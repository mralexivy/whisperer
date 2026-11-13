package syncplane

import (
	"context"
	"errors"
	"time"

	"github.com/mralexivy/whisperer/server/internal/quota"
)

var (
	ErrReadOnly      = errors.New("syncplane: read-only")
	ErrBadRequest    = errors.New("syncplane: bad request")
	ErrNotUploaded   = errors.New("syncplane: object was not uploaded")
	ErrCRCMismatch   = errors.New("syncplane: object does not match what was announced")
	ErrSeqConflict   = errors.New("syncplane: sequence conflict")
	ErrTooManyNames  = errors.New("syncplane: too many names in one request")
	ErrNothingGrants = errors.New("syncplane: no such upload was granted")
)

const (
	MaxBatch       = 50
	MaxObjectBytes = int64(5) << 30
	// A reservation outlives the URL by a margin; resumable sessions (large objects) live a day.
	smallTTL     = 15 * time.Minute
	largeTTL     = 24 * time.Hour
	largeBytes   = int64(8) << 20
	downloadBase = 60 * time.Second
)

type Service struct {
	Store Store
	Blobs Blobs
	Root  string // bucket prefix: "whisperer" or "whisperer-sandbox"
	Now   func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Library identifies one account's current epoch.
type Library struct {
	Account string
	Epoch   int
	Limits  quota.Limits
}

func (s *Service) prefix(l Library) string { return Prefix(s.Root, l.Account, l.Epoch) }

type GrantRequest struct {
	Ref  Ref   `json:"ref"`
	Size int64 `json:"size"`
}

type Grant struct {
	Name      string    `json:"name"`
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expiresAt"`
	Resumable bool      `json:"resumable,omitempty"`
}

func monthKey(t time.Time) string { return t.UTC().Format("2006-01") }

// settle rolls the month counters and releases reservations whose time is up, returning the names whose
// (never committed) objects should be deleted.
func settle(u *Usage, now time.Time) (expired []string) {
	if m := monthKey(now); u.Month != m {
		u.Month, u.DownloadBytes, u.UploadGrants = m, 0, 0
	}
	kept := u.Pending[:0]
	for _, p := range u.Pending {
		if now.After(p.Exp) {
			u.Reserved -= p.Size
			expired = append(expired, p.Name)
			continue
		}
		kept = append(kept, p)
	}
	u.Pending = kept
	if u.Reserved < 0 {
		u.Reserved = 0
	}
	return expired
}

// Grant reserves quota and returns upload URLs. Nothing is signed unless the reservation succeeded.
func (s *Service) Grant(ctx context.Context, l Library, readOnly bool, reqs []GrantRequest) ([]Grant, error) {
	if readOnly {
		return nil, ErrReadOnly
	}
	if len(reqs) == 0 || len(reqs) > MaxBatch {
		return nil, ErrTooManyNames
	}
	prefix := s.prefix(l)
	now := s.now()
	type item struct {
		name string
		size int64
		ttl  time.Duration
	}
	items := make([]item, 0, len(reqs))
	var total int64
	seen := map[string]bool{}
	for _, r := range reqs {
		name, err := r.Ref.Name(prefix)
		if err != nil || r.Size < 1 || r.Size > MaxObjectBytes || seen[name] {
			return nil, ErrBadRequest
		}
		seen[name] = true
		ttl := smallTTL
		if r.Size >= largeBytes {
			ttl = largeTTL
		}
		items = append(items, item{name, r.Size, ttl})
		total += r.Size
	}
	var expired []string
	err := s.Store.UpdateUsage(ctx, l.Account, func(u *Usage) error {
		expired = settle(u, now)
		// A retry of an upload we already reserved must not reserve twice.
		var fresh int64
		var freshN int
		for _, it := range items {
			if !hasPending(u, it.name) {
				fresh += it.size
				freshN++
			}
		}
		if err := l.Limits.CheckUpload(quota.Usage{StoredBytes: u.Committed + u.Reserved, UploadGrants: u.UploadGrants}, fresh, freshN); err != nil {
			return err
		}
		for _, it := range items {
			exp := now.Add(it.ttl + time.Minute)
			if i := pendingIndex(u, it.name); i >= 0 {
				u.Pending[i].Exp = exp
				continue
			}
			u.Pending = append(u.Pending, Pending{Name: it.name, Size: it.size, Exp: exp})
			u.Reserved += it.size
		}
		u.UploadGrants += freshN
		if len(u.Pending) > 64 {
			return quota.ErrGrantLimit
		}
		return nil
	})
	s.discard(ctx, expired)
	if err != nil {
		return nil, err
	}
	out := make([]Grant, 0, len(items))
	for _, it := range items {
		url, err := s.Blobs.SignPut(it.name, it.size, it.ttl)
		if err != nil {
			return nil, err
		}
		out = append(out, Grant{Name: it.name, URL: url, ExpiresAt: now.Add(it.ttl), Resumable: it.size >= largeBytes})
	}
	return out, nil
}

func pendingIndex(u *Usage, name string) int {
	for i, p := range u.Pending {
		if p.Name == name {
			return i
		}
	}
	return -1
}
func hasPending(u *Usage, name string) bool { return pendingIndex(u, name) >= 0 }

// discard deletes objects by exact name (deletes are free; a missing object is fine). No LIST.
func (s *Service) discard(ctx context.Context, names []string) {
	for _, n := range names {
		_ = s.Blobs.Delete(ctx, n)
	}
}

type CommitRequest struct {
	Device string `json:"device"`
	Seq    int64  `json:"seq"`
	CRC    uint32 `json:"crc"`
	// Extra names (audio, snapshots) uploaded alongside the batch, committed with it.
	Extra []Ref `json:"extra,omitempty"`
}

type CommitResult struct {
	Version int64 `json:"version"`
	Head    Head  `json:"head"`
}

// Commit makes an uploaded change batch visible. The object must exist with the announced crc; the device's
// head advances by exactly one, or the identical (seq, crc) is accepted again — so a retry after a lost reply is safe.
func (s *Service) Commit(ctx context.Context, l Library, readOnly bool, c CommitRequest) (CommitResult, error) {
	if readOnly {
		return CommitResult{}, ErrReadOnly
	}
	prefix := s.prefix(l)
	main := Ref{Kind: KindChange, Device: c.Device, Seq: c.Seq}
	mainName, err := main.Name(prefix)
	if err != nil || len(c.Extra) > MaxBatch {
		return CommitResult{}, ErrBadRequest
	}
	names := []string{mainName}
	for _, e := range c.Extra {
		n, err := e.Name(prefix)
		if err != nil || e.Kind == KindChange {
			return CommitResult{}, ErrBadRequest
		}
		names = append(names, n)
	}
	// Verify every object with Storage first (no lock held), then settle the books in one transaction.
	sizes := make(map[string]int64, len(names))
	for i, n := range names {
		size, crc, err := s.Blobs.Stat(ctx, n)
		if errors.Is(err, ErrNotFound) {
			// A retry after a successful commit finds the object but no pending entry; a missing object is a real error.
			return CommitResult{}, ErrNotUploaded
		}
		if err != nil {
			return CommitResult{}, err
		}
		if i == 0 && crc != c.CRC {
			return CommitResult{}, ErrCRCMismatch
		}
		sizes[n] = size
	}
	var result CommitResult
	// Head first: a sequence conflict must not leave bytes counted for a batch nobody can see. If the books
	// step below then fails, the caller's retry is the identical (seq, crc), which the head accepts again.
	err = s.Store.UpdateHeads(ctx, l.Account, func(h *Heads) error {
		cur := h.Heads[c.Device]
		switch {
		case c.Seq == cur.Seq && c.CRC == cur.CRC:
			// identical retry
		case c.Seq == cur.Seq+1:
			h.Heads[c.Device] = Head{Seq: c.Seq, CRC: c.CRC}
			h.Version++
		default:
			result.Head = cur
			return ErrSeqConflict
		}
		result = CommitResult{Version: h.Version, Head: h.Heads[c.Device]}
		return nil
	})
	if err != nil {
		if errors.Is(err, ErrSeqConflict) {
			return result, err // the caller resyncs its counter from the head returned here
		}
		return CommitResult{}, err
	}
	now := s.now()
	var expired []string
	err = s.Store.UpdateUsage(ctx, l.Account, func(u *Usage) error {
		expired = settle(u, now)
		for _, n := range names {
			if i := pendingIndex(u, n); i >= 0 {
				u.Reserved -= u.Pending[i].Size
				u.Committed += sizes[n]
				u.Pending = append(u.Pending[:i], u.Pending[i+1:]...)
			}
			// No pending entry: already committed (a retry) — the books are unchanged.
		}
		return nil
	})
	s.discard(ctx, expired)
	if err != nil {
		return CommitResult{}, err
	}
	return result, nil
}

// HeadsSince is the poll: one read. `unchanged` is true when the caller already has this version.
func (s *Service) HeadsSince(ctx context.Context, l Library, since int64) (h Heads, unchanged bool, err error) {
	h, err = s.Store.GetHeads(ctx, l.Account)
	if err != nil {
		return Heads{}, false, err
	}
	return h, since > 0 && since == h.Version, nil
}

// Download returns read URLs. Only audio and meeting objects count against the monthly allowance (the
// small change batches and snapshots are what every sync needs and are never metered).
func (s *Service) Download(ctx context.Context, l Library, refs []Ref) ([]Grant, error) {
	if len(refs) == 0 || len(refs) > MaxBatch {
		return nil, ErrTooManyNames
	}
	prefix := s.prefix(l)
	names := make([]string, len(refs))
	var metered int64
	sizes := make(map[string]int64)
	for i, r := range refs {
		n, err := r.Name(prefix)
		if err != nil {
			return nil, ErrBadRequest
		}
		names[i] = n
		if r.Kind == KindAudio || r.Kind == KindMeeting {
			size, _, err := s.Blobs.Stat(ctx, n)
			if err != nil {
				return nil, err
			}
			sizes[n] = size
			metered += size
		}
	}
	if metered > 0 {
		now := s.now()
		var expired []string
		err := s.Store.UpdateUsage(ctx, l.Account, func(u *Usage) error {
			expired = settle(u, now)
			if err := l.Limits.CheckDownload(quota.Usage{DownloadBytes: u.DownloadBytes}, metered); err != nil {
				return err
			}
			u.DownloadBytes += metered
			return nil
		})
		s.discard(ctx, expired)
		if err != nil {
			return nil, err
		}
	}
	out := make([]Grant, len(names))
	for i, n := range names {
		ttl := downloadBase + time.Duration(sizes[n]/(20<<20))*time.Second
		url, err := s.Blobs.SignGet(n, ttl)
		if err != nil {
			return nil, err
		}
		out[i] = Grant{Name: n, URL: url, ExpiresAt: s.now().Add(ttl)}
	}
	return out, nil
}

// Delete removes objects by name and gives their real size back to the quota. Allowed while read-only:
// a user over quota must be able to free space.
func (s *Service) Delete(ctx context.Context, l Library, refs []Ref) (int, error) {
	if len(refs) == 0 || len(refs) > MaxBatch {
		return 0, ErrTooManyNames
	}
	prefix := s.prefix(l)
	var freed int64
	deleted := 0
	for _, r := range refs {
		n, err := r.Name(prefix)
		if err != nil {
			return deleted, ErrBadRequest
		}
		size, _, err := s.Blobs.Stat(ctx, n)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return deleted, err
		}
		if err := s.Blobs.Delete(ctx, n); err != nil {
			return deleted, err
		}
		freed += size
		deleted++
	}
	if freed > 0 {
		err := s.Store.UpdateUsage(ctx, l.Account, func(u *Usage) error {
			u.Committed -= freed
			if u.Committed < 0 {
				u.Committed = 0
			}
			return nil
		})
		if err != nil {
			return deleted, err
		}
	}
	return deleted, nil
}

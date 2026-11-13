// Package retention deletes the data of people who stopped paying — late, never early, and never on a guess.
//
// Deleting is free; losing a customer's data is not. So the sweep only ever acts on an entitlement that the
// clock says is past every reversible stage (read-only window, seal, soft-delete — see entitlement), and even
// then it asks Apple, not its own cache, before the first byte goes. Anything unexpected stops it: Apple
// unreachable, a recent purchase, or more accounts due in one run than could plausibly have lapsed together.
package retention

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// Status is what Apple says about a subscription right now.
type Status int

const (
	StatusExpired Status = iota
	StatusRevoked
	StatusActive
	StatusGrace
	StatusRetry // billing retry: Apple is still trying to collect — the user may yet pay
)

// Answer is Apple's authoritative reply (App Store Server API).
type Answer struct {
	Status     Status
	ExpiresAt  time.Time
	GraceUntil time.Time
}

// Apple is the App Store Server API as the sweep needs it. An error means "unknown": never destructive.
type Apple interface {
	Status(ctx context.Context, originalTransactionID string) (Answer, error)
}

type Sweeper struct {
	Entitlements entitlement.Store
	// Accounts, when set, adds the second job: deleting the old epochs a library reset left behind.
	Accounts account.Store
	Apple    Apple
	Blobs    syncplane.Blobs
	Root     string
	// Epoch is the library epoch whose objects belong to the account (the heads document in production).
	Epoch func(ctx context.Context, uid string) (int, error)
	Now   func() time.Time
	Log   *slog.Logger

	MaxPerRun    int           // accounts handled per run
	Breaker      int           // more than this many due at once ⇒ stop and alert, delete nothing
	PageSize     int           // objects listed/deleted per page
	MaxPages     int           // pages per account per run (a run is time-bounded)
	StragglerGap time.Duration // wait between pass one and pass two: longer than any upload URL lives
	// EpochHold is how long a replaced library epoch is kept untouched after a reset before any byte is deleted:
	// a reset can be a mistake (or someone else's), and the old ciphertext is the only way back. Default 7 days.
	EpochHold time.Duration
	// DryRun reports what would be deleted and deletes nothing. The default for a new deployment's first month.
	DryRun bool
}

type Report struct {
	Due         int
	DryRun      []string // uids that would have been deleted
	Deleted     []string // uids whose data is now fully gone
	InProgress  []string
	Reactivated []string // Apple says the subscription is alive: the delete is cancelled
	Skipped     map[string]string
	Tripped     bool // the circuit breaker stopped the run
	// EpochsDeleted are "account/epoch" pairs whose old-epoch objects are now fully gone; EpochsDryRun would have been.
	EpochsDeleted []string
	EpochsDryRun  []string
}

func (s *Sweeper) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Sweeper) log() *slog.Logger {
	if s.Log != nil {
		return s.Log
	}
	return slog.Default()
}

func (s *Sweeper) defaults() {
	if s.MaxPerRun == 0 {
		s.MaxPerRun = 5
	}
	if s.Breaker == 0 {
		s.Breaker = 25
	}
	if s.PageSize == 0 {
		s.PageSize = 1000
	}
	if s.MaxPages == 0 {
		s.MaxPages = 20
	}
	if s.EpochHold == 0 {
		s.EpochHold = 7 * 24 * time.Hour
	}
	if s.StragglerGap == 0 {
		s.StragglerGap = 25 * time.Minute
	}
}

// Run is one bounded, restartable pass. Safe to call at any time and from two instances: every step is
// idempotent and checks state again before acting.
func (s *Sweeper) Run(ctx context.Context) Report {
	s.defaults()
	rep := Report{Skipped: map[string]string{}}
	now := s.now()
	s.sweepEpochs(ctx, now, &rep) // user-requested and independent of the lapse guards below
	due, err := s.Entitlements.Due(ctx, now, s.Breaker+1)
	if err != nil {
		s.log().Error("retention: listing due", "err", err)
		return rep
	}
	rep.Due = len(due)
	// Accounts already being deleted are exempt from the breaker: that decision was taken earlier, with checks.
	fresh := 0
	for _, e := range due {
		if e.DeletingSince.IsZero() {
			fresh++
		}
	}
	if fresh > s.Breaker {
		rep.Tripped = true
		s.log().Error("retention: circuit breaker — too many accounts due at once, deleting nothing", "due", fresh, "limit", s.Breaker)
		return rep
	}
	handled := 0
	for _, e := range due {
		if handled >= s.MaxPerRun {
			break
		}
		handled++
		s.one(ctx, e, now, &rep)
	}
	return rep
}

func (s *Sweeper) one(ctx context.Context, e entitlement.Entitlement, now time.Time, rep *Report) {
	if e.DeletingSince.IsZero() {
		// Before the point of no return: every guard, re-checked now.
		switch {
		case now.Sub(e.UpdatedAt) < 24*time.Hour:
			rep.Skipped[e.UID] = "recent activity"
			return
		case !e.Due(now):
			rep.Skipped[e.UID] = "not due"
			return
		}
		ans, err := s.Apple.Status(ctx, e.OriginalTransactionID)
		if err != nil {
			rep.Skipped[e.UID] = "apple unreachable"
			s.log().Warn("retention: apple unreachable, postponing", "uid", e.UID, "err", err)
			return
		}
		if ans.Status != StatusExpired && ans.Status != StatusRevoked {
			refreshed := e.Refreshed(ans.ExpiresAt, ans.GraceUntil, now)
			if err := s.Entitlements.Put(ctx, refreshed); err != nil {
				s.log().Error("retention: saving reactivation", "uid", e.UID, "err", err)
			}
			rep.Reactivated = append(rep.Reactivated, e.UID)
			return
		}
		if s.DryRun {
			rep.DryRun = append(rep.DryRun, e.UID)
			return
		}
		e.DeletingSince, e.LastVerifiedAt = now, now
		if err := s.Entitlements.Put(ctx, e); err != nil {
			rep.Skipped[e.UID] = "store"
			return
		}
	}
	s.deleteData(ctx, e, now, rep)
}

// deleteData runs the two passes. Listing from the start each time is idempotent: deleted names are gone.
func (s *Sweeper) deleteData(ctx context.Context, e entitlement.Entitlement, now time.Time, rep *Report) {
	epoch, err := s.Epoch(ctx, e.UID)
	if err != nil {
		rep.Skipped[e.UID] = "epoch"
		return
	}
	prefix := syncplane.Prefix(s.Root, e.UID, epoch)
	if !e.PassOneDoneAt.IsZero() && now.Sub(e.PassOneDoneAt) < s.StragglerGap {
		rep.InProgress = append(rep.InProgress, e.UID) // waiting out in-flight upload URLs
		return
	}
	for page := 0; page < s.MaxPages; page++ {
		names, _, err := s.Blobs.List(ctx, prefix, "", s.PageSize)
		if err != nil {
			s.log().Warn("retention: list", "uid", e.UID, "err", err)
			rep.InProgress = append(rep.InProgress, e.UID)
			return
		}
		if len(names) == 0 {
			break
		}
		for _, n := range names {
			if err := s.Blobs.Delete(ctx, n); err != nil && !errors.Is(err, syncplane.ErrNotFound) {
				s.log().Warn("retention: delete", "uid", e.UID, "err", err)
				rep.InProgress = append(rep.InProgress, e.UID)
				_ = s.Entitlements.Put(ctx, e)
				return
			}
			e.DeletedObjects++
		}
		if page == s.MaxPages-1 {
			_ = s.Entitlements.Put(ctx, e) // out of time: continue next run
			rep.InProgress = append(rep.InProgress, e.UID)
			return
		}
	}
	// The prefix is empty.
	if e.PassOneDoneAt.IsZero() {
		e.PassOneDoneAt = now
		_ = s.Entitlements.Put(ctx, e)
		rep.InProgress = append(rep.InProgress, e.UID)
		return
	}
	e.DataDeletedAt = now
	if err := s.Entitlements.Put(ctx, e); err != nil {
		rep.InProgress = append(rep.InProgress, e.UID)
		return
	}
	rep.Deleted = append(rep.Deleted, e.UID)
	s.log().Info("retention: data deleted", "uid", e.UID, "objects", e.DeletedObjects)
}

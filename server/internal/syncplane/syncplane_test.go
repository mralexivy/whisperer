package syncplane_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/quota"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

const dev = "0123456789abcdef0123456789abcdef"
const obj = "fedcba9876543210fedcba9876543210"

var t0 = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

type rig struct {
	svc   *syncplane.Service
	blobs *syncplane.MemoryBlobs
	store *syncplane.MemoryStore
	now   *time.Time
	lib   syncplane.Library
}

func newRig(limits quota.Limits) *rig {
	now := t0
	r := &rig{blobs: syncplane.NewMemoryBlobs(), store: syncplane.NewMemoryStore(), now: &now}
	r.svc = &syncplane.Service{Store: r.store, Blobs: r.blobs, Root: "whisperer", Now: func() time.Time { return *r.now }}
	r.lib = syncplane.Library{Account: "acct", Epoch: 1, Limits: limits}
	return r
}

var big = quota.Limits{StoredBytes: 5 << 30, MonthlyDownloadBytes: 2 << 30, MonthlyUploadGrants: 1000}

func change(seq int64) syncplane.Ref {
	return syncplane.Ref{Kind: syncplane.KindChange, Device: dev, Seq: seq}
}

func (r *rig) upload(t *testing.T, ref syncplane.Ref, size int64, crc uint32) string {
	t.Helper()
	g, err := r.svc.Grant(context.Background(), r.lib, false, []syncplane.GrantRequest{{Ref: ref, Size: size}})
	if err != nil {
		t.Fatalf("grant: %v", err)
	}
	r.blobs.Put(g[0].Name, size, crc)
	return g[0].Name
}

func TestNamesAreBuiltFromTheAccountAndValidated(t *testing.T) {
	prefix := syncplane.Prefix("whisperer", "acct", 1)
	n, err := change(7).Name(prefix)
	if err != nil || n != prefix+"changes/"+dev+"/000000000007" {
		t.Fatalf("name = %q, %v", n, err)
	}
	bad := []syncplane.Ref{
		{Kind: syncplane.KindChange, Device: "../x", Seq: 1},
		{Kind: syncplane.KindChange, Device: dev, Seq: 0},
		{Kind: syncplane.KindAudio, ID: "ABC"},
		{Kind: syncplane.KindAudio, ID: obj + "/../../other"},
		{Kind: "secrets", ID: obj},
	}
	for _, r := range bad {
		if _, err := r.Name(prefix); err == nil {
			t.Errorf("%+v accepted", r)
		}
	}
	for _, name := range []string{
		"whisperer/users/other/e1/audio/" + obj, // another account
		prefix + "../e2/audio/" + obj,           // traversal
		strings.Replace(n, "e1", "e2", 1),       // another epoch
		prefix + "audio/" + obj + "/extra",
	} {
		if _, err := syncplane.ParseName(prefix, name); err == nil {
			t.Errorf("ParseName accepted %q", name)
		}
	}
	if ref, err := syncplane.ParseName(prefix, n); err != nil || ref != change(7) {
		t.Errorf("round trip: %+v %v", ref, err)
	}
}

func TestGrantReservesAndACommitMovesItToCommitted(t *testing.T) {
	r := newRig(big)
	name := r.upload(t, syncplane.Ref{Kind: syncplane.KindAudio, ID: obj}, 1000, 0)
	u, _ := r.store.GetUsage(context.Background(), "acct")
	if u.Reserved != 1000 || u.Committed != 0 {
		t.Fatalf("after grant: %+v", u)
	}
	// Commit the change batch that references it.
	r.upload(t, change(1), 200, 42)
	res, err := r.svc.Commit(context.Background(), r.lib, false, syncplane.CommitRequest{Device: dev, Seq: 1, CRC: 42, Extra: []syncplane.Ref{{Kind: syncplane.KindAudio, ID: obj}}})
	if err != nil || res.Version != 1 || res.Head.Seq != 1 {
		t.Fatalf("commit: %+v %v", res, err)
	}
	u, _ = r.store.GetUsage(context.Background(), "acct")
	if u.Reserved != 0 || u.Committed != 1200 || len(u.Pending) != 0 {
		t.Fatalf("after commit: %+v (name %s)", u, name)
	}
}

func TestACommitRetryIsIdempotentAndAGapIsAConflict(t *testing.T) {
	r := newRig(big)
	r.upload(t, change(1), 100, 7)
	c := syncplane.CommitRequest{Device: dev, Seq: 1, CRC: 7}
	first, err := r.svc.Commit(context.Background(), r.lib, false, c)
	if err != nil {
		t.Fatal(err)
	}
	again, err := r.svc.Commit(context.Background(), r.lib, false, c)
	if err != nil || again != first {
		t.Fatalf("retry changed the outcome: %+v vs %+v (%v)", again, first, err)
	}
	if u, _ := r.store.GetUsage(context.Background(), "acct"); u.Committed != 100 {
		t.Fatalf("a retry double-counted: %+v", u)
	}
	r.upload(t, change(3), 100, 9)
	res, err := r.svc.Commit(context.Background(), r.lib, false, syncplane.CommitRequest{Device: dev, Seq: 3, CRC: 9})
	if !errors.Is(err, syncplane.ErrSeqConflict) || res.Head.Seq != 1 {
		t.Fatalf("a gap must conflict and report the head: %+v %v", res, err)
	}
	if u, _ := r.store.GetUsage(context.Background(), "acct"); u.Committed != 100 {
		t.Fatalf("a conflicting commit counted bytes: %+v", u)
	}
}

func TestACommitNeedsTheRealObjectWithTheAnnouncedChecksum(t *testing.T) {
	r := newRig(big)
	_, err := r.svc.Commit(context.Background(), r.lib, false, syncplane.CommitRequest{Device: dev, Seq: 1, CRC: 1})
	if !errors.Is(err, syncplane.ErrNotUploaded) {
		t.Fatalf("missing object: %v", err)
	}
	r.upload(t, change(1), 10, 5)
	_, err = r.svc.Commit(context.Background(), r.lib, false, syncplane.CommitRequest{Device: dev, Seq: 1, CRC: 6})
	if !errors.Is(err, syncplane.ErrCRCMismatch) {
		t.Fatalf("wrong crc: %v", err)
	}
	if h, _, _ := r.svc.HeadsSince(context.Background(), r.lib, 0); h.Version != 0 {
		t.Fatal("a failed commit moved the head")
	}
}

func TestQuotaNeverExceededUnderConcurrentGrants(t *testing.T) {
	r := newRig(quota.Limits{StoredBytes: 1000, MonthlyDownloadBytes: 1 << 20, MonthlyUploadGrants: 1000})
	var wg sync.WaitGroup
	var mu sync.Mutex
	granted := int64(0)
	for i := 0; i < 40; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := strings.Repeat("0", 31) + string("0123456789abcdef"[i%16])
			ref := syncplane.Ref{Kind: syncplane.KindAudio, ID: id}
			if i >= 16 {
				ref = syncplane.Ref{Kind: syncplane.KindChange, Device: dev, Seq: int64(i)}
			}
			if _, err := r.svc.Grant(context.Background(), r.lib, false, []syncplane.GrantRequest{{Ref: ref, Size: 100}}); err == nil {
				mu.Lock()
				granted += 100
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	u, _ := r.store.GetUsage(context.Background(), "acct")
	if granted > 1000 || u.Reserved != granted || u.Reserved+u.Committed > 1000 {
		t.Fatalf("granted %d, ledger %+v exceeds 1000", granted, u)
	}
}

func TestGrantsAreRefusedWhenReadOnlyOrFull(t *testing.T) {
	r := newRig(quota.Limits{StoredBytes: 100, MonthlyDownloadBytes: 10, MonthlyUploadGrants: 2})
	req := []syncplane.GrantRequest{{Ref: change(1), Size: 50}}
	if _, err := r.svc.Grant(context.Background(), r.lib, true, req); !errors.Is(err, syncplane.ErrReadOnly) {
		t.Fatalf("read-only: %v", err)
	}
	if _, err := r.svc.Grant(context.Background(), r.lib, false, []syncplane.GrantRequest{{Ref: change(1), Size: 101}}); !errors.Is(err, quota.ErrStorageFull) {
		t.Fatalf("too big: %v", err)
	}
	if _, err := r.svc.Grant(context.Background(), r.lib, false, req); err != nil {
		t.Fatal(err)
	}
	// Asking again for the same object reuses the reservation and the grant allowance.
	if _, err := r.svc.Grant(context.Background(), r.lib, false, req); err != nil {
		t.Fatalf("retry of the same grant: %v", err)
	}
	if u, _ := r.store.GetUsage(context.Background(), "acct"); u.Reserved != 50 || u.UploadGrants != 1 {
		t.Fatalf("a retried grant double-reserved: %+v", u)
	}
}

func TestAbandonedUploadsAreReleasedAndTheirObjectsDeleted(t *testing.T) {
	r := newRig(big)
	name := r.upload(t, syncplane.Ref{Kind: syncplane.KindAudio, ID: obj}, 4096, 1)
	*r.now = t0.Add(time.Hour) // far past the URL TTL
	if _, err := r.svc.Grant(context.Background(), r.lib, false, []syncplane.GrantRequest{{Ref: change(1), Size: 10}}); err != nil {
		t.Fatal(err)
	}
	u, _ := r.store.GetUsage(context.Background(), "acct")
	if u.Reserved != 10 {
		t.Fatalf("the abandoned reservation was kept: %+v", u)
	}
	if _, _, err := r.blobs.Stat(context.Background(), name); !errors.Is(err, syncplane.ErrNotFound) {
		t.Fatal("the orphan object was not deleted")
	}
}

func TestDownloadAllowanceCountsAudioOnlyAndResetsMonthly(t *testing.T) {
	r := newRig(quota.Limits{StoredBytes: 1 << 30, MonthlyDownloadBytes: 1000, MonthlyUploadGrants: 100})
	audio := syncplane.Ref{Kind: syncplane.KindAudio, ID: obj}
	r.blobs.Put(syncplane.Prefix("whisperer", "acct", 1)+"audio/"+obj, 600, 0)
	r.blobs.Put(syncplane.Prefix("whisperer", "acct", 1)+"changes/"+dev+"/000000000001", 5000, 0)
	ctx := context.Background()
	if _, err := r.svc.Download(ctx, r.lib, []syncplane.Ref{change(1)}); err != nil {
		t.Fatalf("change batches are never metered: %v", err)
	}
	if _, err := r.svc.Download(ctx, r.lib, []syncplane.Ref{audio}); err != nil {
		t.Fatal(err)
	}
	if _, err := r.svc.Download(ctx, r.lib, []syncplane.Ref{audio}); !errors.Is(err, quota.ErrDownloadLimit) {
		t.Fatalf("second audio download should exceed 1000: %v", err)
	}
	*r.now = t0.AddDate(0, 1, 0)
	if _, err := r.svc.Download(ctx, r.lib, []syncplane.Ref{audio}); err != nil {
		t.Fatalf("a new month resets the allowance: %v", err)
	}
}

func TestDeleteFreesTheRealSizeAndWorksReadOnly(t *testing.T) {
	r := newRig(big)
	r.upload(t, change(1), 300, 3)
	if _, err := r.svc.Commit(context.Background(), r.lib, false, syncplane.CommitRequest{Device: dev, Seq: 1, CRC: 3}); err != nil {
		t.Fatal(err)
	}
	n, err := r.svc.Delete(context.Background(), r.lib, []syncplane.Ref{change(1), change(2)})
	if err != nil || n != 1 {
		t.Fatalf("delete: %d %v", n, err)
	}
	if u, _ := r.store.GetUsage(context.Background(), "acct"); u.Committed != 0 {
		t.Fatalf("not freed: %+v", u)
	}
}

func TestHeadsPollIsUnchangedWhenTheVersionMatches(t *testing.T) {
	r := newRig(big)
	r.upload(t, change(1), 10, 1)
	res, _ := r.svc.Commit(context.Background(), r.lib, false, syncplane.CommitRequest{Device: dev, Seq: 1, CRC: 1})
	h, unchanged, _ := r.svc.HeadsSince(context.Background(), r.lib, 0)
	if unchanged || h.Version != res.Version {
		t.Fatalf("first poll: %+v %v", h, unchanged)
	}
	if _, unchanged, _ = r.svc.HeadsSince(context.Background(), r.lib, h.Version); !unchanged {
		t.Fatal("an up-to-date poll must report unchanged")
	}
}

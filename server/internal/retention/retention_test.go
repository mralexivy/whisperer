package retention_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/retention"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

var t0 = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

func day(n int) time.Duration { return time.Duration(n) * 24 * time.Hour }

type fakeApple struct {
	answer retention.Answer
	err    error
	calls  int
}

func (f *fakeApple) Status(context.Context, string) (retention.Answer, error) {
	f.calls++
	return f.answer, f.err
}

type rig struct {
	sweeper *retention.Sweeper
	ents    *entitlement.Memory
	blobs   *syncplane.MemoryBlobs
	apple   *fakeApple
	now     *time.Time
}

func newRig() *rig {
	now := t0.Add(day(400))
	r := &rig{ents: entitlement.NewMemory(), blobs: syncplane.NewMemoryBlobs(), apple: &fakeApple{answer: retention.Answer{Status: retention.StatusExpired}}, now: &now}
	r.sweeper = &retention.Sweeper{Entitlements: r.ents, Apple: r.apple, Blobs: r.blobs, Root: "whisperer",
		Epoch: func(context.Context, string) (int, error) { return 1, nil }, Now: func() time.Time { return *r.now }, PageSize: 3, MaxPages: 100}
	return r
}

// lapsed adds a subscriber whose paid period ended long ago, with `n` objects stored.
func (r *rig) lapsed(uid string, endedDaysAgo, n int) entitlement.Entitlement {
	tx := apple.Transaction{OriginalTransactionID: "tx-" + uid, ProductID: "cloud.monthly", Environment: "Production",
		ExpiresDate: r.now.Add(-day(endedDaysAgo)).UnixMilli()}
	e := entitlement.FromTransaction(nil, uid, tx, r.now.Add(-day(endedDaysAgo+30))) // last touched long ago
	_ = r.ents.Put(context.Background(), e)
	for i := 0; i < n; i++ {
		r.blobs.Put(fmt.Sprintf("%saudio/%032x", syncplane.Prefix("whisperer", uid, 1), i), 10, 0)
	}
	return e
}

func (r *rig) count(uid string) int { return r.blobs.Count(syncplane.Prefix("whisperer", uid, 1)) }

func TestNothingIsDeletedBeforeEveryReversibleStageHasPassed(t *testing.T) {
	r := newRig()
	r.lapsed("early", 70, 5) // 60-day window + 14 seal → soft-deleted at day 70; hard delete at 81
	rep := r.sweeper.Run(context.Background())
	if rep.Due != 0 || r.count("early") != 5 || r.apple.calls != 0 {
		t.Fatalf("a soft-deleted account must be untouched and not even checked: %+v, %d objects", rep, r.count("early"))
	}
}

func TestAnExpiredAccountIsDeletedInTwoPassesAfterAppleConfirms(t *testing.T) {
	r := newRig()
	r.lapsed("gone", 90, 7)
	ctx := context.Background()
	rep := r.sweeper.Run(ctx)
	if r.apple.calls != 1 || r.count("gone") != 0 || len(rep.InProgress) != 1 {
		t.Fatalf("pass one: %+v calls=%d left=%d", rep, r.apple.calls, r.count("gone"))
	}
	*r.now = r.now.Add(5 * time.Minute) // in-flight upload URLs may still land
	r.blobs.Put(syncplane.Prefix("whisperer", "gone", 1)+"audio/"+fmt.Sprintf("%032x", 99), 10, 0)
	if rep = r.sweeper.Run(ctx); len(rep.Deleted) != 0 || r.count("gone") != 1 {
		t.Fatalf("must wait out the straggler gap: %+v", rep)
	}
	*r.now = r.now.Add(30 * time.Minute)
	if rep = r.sweeper.Run(ctx); len(rep.Deleted) != 1 || r.count("gone") != 0 {
		t.Fatalf("pass two: %+v left=%d", rep, r.count("gone"))
	}
	e, _, _ := r.ents.Get(ctx, "gone")
	if e.DataDeletedAt.IsZero() || e.DeletedObjects != 8 || e.StateAt(*r.now) != entitlement.Deleted {
		t.Fatalf("not recorded: %+v", e)
	}
	if r.apple.calls != 1 {
		t.Fatalf("Apple is asked once, before the point of no return; got %d", r.apple.calls)
	}
}

func TestAppleSayingActiveCancelsTheDeleteAndKeepsTheData(t *testing.T) {
	for name, status := range map[string]retention.Status{"active": retention.StatusActive, "grace": retention.StatusGrace, "billing retry": retention.StatusRetry} {
		r := newRig()
		r.lapsed("u", 90, 4)
		r.apple.answer = retention.Answer{Status: status, ExpiresAt: r.now.Add(day(20))}
		rep := r.sweeper.Run(context.Background())
		e, _, _ := r.ents.Get(context.Background(), "u")
		if len(rep.Reactivated) != 1 || r.count("u") != 4 || e.Due(*r.now) {
			t.Fatalf("%s: %+v left=%d due=%v", name, rep, r.count("u"), e.Due(*r.now))
		}
	}
}

func TestUnknownAppleStatusNeverDeletes(t *testing.T) {
	r := newRig()
	r.lapsed("u", 90, 4)
	r.apple.err = errors.New("apple is down")
	rep := r.sweeper.Run(context.Background())
	if r.count("u") != 4 || rep.Skipped["u"] != "apple unreachable" {
		t.Fatalf("%+v left=%d", rep, r.count("u"))
	}
}

func TestARecentPurchaseOrTouchBlocksTheDelete(t *testing.T) {
	r := newRig()
	e := r.lapsed("u", 90, 4)
	e.UpdatedAt = r.now.Add(-time.Hour)
	_ = r.ents.Put(context.Background(), e)
	if rep := r.sweeper.Run(context.Background()); r.count("u") != 4 || rep.Skipped["u"] != "recent activity" {
		t.Fatalf("%+v", rep)
	}
}

func TestTheCircuitBreakerStopsAMassDelete(t *testing.T) {
	r := newRig()
	r.sweeper.Breaker = 3
	for i := 0; i < 6; i++ {
		r.lapsed(fmt.Sprintf("u%d", i), 90, 2)
	}
	rep := r.sweeper.Run(context.Background())
	if !rep.Tripped || r.apple.calls != 0 {
		t.Fatalf("breaker did not trip: %+v", rep)
	}
	for i := 0; i < 6; i++ {
		if r.count(fmt.Sprintf("u%d", i)) != 2 {
			t.Fatal("the breaker must leave every account untouched")
		}
	}
}

func TestDryRunReportsAndDeletesNothing(t *testing.T) {
	r := newRig()
	r.sweeper.DryRun = true
	r.lapsed("u", 90, 4)
	rep := r.sweeper.Run(context.Background())
	e, _, _ := r.ents.Get(context.Background(), "u")
	if len(rep.DryRun) != 1 || r.count("u") != 4 || !e.DeletingSince.IsZero() {
		t.Fatalf("%+v", rep)
	}
}

func TestAnInterruptedDeleteResumesWithoutAskingAppleAgain(t *testing.T) {
	r := newRig()
	r.sweeper.MaxPages = 1 // three objects per run
	r.lapsed("u", 90, 7)
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		r.sweeper.Run(ctx)
		*r.now = r.now.Add(time.Minute)
	}
	if r.count("u") != 0 {
		t.Fatalf("left %d", r.count("u"))
	}
	if r.apple.calls != 1 {
		t.Fatalf("Apple asked %d times", r.apple.calls)
	}
}

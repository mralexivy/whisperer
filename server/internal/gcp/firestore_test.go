package gcp_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/gcp"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

func newFS(t *testing.T) (*gcp.Firestore, *fakeFirestore) {
	f, srv := newFake(t)
	return &gcp.Firestore{Project: "p", Root: "envs/prod", Tokens: gcp.StaticTokens{AccessToken: "test-token"}, Base: srv.URL}, f
}

var t0 = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

type doc struct {
	Name   string            `json:"name"`
	N      int64             `json:"n"`
	Ratio  float64           `json:"ratio"`
	On     bool              `json:"on"`
	Tags   []string          `json:"tags"`
	Nested map[string]int64  `json:"nested"`
	At     time.Time         `json:"at"`
	Later  time.Time         `json:"later,omitempty"`
	Items  []struct{ A int } `json:"items"`
}

func TestDocumentsRoundTripThroughTheValueEncoding(t *testing.T) {
	fs, _ := newFS(t)
	in := doc{Name: "x", N: 1 << 40, Ratio: 0.5, On: true, Tags: []string{"a", "b"}, Nested: map[string]int64{"k": 7}, At: t0, Items: []struct{ A int }{{1}, {2}}}
	if err := fs.Set(context.Background(), "d/1", in); err != nil {
		t.Fatal(err)
	}
	var out doc
	if err := fs.Get(context.Background(), "d/1", &out); err != nil {
		t.Fatal(err)
	}
	if out.Name != "x" || out.N != 1<<40 || out.Ratio != 0.5 || !out.On || len(out.Tags) != 2 || out.Nested["k"] != 7 || !out.At.Equal(t0) || !out.Later.IsZero() || len(out.Items) != 2 {
		t.Fatalf("round trip lost data: %+v", out)
	}
	if err := fs.Get(context.Background(), "d/missing", &out); err != gcp.ErrNotFound {
		t.Fatalf("missing doc: %v", err)
	}
}

func TestAZeroTimeIsNotStored(t *testing.T) {
	fs, f := newFS(t)
	if err := fs.Set(context.Background(), "d/1", doc{Name: "z"}); err != nil {
		t.Fatal(err)
	}
	for _, fields := range f.docs {
		if _, present := fields["later"]; present {
			t.Fatal("a zero time must be absent so range queries never match it")
		}
	}
}

func TestTransactionsRetryOnContentionAndStartFromTheStoredDocumentEachTime(t *testing.T) {
	fs, f := newFS(t)
	f.failCommits = 2
	var u syncplane.Usage
	calls := 0
	err := fs.Transact(context.Background(), "sync_usage/a", &u, func() error {
		calls++
		u.Committed += 100 // would accumulate across attempts if state leaked between retries
		return nil
	})
	if err != nil || calls != 3 {
		t.Fatalf("err=%v calls=%d", err, calls)
	}
	var got syncplane.Usage
	if err := fs.Get(context.Background(), "sync_usage/a", &got); err != nil || got.Committed != 100 {
		t.Fatalf("stored %+v (%v)", got, err)
	}
}

func TestConcurrentUpdatesNeverLoseAWrite(t *testing.T) {
	fs, _ := newFS(t)
	store := gcp.SyncStore{FS: fs}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = store.UpdateUsage(context.Background(), "a", func(u *syncplane.Usage) error { u.Committed += 10; return nil })
		}()
	}
	wg.Wait()
	u, _ := store.GetUsage(context.Background(), "a")
	if u.Committed != 80 {
		t.Fatalf("committed = %d, want 80: an update was lost", u.Committed)
	}
}

func TestAnAbortedTransactionWritesNothing(t *testing.T) {
	fs, _ := newFS(t)
	store := gcp.SyncStore{FS: fs}
	_ = store.UpdateUsage(context.Background(), "a", func(u *syncplane.Usage) error { u.Committed = 5; return nil })
	err := store.UpdateUsage(context.Background(), "a", func(u *syncplane.Usage) error { u.Committed = 999; return syncplane.ErrReadOnly })
	if err != syncplane.ErrReadOnly {
		t.Fatalf("err = %v", err)
	}
	if u, _ := store.GetUsage(context.Background(), "a"); u.Committed != 5 {
		t.Fatalf("an aborted update leaked: %+v", u)
	}
}

func TestHeadsDefaultToEpochOneAndAdvance(t *testing.T) {
	fs, _ := newFS(t)
	store := gcp.SyncStore{FS: fs}
	h, _ := store.GetHeads(context.Background(), "a")
	if h.Epoch != 1 || h.Version != 0 || h.Heads == nil {
		t.Fatalf("defaults: %+v", h)
	}
	_ = store.UpdateHeads(context.Background(), "a", func(h *syncplane.Heads) error {
		h.Heads["dev"] = syncplane.Head{Seq: 3, CRC: 9}
		h.Version++
		return nil
	})
	h, _ = store.GetHeads(context.Background(), "a")
	if h.Version != 1 || h.Heads["dev"].Seq != 3 || h.Heads["dev"].CRC != 9 {
		t.Fatalf("after: %+v", h)
	}
}

func lapsedEntitlement(uid, tx string, expiredDaysAgo int, now time.Time) entitlement.Entitlement {
	return entitlement.FromTransaction(nil, uid, apple.Transaction{OriginalTransactionID: tx, ProductID: "cloud.monthly", Environment: "Production",
		ExpiresDate: now.Add(-time.Duration(expiredDaysAgo) * 24 * time.Hour).UnixMilli()}, now)
}

func TestEntitlementsRoundTripAndAreFoundByTransaction(t *testing.T) {
	fs, _ := newFS(t)
	store := gcp.EntitlementStore{FS: fs}
	ctx := context.Background()
	e := lapsedEntitlement("u1", "tx-1", -30, t0)
	e.SeenNotifications = []string{"n1", "n2"}
	if err := store.Put(ctx, e); err != nil {
		t.Fatal(err)
	}
	got, ok, err := store.Get(ctx, "u1")
	if err != nil || !ok || got.OriginalTransactionID != "tx-1" || !got.ExpiresAt.Equal(e.ExpiresAt) || len(got.SeenNotifications) != 2 {
		t.Fatalf("get: %+v %v %v", got, ok, err)
	}
	if _, ok, _ := store.Get(ctx, "nobody"); ok {
		t.Fatal("an unknown uid must not be found")
	}
	by, ok, _ := store.ByOriginalTransactionID(ctx, "tx-1")
	if !ok || by.UID != "u1" {
		t.Fatalf("by transaction: %+v %v", by, ok)
	}
}

func TestDueFindsOnlyAccountsPastEveryStageAndNeverFinishedOnes(t *testing.T) {
	fs, _ := newFS(t)
	store := gcp.EntitlementStore{FS: fs}
	ctx := context.Background()
	now := t0.Add(400 * 24 * time.Hour)
	_ = store.Put(ctx, lapsedEntitlement("old", "t1", 300, now))
	_ = store.Put(ctx, lapsedEntitlement("soft", "t2", 70, now)) // inside the seal/soft-delete stages
	_ = store.Put(ctx, lapsedEntitlement("paid", "t3", -20, now))
	done := lapsedEntitlement("done", "t4", 300, now)
	done.DataDeletedAt = now
	_ = store.Put(ctx, done)
	due, err := store.Due(ctx, now, 10)
	if err != nil || len(due) != 1 || due[0].UID != "old" {
		t.Fatalf("due = %+v (%v)", due, err)
	}
}

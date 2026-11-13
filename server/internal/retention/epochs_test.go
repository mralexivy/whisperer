package retention_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// resetRig is a retention rig plus an account store holding one account that has been reset once (epoch 2) and
// whose epoch 1 was queued at t0.
func resetRig(t *testing.T, objectsInOldEpoch int) (*rig, *account.Memory) {
	r := newRig()
	accts := account.NewMemory()
	err := accts.Create(context.Background(), account.Creation{
		Account: account.Account{ID: "acct", Epoch: 1, CreatedAt: t0},
		SubKey:  "sub", Device: account.Device{ID: "dev", State: account.DeviceAuthorized},
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = accts.UpdateAccount(context.Background(), "acct", func(a *account.Account) error {
		a.EpochsToDelete = []account.PendingEpoch{{Epoch: 1, QueuedAt: *r.now}}
		a.Epoch = 2
		return nil
	})
	for i := 0; i < objectsInOldEpoch; i++ {
		r.blobs.Put(fmt.Sprintf("%saudio/%032x", syncplane.Prefix("whisperer", "acct", 1), i), 10, 0)
	}
	r.blobs.Put(syncplane.Prefix("whisperer", "acct", 2)+"audio/00000000000000000000000000000001", 10, 0)
	r.sweeper.Accounts = accts
	r.sweeper.EpochHold = time.Minute // short for these tests; TestAResetKeepsTheOldEpochForSevenDays uses the default
	return r, accts
}

func queued(a *account.Memory) int {
	acct, _, _ := a.GetAccount(context.Background(), "acct")
	return len(acct.EpochsToDelete)
}

func TestAResetEpochIsDeletedAfterTheStragglerGapAndTheNewEpochIsUntouched(t *testing.T) {
	r, accts := resetRig(t, 7)
	old, cur := syncplane.Prefix("whisperer", "acct", 1), syncplane.Prefix("whisperer", "acct", 2)

	*r.now = r.now.Add(2 * time.Minute)        // past the (short) hold
	rep := r.sweeper.Run(context.Background()) // deletes everything, but in-flight upload URLs may still land
	if r.blobs.Count(old) != 0 || len(rep.EpochsDeleted) != 0 || queued(accts) != 1 {
		t.Fatalf("first run: %d objects left, deleted=%v, queued=%d", r.blobs.Count(old), rep.EpochsDeleted, queued(accts))
	}
	r.blobs.Put(old+"audio/ffffffffffffffffffffffffffffffff", 10, 0) // a straggler upload that landed after the reset
	*r.now = r.now.Add(10 * time.Minute)
	r.sweeper.Run(context.Background())
	if r.blobs.Count(old) != 0 || queued(accts) != 1 {
		t.Fatal("inside the gap the entry stays queued even when the prefix is empty")
	}
	*r.now = r.now.Add(30 * time.Minute)
	rep = r.sweeper.Run(context.Background())
	if len(rep.EpochsDeleted) != 1 || rep.EpochsDeleted[0] != "acct/1" || queued(accts) != 0 {
		t.Fatalf("after the gap: %+v queued=%d", rep, queued(accts))
	}
	if r.blobs.Count(cur) != 1 {
		t.Fatal("the live epoch must never be touched")
	}
}

func TestTheCurrentEpochIsNeverDeletedEvenIfQueued(t *testing.T) {
	r, accts := resetRig(t, 3)
	_ = accts.UpdateAccount(context.Background(), "acct", func(a *account.Account) error {
		a.EpochsToDelete = []account.PendingEpoch{{Epoch: 2, QueuedAt: t0}} // a corrupt queue entry for the live epoch
		return nil
	})
	*r.now = r.now.Add(time.Hour)
	r.sweeper.Run(context.Background())
	if r.blobs.Count(syncplane.Prefix("whisperer", "acct", 2)) != 1 {
		t.Fatal("the live epoch was deleted")
	}
}

func TestEpochDeletionHonoursDryRun(t *testing.T) {
	r, accts := resetRig(t, 4)
	r.sweeper.DryRun = true
	*r.now = r.now.Add(time.Hour)
	rep := r.sweeper.Run(context.Background())
	if r.blobs.Count(syncplane.Prefix("whisperer", "acct", 1)) != 4 || len(rep.EpochsDryRun) != 1 || queued(accts) != 1 {
		t.Fatalf("dry run must report and delete nothing: %+v", rep)
	}
}

func TestEpochDeletionIsOffWithoutAnAccountStore(t *testing.T) {
	r, _ := resetRig(t, 2)
	r.sweeper.Accounts = nil
	r.sweeper.Run(context.Background())
	if r.blobs.Count(syncplane.Prefix("whisperer", "acct", 1)) != 2 {
		t.Fatal("nothing should be deleted when no account store is wired")
	}
}

func TestAResetKeepsTheOldEpochForSevenDays(t *testing.T) {
	r, accts := resetRig(t, 5)
	r.sweeper.EpochHold = 0 // the default: 7 days
	old := syncplane.Prefix("whisperer", "acct", 1)
	for _, after := range []time.Duration{time.Minute, 24 * time.Hour, 6*24*time.Hour + 23*time.Hour} {
		*r.now = t0.Add(400*24*time.Hour + after)
		r.sweeper.Run(context.Background())
		if r.blobs.Count(old) != 5 || queued(accts) != 1 {
			t.Fatalf("%v after the reset the old epoch must be untouched: %d objects, %d queued", after, r.blobs.Count(old), queued(accts))
		}
	}
}

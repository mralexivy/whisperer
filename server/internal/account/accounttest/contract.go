// Package accounttest is the behaviour every account.Store must have, run against Memory and Firestore.
package accounttest

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
)

var t0 = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

func creation(acct, sub, token, dev string) account.Creation {
	return account.Creation{
		Account: account.Account{ID: acct, CreatedAt: t0, AppAccountToken: token, Epoch: 1},
		SubKey:  sub,
		Device:  account.Device{ID: dev, PubKey: "pk-" + dev, State: account.DeviceAuthorized, EnrolledAt: t0},
	}
}

// Contract runs the shared store tests; mk returns a fresh empty store.
func Contract(t *testing.T, mk func(t *testing.T) account.Store) {
	ctx := context.Background()
	t.Run("create then resolve", func(t *testing.T) {
		s := mk(t)
		if err := s.Create(ctx, creation("a1", "sub1", "tok1", "d1")); err != nil {
			t.Fatal(err)
		}
		if id, ok, _ := s.ResolveSub(ctx, "sub1"); !ok || id != "a1" {
			t.Fatalf("sub: %q %v", id, ok)
		}
		if id, ok, _ := s.ResolveToken(ctx, "tok1"); !ok || id != "a1" {
			t.Fatalf("token: %q %v", id, ok)
		}
		if _, ok, _ := s.ResolveSub(ctx, "nope"); ok {
			t.Fatal("unknown sub resolved")
		}
		a, ok, _ := s.GetAccount(ctx, "a1")
		if !ok || a.Epoch != 1 || a.AppAccountToken != "tok1" {
			t.Fatalf("account: %+v", a)
		}
		d, ok, _ := s.GetDevice(ctx, "d1")
		if !ok || d.AccountID != "a1" || d.State != account.DeviceAuthorized {
			t.Fatalf("device: %+v", d)
		}
	})
	t.Run("create refusals write nothing", func(t *testing.T) {
		s := mk(t)
		if err := s.Create(ctx, creation("a1", "sub1", "tok1", "d1")); err != nil {
			t.Fatal(err)
		}
		cases := []struct {
			name string
			c    account.Creation
			want error
		}{
			{"same subscription", creation("a2", "sub1", "tok2", "d2"), account.ErrBound},
			{"same purchase token", creation("a3", "sub3", "tok1", "d3"), account.ErrBound},
			{"same device key", creation("a4", "sub4", "tok4", "d1"), account.ErrDeviceBound},
		}
		for _, tc := range cases {
			if err := s.Create(ctx, tc.c); !errors.Is(err, tc.want) {
				t.Errorf("%s: got %v want %v", tc.name, err, tc.want)
			}
			if _, ok, _ := s.GetAccount(ctx, tc.c.Account.ID); ok {
				t.Errorf("%s: a refused creation left an account behind", tc.name)
			}
			if _, ok, _ := s.ResolveSub(ctx, tc.c.SubKey); ok && tc.c.SubKey != "sub1" {
				t.Errorf("%s: a refused creation left a subscription mapping", tc.name)
			}
		}
	})
	t.Run("bind subscription", func(t *testing.T) {
		s := mk(t)
		_ = s.Create(ctx, creation("a1", "sub1", "tok1", "d1"))
		_ = s.Create(ctx, creation("a2", "sub2", "tok2", "d2"))
		if err := s.BindSub(ctx, "a1", "sub9"); err != nil {
			t.Fatal(err)
		}
		if err := s.BindSub(ctx, "a1", "sub9"); err != nil {
			t.Fatalf("idempotent bind: %v", err)
		}
		if err := s.BindSub(ctx, "a2", "sub9"); !errors.Is(err, account.ErrBound) {
			t.Fatalf("binding another account's subscription: %v", err)
		}
		if id, _, _ := s.ResolveSub(ctx, "sub9"); id != "a1" {
			t.Fatalf("sub9 -> %q", id)
		}
	})
	t.Run("update account", func(t *testing.T) {
		s := mk(t)
		_ = s.Create(ctx, creation("a1", "sub1", "tok1", "d1"))
		err := s.UpdateAccount(ctx, "a1", func(a *account.Account) error {
			a.Library = account.Library{Exists: true, KeyVersion: 1, Verifier: "v", Recovery: &account.Recovery{Wrapped: "w", Kdf: "k"}}
			a.EpochsToDelete = append(a.EpochsToDelete, account.PendingEpoch{Epoch: 1, QueuedAt: t0})
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		a, _, _ := s.GetAccount(ctx, "a1")
		if !a.Library.Exists || a.Library.Recovery == nil || a.Library.Recovery.Wrapped != "w" || len(a.EpochsToDelete) != 1 || a.EpochQueue != "pending" {
			t.Fatalf("after update: %+v", a)
		}
		boom := errors.New("boom")
		if err := s.UpdateAccount(ctx, "a1", func(a *account.Account) error { a.Epoch = 99; return boom }); !errors.Is(err, boom) {
			t.Fatalf("callback error: %v", err)
		}
		if a, _, _ := s.GetAccount(ctx, "a1"); a.Epoch != 1 {
			t.Fatal("a failed callback must not write")
		}
		if err := s.UpdateAccount(ctx, "missing", func(*account.Account) error { return nil }); !errors.Is(err, account.ErrNotFound) {
			t.Fatalf("missing account: %v", err)
		}
		pend, err := s.PendingEpochs(ctx, 10)
		if err != nil || len(pend) != 1 || pend[0].ID != "a1" {
			t.Fatalf("pending epochs: %+v %v", pend, err)
		}
		_ = s.UpdateAccount(ctx, "a1", func(a *account.Account) error { a.EpochsToDelete = nil; return nil })
		if pend, _ := s.PendingEpochs(ctx, 10); len(pend) != 0 {
			t.Fatalf("queue should be empty: %+v", pend)
		}
	})
	t.Run("devices", func(t *testing.T) {
		s := mk(t)
		_ = s.Create(ctx, creation("a1", "sub1", "tok1", "d1"))
		_ = s.Create(ctx, creation("a2", "sub2", "tok2", "d2"))
		pending := account.Device{ID: "d3", AccountID: "a1", PubKey: "pk", State: account.DevicePending, EnrolledAt: t0.Add(time.Minute), PurgeAt: t0.Add(account.PendingTTL), EnrollChallenge: "c"}
		if err := s.PutDevice(ctx, pending); err != nil {
			t.Fatal(err)
		}
		if err := s.PutDevice(ctx, pending); err != nil {
			t.Fatalf("re-enrolling the same device on the same account: %v", err)
		}
		stolen := pending
		stolen.AccountID = "a2"
		if err := s.PutDevice(ctx, stolen); !errors.Is(err, account.ErrDeviceBound) {
			t.Fatalf("a device key cannot move between accounts: %v", err)
		}
		list, _ := s.ListDevices(ctx, "a1")
		if len(list) != 2 || list[0].ID != "d1" || list[1].ID != "d3" || list[1].EnrollChallenge != "c" || list[1].PurgeAt.IsZero() {
			t.Fatalf("list: %+v", list)
		}
		if other, _ := s.ListDevices(ctx, "a2"); len(other) != 1 {
			t.Fatalf("accounts must not see each other's devices: %+v", other)
		}
		err := s.UpdateDevice(ctx, "d3", func(d *account.Device) error {
			d.State, d.EnrollChallenge, d.PurgeAt = account.DeviceAuthorized, "", time.Time{}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		d, _, _ := s.GetDevice(ctx, "d3")
		if d.State != account.DeviceAuthorized || d.EnrollChallenge != "" || !d.PurgeAt.IsZero() {
			t.Fatalf("after confirm: %+v", d)
		}
		if err := s.UpdateDevice(ctx, "ghost", func(*account.Device) error { return nil }); !errors.Is(err, account.ErrNotFound) {
			t.Fatalf("missing device: %v", err)
		}
	})
}

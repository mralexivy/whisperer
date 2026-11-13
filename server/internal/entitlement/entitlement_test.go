package entitlement_test

import (
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
)

var t0 = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

func day(n int) time.Duration { return time.Duration(n) * 24 * time.Hour }

func tx(expires time.Time) apple.Transaction {
	return apple.Transaction{OriginalTransactionID: "1000", ProductID: "cloud.monthly", Environment: "Production", ExpiresDate: expires.UnixMilli()}
}

func TestLifecycleActiveGraceLapsedDeleted(t *testing.T) {
	e := entitlement.FromTransaction(nil, "u", tx(t0.Add(day(30))), t0)
	renewal := apple.RenewalInfo{GracePeriodExpiresDate: t0.Add(day(30 + 16)).UnixMilli()}
	e, _ = entitlement.ApplyNotification(e, apple.Notification{NotificationType: "DID_FAIL_TO_RENEW", NotificationUUID: "n1"}, nil, &renewal, t0)

	cases := []struct {
		at    time.Time
		state entitlement.State
		write bool
		read  bool
	}{
		{t0.Add(day(10)), entitlement.Active, true, true},
		{t0.Add(day(30) + time.Hour), entitlement.Grace, true, true},
		{t0.Add(day(46) + time.Hour), entitlement.Lapsed, false, true},
		{t0.Add(day(46 + 59)), entitlement.Lapsed, false, true},
		{t0.Add(day(46+60) + time.Hour), entitlement.Deleted, false, false},
	}
	for _, c := range cases {
		if got := e.StateAt(c.at); got != c.state || e.CanWrite(c.at) != c.write || e.CanRead(c.at) != c.read {
			t.Errorf("at +%v: state %s write %v read %v; want %s %v %v", c.at.Sub(t0), got, e.CanWrite(c.at), e.CanRead(c.at), c.state, c.write, c.read)
		}
	}
	if want := t0.Add(day(46 + 60)); !e.DeleteAfter.Equal(want) {
		t.Errorf("DeleteAfter = %v, want %v", e.DeleteAfter, want)
	}
}

func TestAStaleTransactionNeverShortensAPaidPeriod(t *testing.T) {
	e := entitlement.FromTransaction(nil, "u", tx(t0.Add(day(60))), t0)
	e = entitlement.FromTransaction(&e, "u", tx(t0.Add(day(5))), t0) // an old JWS cached on a Mac
	if !e.ExpiresAt.Equal(t0.Add(day(60))) {
		t.Fatalf("expiry moved backwards to %v", e.ExpiresAt)
	}
}

func TestARefundLapsesAtOnceAndStaysLapsed(t *testing.T) {
	e := entitlement.FromTransaction(nil, "u", tx(t0.Add(day(25))), t0)
	e, changed := entitlement.ApplyNotification(e, apple.Notification{NotificationType: "REFUND", NotificationUUID: "r1", SignedDate: t0.Add(day(2)).UnixMilli()}, nil, nil, t0.Add(day(2)))
	if !changed || e.StateAt(t0.Add(day(3))) != entitlement.Lapsed || e.CanWrite(t0.Add(day(3))) {
		t.Fatal("a refund must lapse immediately")
	}
	// A later renewal-looking transaction does not undo a revocation.
	e = entitlement.FromTransaction(&e, "u", tx(t0.Add(day(90))), t0.Add(day(4)))
	if e.CanWrite(t0.Add(day(5))) {
		t.Fatal("a revocation is permanent")
	}
	if want := t0.Add(day(2) + entitlement.Retention); !e.DeleteAfter.Equal(want) {
		t.Fatalf("DeleteAfter %v want %v", e.DeleteAfter, want)
	}
}

func TestNotificationsAreIdempotent(t *testing.T) {
	e := entitlement.FromTransaction(nil, "u", tx(t0.Add(day(30))), t0)
	n := apple.Notification{NotificationType: "DID_RENEW", NotificationUUID: "same"}
	renewed := tx(t0.Add(day(60)))
	e, changed := entitlement.ApplyNotification(e, n, &renewed, nil, t0)
	if !changed || !e.ExpiresAt.Equal(t0.Add(day(60))) {
		t.Fatal("first delivery applies")
	}
	again, changed := entitlement.ApplyNotification(e, n, &renewed, nil, t0.Add(time.Hour))
	if changed || !again.UpdatedAt.Equal(e.UpdatedAt) {
		t.Fatal("a retried notification must change nothing")
	}
}

func TestSeenListIsBounded(t *testing.T) {
	e := entitlement.FromTransaction(nil, "u", tx(t0.Add(day(30))), t0)
	for i := 0; i < 40; i++ {
		e, _ = entitlement.ApplyNotification(e, apple.Notification{NotificationType: "DID_RENEW", NotificationUUID: string(rune('a' + i))}, nil, nil, t0)
	}
	if len(e.SeenNotifications) != 16 {
		t.Fatalf("kept %d notification ids, want 16", len(e.SeenNotifications))
	}
}

func TestAutoRenewFollowsTheRenewalInfo(t *testing.T) {
	e := entitlement.FromTransaction(nil, "u", tx(t0.Add(day(30))), t0)
	off := apple.RenewalInfo{AutoRenewStatus: 0}
	e, _ = entitlement.ApplyNotification(e, apple.Notification{NotificationType: "DID_CHANGE_RENEWAL_STATUS", NotificationUUID: "a"}, nil, &off, t0)
	if e.AutoRenew {
		t.Fatal("auto-renew should be off")
	}
}

func TestMemoryStoreFindsDueAndByTransaction(t *testing.T) {
	m := entitlement.NewMemory()
	old := entitlement.FromTransaction(nil, "old", tx(t0.Add(-day(200))), t0)
	fresh := entitlement.FromTransaction(nil, "fresh", apple.Transaction{OriginalTransactionID: "2000", ExpiresDate: t0.Add(day(30)).UnixMilli()}, t0)
	ctx := t.Context()
	_ = m.Put(ctx, old)
	_ = m.Put(ctx, fresh)
	due, _ := m.Due(ctx, t0, 10)
	if len(due) != 1 || due[0].UID != "old" {
		t.Fatalf("due = %+v", due)
	}
	got, ok, _ := m.ByOriginalTransactionID(ctx, "2000")
	if !ok || got.UID != "fresh" {
		t.Fatal("lookup by original transaction id")
	}
}

package server_test

import (
	"strings"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

func TestAccountCreationThenSessionThenAccount(t *testing.T) {
	r := newRig(t, false)
	m, token := r.signup()
	code, acct := r.do("GET", "/v1/account", nil, token)
	if code != 200 || acct["state"] != "active" {
		t.Fatalf("account: %d %v", code, acct)
	}
	if plan := acct["plan"].(map[string]any); plan["name"] != "standard" || plan["storedBytes"].(float64) != 25*1024*1024*1024 {
		t.Fatalf("plan: %v", plan)
	}
	code, body := r.session(m, "")
	if code != 200 || body["state"] != "active" || body["readOnly"] != false || body["accountId"] != acct["accountId"] {
		t.Fatalf("session: %d %v", code, body)
	}
}

func TestTheSameSubscriptionIsTheSameAccountOnEveryMac(t *testing.T) {
	r := newRig(t, false)
	m1, tok1 := r.signup()
	r.withLibrary(tok1)
	m2, tok2 := r.enrolConfirmed()
	id1, id2 := r.accountID(m1), r.accountID(m2)
	if id1 != id2 {
		t.Fatalf("two Macs, one subscription, two accounts: %s %s", id1, id2)
	}
	if len(id1) != 32 || strings.Contains(id1, "1000") || id1 == r.srv.SubKey("1000") {
		t.Fatalf("the account id must be a random 128-bit id, not derived from the transaction id: %q", id1)
	}
	if len(r.srv.SubKey("1000")) != 64 || r.srv.SubKey("1000") == "1000" {
		t.Fatal("subKey must be an HMAC, never the raw transaction id")
	}
	for _, tok := range []string{tok1, tok2} {
		if code, acct := r.do("GET", "/v1/account", nil, tok); code != 200 || acct["accountId"] != id1 {
			t.Fatalf("both Macs see the one account: %d %v", code, acct)
		}
	}
	e, ok, _ := r.store.ByOriginalTransactionID(t.Context(), "1000")
	if !ok || e.UID != id1 {
		t.Fatalf("the entitlement is keyed by the account id, got %q", e.UID)
	}
	other := newRig(t, false)
	if other.srv.SubKey("1000") != r.srv.SubKey("1000") {
		t.Fatal("the subKey must be deterministic for a given secret")
	}
	if id, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("1000")); !ok || id != id1 {
		t.Fatalf("subscriptions/{subKey} -> %q", id)
	}
	if id, ok, _ := r.accounts.ResolveToken(t.Context(), "6f1c2d3e-0000-4000-8000-000000000001"); !ok || id != id1 {
		t.Fatalf("tokens/{appAccountToken} -> %q", id)
	}
}

func TestRefusesAForgedPurchase(t *testing.T) {
	r := newRig(t, false)
	forged := r.apple.JWSWith(t, map[string]any{"originalTransactionId": "1", "signedDate": now.UnixMilli()}, testkit.OtherKey(t), true)
	if code, _ := r.createAccount(r.newMac(), forged); code != 401 {
		t.Fatalf("forged purchase: %d", code)
	}
}

func TestRefusesOtherAppsProductsAndTestPurchases(t *testing.T) {
	r := newRig(t, false)
	cases := map[string]map[string]any{
		"wrong_app":         {"bundleId": "com.someone.else"},
		"wrong_product":     {"productId": "pro.pack"},
		"wrong_environment": {"environment": "Sandbox"},
	}
	for want, o := range cases {
		code, body := r.createAccount(r.newMac(), r.tx(o))
		if code != 403 || body["error"] != want {
			t.Errorf("%s: %d %v", want, code, body)
		}
	}
	sb := newRig(t, true)
	if code, _ := sb.createAccount(sb.newMac(), sb.tx(map[string]any{"environment": "Sandbox"})); code != 201 {
		t.Errorf("sandbox purchases must be accepted when configured (code %d)", code)
	}
}

func TestLapsedUsersGetAReadOnlySessionAndEndedOnesNone(t *testing.T) {
	r := newRig(t, false)
	lapsed := r.tx(map[string]any{"expiresDate": now.Add(-10 * 24 * time.Hour).UnixMilli()})
	code, body := r.createAccount(r.newMac(), lapsed)
	if code != 201 || body["state"] != "lapsed" || body["readOnly"] != true {
		t.Fatalf("lapsed: %d %v", code, body)
	}
	gone := r.tx(map[string]any{"originalTransactionId": "2000", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000002", "expiresDate": now.Add(-200 * 24 * time.Hour).UnixMilli()})
	if code, body := r.createAccount(r.newMac(), gone); code != 402 || body["error"] != "subscription_expired" {
		t.Fatalf("ended: %d %v", code, body)
	}
}

func TestAccountNeedsASession(t *testing.T) {
	r := newRig(t, false)
	for _, token := range []string{"", "garbage", "a.b.c"} {
		if code, _ := r.do("GET", "/v1/account", nil, token); code != 401 {
			t.Errorf("token %q: %d", token, code)
		}
	}
}

func notification(r *rig, kind, uuid string, tx string, signed time.Time) string {
	return r.apple.JWS(r.t, map[string]any{
		"notificationType": kind, "notificationUUID": uuid, "signedDate": signed.UnixMilli(),
		"data": map[string]any{"environment": "Production", "bundleId": "com.ivy.whisperer", "signedTransactionInfo": tx},
	})
}

func TestARefundNotificationLapsesTheAccount(t *testing.T) {
	r := newRig(t, false)
	m, token := r.signup()
	refund := notification(r, "REFUND", "n-1", r.tx(map[string]any{"revocationDate": now.UnixMilli()}), now)
	if code, out := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": refund}, ""); code != 200 || out["applied"] != true {
		t.Fatalf("notification: %d %v", code, out)
	}
	if _, acct := r.do("GET", "/v1/account", nil, token); acct["state"] != "lapsed" {
		t.Fatalf("after refund: %v", acct)
	}
	// Apple retries: nothing changes the second time.
	if _, out := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": refund}, ""); out["applied"] != false {
		t.Fatalf("replay applied again: %v", out)
	}
	// A new session cannot buy the refund back.
	if _, again := r.session(m, r.tx(nil)); again["readOnly"] != true {
		t.Fatalf("refunded subscription got write access: %v", again)
	}
}

func TestNotificationsMustBeSignedByApple(t *testing.T) {
	r := newRig(t, false)
	forged := r.apple.JWSWith(t, map[string]any{"notificationType": "REFUND", "notificationUUID": "x", "signedDate": now.UnixMilli()}, testkit.OtherKey(t), true)
	if code, _ := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": forged}, ""); code != 400 {
		t.Fatalf("forged notification: %d", code)
	}
	if code, _ := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": "x"}, ""); code != 400 {
		t.Fatalf("garbage notification: %d", code)
	}
}

func TestNotificationsForOtherAppsAreAcknowledgedAndIgnored(t *testing.T) {
	r := newRig(t, false)
	other := r.apple.JWS(t, map[string]any{
		"notificationType": "SUBSCRIBED", "notificationUUID": "o-1", "signedDate": now.UnixMilli(),
		"data": map[string]any{"environment": "Production", "bundleId": "com.another.app"},
	})
	if code, _ := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": other}, ""); code != 200 {
		t.Fatalf("Apple must not be told to retry: %d", code)
	}
}

func TestANotificationNeverCreatesOrBindsAnAccount(t *testing.T) {
	r := newRig(t, false)
	n := notification(r, "SUBSCRIBED", "s-1", r.tx(map[string]any{"originalTransactionId": "5000"}), now)
	code, out := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": n}, "")
	if code != 200 || out["ignored"] != "unbound_subscription" {
		t.Fatalf("unbound subscription: %d %v", code, out)
	}
	if _, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("5000")); ok {
		t.Fatal("a notification bound a subscription")
	}
	// A bound account's older subscription is ignored once a newer one is the entitlement.
	m, token := r.signup()
	_ = token
	_, _ = r.session(m, r.tx(map[string]any{"originalTransactionId": "1500", "transactionId": "1501"}))
	old := notification(r, "DID_RENEW", "s-2", r.tx(nil), now)
	if _, out := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": old}, ""); out["ignored"] != "superseded_subscription" {
		t.Fatalf("older chain: %v", out)
	}
}

func TestRateLimitBluntsARunawayClient(t *testing.T) {
	r2 := newLimitedRig(t, 30)
	limited := 0
	for i := 0; i < 60; i++ {
		if code, _ := r2.do("GET", "/v1/account", nil, ""); code == 429 {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("60 requests in a minute from one address were all served")
	}
	if code, _ := r2.do("GET", "/v1/health", nil, ""); code != 200 {
		t.Fatal("health checks must never be limited")
	}
	if code, _ := r2.do("POST", "/v1/auth/challenge", map[string]string{"deviceId": "0123456789abcdef0123456789abcdef"}, ""); code != 429 {
		t.Fatal("the challenge endpoint is IP-limited too")
	}
}

func entitlementTx(id string, expires time.Time) apple.Transaction {
	return apple.Transaction{OriginalTransactionID: id, ProductID: "com.ivy.whisperer.cloud.standard.monthly", Environment: "Production", ExpiresDate: expires.UnixMilli()}
}

func TestAnUpgradeChangesThePlanOnTheNextSession(t *testing.T) {
	r := newRig(t, false)
	m := r.newMac()
	_, first := r.createAccount(m, r.tx(map[string]any{"productId": "com.ivy.whisperer.cloud.starter.monthly"}))
	if first["plan"].(map[string]any)["name"] != "starter" {
		t.Fatalf("first plan: %v", first["plan"])
	}
	_, second := r.session(m, r.tx(map[string]any{"productId": "com.ivy.whisperer.cloud.large.monthly", "transactionId": "1500"}))
	if second["plan"].(map[string]any)["name"] != "large" {
		t.Fatalf("after upgrade: %v", second["plan"])
	}
}

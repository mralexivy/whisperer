package server_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/server"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

var now = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

type deleter struct {
	mu      sync.Mutex
	deleted []string
}

func (d *deleter) DeleteUser(_ context.Context, uid string) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.deleted = append(d.deleted, uid)
	return nil
}

type rig struct {
	t     *testing.T
	apple *testkit.Apple
	srv   *server.Server
	h     http.Handler
	store *entitlement.Memory
	del   *deleter
	clock *time.Time
}

func newRig(t *testing.T, allowSandbox bool) *rig {
	a := testkit.New(t, now)
	clock := now
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	_ = pub
	store := entitlement.NewMemory()
	del := &deleter{}
	cfg := server.Config{
		BundleID: "com.ivy.whisperer", AllowSandbox: allowSandbox, UIDSecret: []byte("test-secret"),
		Now: func() time.Time { return clock },
	}
	a.Now = clock
	s := server.New(cfg, a.Verifier, store, auth.NewSigner(priv, "k1"), del, nil)
	return &rig{t: t, apple: a, srv: s, h: s.Handler(), store: store, del: del, clock: &clock}
}

func (r *rig) tx(overrides map[string]any) string {
	p := map[string]any{
		"originalTransactionId": "1000", "transactionId": "1001", "bundleId": "com.ivy.whisperer",
		"productId": "com.ivy.whisperer.cloud.standard.monthly", "type": "Auto-Renewable Subscription", "environment": "Production",
		"expiresDate": now.Add(30 * 24 * time.Hour).UnixMilli(), "signedDate": now.UnixMilli(),
	}
	for k, v := range overrides {
		p[k] = v
	}
	return r.apple.JWS(r.t, p)
}

func (r *rig) do(method, path string, body any, token string) (int, map[string]any) {
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	req.RemoteAddr = "203.0.113.7:4000"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	r.h.ServeHTTP(rec, req)
	out := map[string]any{}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func (r *rig) session(jws, device string) (int, map[string]any) {
	return r.do("POST", "/v1/session", map[string]string{"transactionJWS": jws, "deviceID": device}, "")
}

func TestSessionThenAccount(t *testing.T) {
	r := newRig(t, false)
	code, body := r.session(r.tx(nil), "mac-1")
	if code != 200 || body["state"] != "active" || body["readOnly"] != false {
		t.Fatalf("session: %d %v", code, body)
	}
	token := body["token"].(string)
	code, acct := r.do("GET", "/v1/account", nil, token)
	if code != 200 || acct["state"] != "active" {
		t.Fatalf("account: %d %v", code, acct)
	}
	if plan := acct["plan"].(map[string]any); plan["name"] != "standard" || plan["storedBytes"].(float64) != 25*1024*1024*1024 {
		t.Fatalf("plan: %v", plan)
	}
}

func TestTheSameSubscriptionIsTheSameUserOnEveryMac(t *testing.T) {
	r := newRig(t, false)
	_, a := r.session(r.tx(nil), "mac-1")
	_, b := r.session(r.tx(map[string]any{"transactionId": "1002"}), "mac-2")
	uid := r.srv.UID("1000")
	if uid == "" || uid == "1000" || len(uid) != 32 {
		t.Fatalf("uid should be an opaque 128-bit id, got %q", uid)
	}
	e, ok, _ := r.store.ByOriginalTransactionID(t.Context(), "1000")
	if !ok || e.UID != uid {
		t.Fatalf("the subscriber record is keyed by %q, want %q", e.UID, uid)
	}
	for _, tok := range []string{a["token"].(string), b["token"].(string)} {
		if code, acct := r.do("GET", "/v1/account", nil, tok); code != 200 || acct["state"] != "active" {
			t.Fatalf("both Macs see the one account: %d %v", code, acct)
		}
	}
	if newRig(t, false).srv.UID("1000") != uid {
		t.Fatal("the uid must be deterministic for a given secret")
	}
}

func TestRefusesAForgedPurchase(t *testing.T) {
	r := newRig(t, false)
	forged := r.apple.JWSWith(t, map[string]any{"originalTransactionId": "1", "signedDate": now.UnixMilli()}, testkit.OtherKey(t), true)
	if code, _ := r.session(forged, "d"); code != 401 {
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
		code, body := r.session(r.tx(o), "d")
		if code != 403 || body["error"] != want {
			t.Errorf("%s: %d %v", want, code, body)
		}
	}
	sb := newRig(t, true)
	if code, _ := sb.session(sb.tx(map[string]any{"environment": "Sandbox"}), "d"); code != 200 {
		t.Errorf("sandbox purchases must be accepted when configured (code %d)", code)
	}
}

func TestLapsedUsersGetAReadOnlySessionAndEndedOnesNone(t *testing.T) {
	r := newRig(t, false)
	lapsed := r.tx(map[string]any{"expiresDate": now.Add(-10 * 24 * time.Hour).UnixMilli()})
	code, body := r.session(lapsed, "d")
	if code != 200 || body["state"] != "lapsed" || body["readOnly"] != true {
		t.Fatalf("lapsed: %d %v", code, body)
	}
	gone := r.tx(map[string]any{"originalTransactionId": "2000", "expiresDate": now.Add(-200 * 24 * time.Hour).UnixMilli()})
	if code, body := r.session(gone, "d"); code != 402 || body["error"] != "subscription_expired" {
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
	_, body := r.session(r.tx(nil), "d")
	token := body["token"].(string)
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
	if _, again := r.session(r.tx(nil), "d"); again["readOnly"] != true {
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

func TestARenewalNotificationCreatesAMissingAccount(t *testing.T) {
	r := newRig(t, false)
	n := notification(r, "SUBSCRIBED", "s-1", r.tx(map[string]any{"originalTransactionId": "5000"}), now)
	if code, _ := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": n}, ""); code != 200 {
		t.Fatal("subscribe notification failed")
	}
	if _, ok, _ := r.store.Get(t.Context(), r.srv.UID("5000")); !ok {
		t.Fatal("subscriber was not recorded")
	}
}

func TestRetentionSweepDeletesOnlyThoseWhoseTimeIsUp(t *testing.T) {
	r := newRig(t, false)
	old := entitlement.FromTransaction(nil, "gone", entitlementTx("7000", now.Add(-300*24*time.Hour)), now)
	live := entitlement.FromTransaction(nil, "live", entitlementTx("7001", now.Add(30*24*time.Hour)), now)
	_ = r.store.Put(t.Context(), old)
	_ = r.store.Put(t.Context(), live)
	r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": notification(r, "DID_RENEW", "sw-1", r.tx(map[string]any{"originalTransactionId": "7002"}), now)}, "")
	if len(r.del.deleted) != 1 || r.del.deleted[0] != "gone" {
		t.Fatalf("deleted = %v", r.del.deleted)
	}
	got, _, _ := r.store.Get(t.Context(), "gone")
	if got.DataDeletedAt.IsZero() {
		t.Fatal("deletion not recorded")
	}
	r.del.deleted = nil
	r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": notification(r, "DID_RENEW", "sw-2", r.tx(map[string]any{"originalTransactionId": "7002"}), now)}, "")
	if len(r.del.deleted) != 0 {
		t.Fatalf("a deleted user must not be deleted twice: %v", r.del.deleted)
	}
}

func TestRateLimitBluntsARunawayClient(t *testing.T) {
	r := newRig(t, false)
	limited := 0
	for i := 0; i < 60; i++ {
		if code, _ := r.do("GET", "/v1/account", nil, ""); code == 429 {
			limited++
		}
	}
	if limited == 0 {
		t.Fatal("60 requests in a minute from one address were all served")
	}
	if code, _ := r.do("GET", "/healthz", nil, ""); code != 200 {
		t.Fatal("health checks must never be limited")
	}
}

func entitlementTx(id string, expires time.Time) apple.Transaction {
	return apple.Transaction{OriginalTransactionID: id, ProductID: "com.ivy.whisperer.cloud.standard.monthly", Environment: "Production", ExpiresDate: expires.UnixMilli()}
}

func TestAnUpgradeChangesThePlanOnTheNextSession(t *testing.T) {
	r := newRig(t, false)
	_, first := r.session(r.tx(map[string]any{"productId": "com.ivy.whisperer.cloud.starter.monthly"}), "d")
	if first["plan"].(map[string]any)["name"] != "starter" {
		t.Fatalf("first plan: %v", first["plan"])
	}
	_, second := r.session(r.tx(map[string]any{"productId": "com.ivy.whisperer.cloud.large.monthly", "transactionId": "1500"}), "d")
	if second["plan"].(map[string]any)["name"] != "large" {
		t.Fatalf("after upgrade: %v", second["plan"])
	}
}

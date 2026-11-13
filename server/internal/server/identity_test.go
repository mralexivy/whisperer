package server_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/devauth"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

func TestChallenge(t *testing.T) {
	r := newRig(t, false)
	cases := []struct {
		name string
		body any
		want int
	}{
		{"valid", map[string]string{"deviceId": "0123456789abcdef0123456789abcdef"}, 200},
		{"too short", map[string]string{"deviceId": "abc"}, 400},
		{"uppercase", map[string]string{"deviceId": "0123456789ABCDEF0123456789ABCDEF"}, 400},
		{"missing", map[string]string{}, 400},
		{"not json", "x", 400},
	}
	for _, tc := range cases {
		code, body := r.do("POST", "/v1/auth/challenge", tc.body, "")
		if code != tc.want {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
		if code == 200 && (len(body["nonce"].(string)) != 64 || body["serverTime"] == nil) {
			t.Errorf("%s: %v", tc.name, body)
		}
	}
}

// refusals shared by every route that takes a device signature over a fresh nonce.
func TestDeviceSignatureRefusals(t *testing.T) {
	r := newRig(t, false)
	m, _ := r.signup()
	attacker := r.newMac()
	jws := r.tx(map[string]any{"originalTransactionId": "7000", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000007"})
	good := func(purpose string) map[string]any {
		return merge(map[string]any{"transactionJWS": jws, "devicePublicKey": m.pub}, r.signed(m, purpose))
	}
	staleNonce := r.challenge(m.id)
	staleSig, _ := devauth.Sign(m.key, staleNonce, devauth.PurposeAccountCreate)
	*r.clock = r.clock.Add(3 * time.Minute)

	forged := good(devauth.PurposeAccountCreate)
	forged["sig"], _ = devauth.Sign(attacker.key, forged["nonce"].(string), devauth.PurposeAccountCreate)
	wrongPurpose := good(devauth.PurposeSession)
	otherDeviceNonce := good(devauth.PurposeAccountCreate)
	otherDeviceNonce["nonce"] = r.challenge(attacker.id)
	expired := map[string]any{"transactionJWS": jws, "devicePublicKey": m.pub, "nonce": staleNonce, "sig": staleSig}
	badKey := good(devauth.PurposeAccountCreate)
	badKey["devicePublicKey"] = "AAAA"
	garbageSig := good(devauth.PurposeAccountCreate)
	garbageSig["sig"] = "not-a-signature"

	cases := []struct {
		name  string
		body  map[string]any
		code  int
		error string
	}{
		{"forged signature", forged, 401, "bad_signature"},
		{"signature made for another route", wrongPurpose, 401, "bad_signature"},
		{"nonce issued for another device", otherDeviceNonce, 401, "bad_nonce"},
		{"nonce outside the 120 s window", expired, 401, "bad_nonce"},
		{"malformed device key", badKey, 400, "bad_device_key"},
		{"garbage signature", garbageSig, 401, "bad_signature"},
	}
	for _, route := range []string{"/v1/accounts", "/v1/devices"} {
		for _, tc := range cases {
			code, body := r.do("POST", route, tc.body, "")
			if code != tc.code || body["error"] != tc.error {
				t.Errorf("%s %s: %d %v", route, tc.name, code, body)
			}
		}
	}
}

func TestCreateAccountRefusals(t *testing.T) {
	r := newRig(t, false)
	_, _ = r.signup()
	m2 := r.newMac()
	cases := []struct {
		name  string
		mac   *mac
		jws   string
		code  int
		error string
	}{
		{"subscription already bound", m2, r.tx(nil), 409, "already_bound"},
		{"new subscription id, same purchase token", m2, r.tx(map[string]any{"originalTransactionId": "1111"}), 409, "already_bound"},
		{"invalid transaction", m2, "garbage", 401, "invalid_transaction"},
		{"forged transaction", m2, r.apple.JWSWith(t, map[string]any{"originalTransactionId": "9"}, testkit.OtherKey(t), true), 401, "invalid_transaction"},
		{"no transaction", m2, "", 400, "bad_request"},
	}
	for _, tc := range cases {
		code, body := r.createAccount(tc.mac, tc.jws)
		if code != tc.code || body["error"] != tc.error {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	if _, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("1111")); ok {
		t.Error("a refused creation must not leave a mapping")
	}
}

func TestCreateAccountRefusesADeviceKeyThatBelongsToAnotherAccount(t *testing.T) {
	r := newRig(t, false)
	m, _ := r.signup()
	code, body := r.createAccount(m, r.tx(map[string]any{"originalTransactionId": "2222", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000022"}))
	if code != 409 || body["error"] != "device_bound" {
		t.Fatalf("%d %v", code, body)
	}
	if _, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("2222")); ok {
		t.Fatal("a refused creation must not leave a mapping")
	}
}

func TestCreateAccountWithoutAPurchaseTokenStillWorksAndMapsBySubscription(t *testing.T) {
	r := newRig(t, false)
	m := r.newMac()
	code, body := r.createAccount(m, r.tx(map[string]any{"appAccountToken": ""}))
	if code != 201 {
		t.Fatalf("%d %v", code, body)
	}
	if _, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("1000")); !ok {
		t.Fatal("subscription mapping missing")
	}
}

func TestEnrollAndConfirmANewMac(t *testing.T) {
	r := newRig(t, false)
	_, tok1 := r.signup()
	r.withLibrary(tok1)
	m2 := r.newMac()
	code, body := r.enroll(m2, r.tx(nil))
	if code != 200 {
		t.Fatalf("enroll: %d %v", code, body)
	}
	lib := body["library"].(map[string]any)
	if lib["exists"] != true || lib["keyVersion"].(float64) != 1 || lib["recoveryAvailable"] != true {
		t.Fatalf("library info: %v", lib)
	}
	for _, leak := range []string{"token", "accountId", "epoch", "wrapped", "verifier"} {
		if _, present := body[leak]; present {
			t.Errorf("a pending device must not learn %q: %v", leak, body)
		}
	}
	challenge := body["enrollChallenge"].(string)
	// A JWS alone never reaches data: the pending device has no session, and cannot get one.
	if code, b := r.session(m2, r.tx(nil)); code != 403 || b["error"] != "device_pending" {
		t.Fatalf("pending device session: %d %v", code, b)
	}
	if code, b := r.confirm(m2, "00"+proofFor(m2, challenge, "")[2:]); code != 403 || b["error"] != "bad_key_proof" {
		t.Fatalf("wrong proof: %d %v", code, b)
	}
	code, b := r.confirm(m2, proofFor(m2, challenge, ""))
	if code != 200 || b["token"] == "" || b["accountId"] != r.accountID(m2) || b["epoch"].(float64) != 1 {
		t.Fatalf("confirm: %d %v", code, b)
	}
	if code, _ := r.session(m2, ""); code != 200 {
		t.Fatal("the confirmed device now has sessions")
	}
	d, _, _ := r.accounts.GetDevice(t.Context(), m2.id)
	if d.State != account.DeviceAuthorized || d.EnrollChallenge != "" || !d.PurgeAt.IsZero() {
		t.Fatalf("device after confirm: %+v", d)
	}
}

func TestEnrollRefusals(t *testing.T) {
	r := newRig(t, false)
	m1, tok1 := r.signup()
	r.withLibrary(tok1)
	revoked, _ := r.enrolConfirmed()
	if code, _ := r.do("DELETE", "/v1/devices/"+revoked.id, nil, tok1); code != 204 {
		t.Fatal("revoke failed")
	}
	cases := []struct {
		name  string
		mac   *mac
		jws   string
		code  int
		error string
	}{
		{"no account for this purchase", r.newMac(), r.tx(map[string]any{"originalTransactionId": "3333", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000033"}), 404, "no_account"},
		{"already enrolled and authorized", m1, r.tx(nil), 409, "device_enrolled"},
		{"revoked device key", revoked, r.tx(nil), 403, "device_revoked"},
		{"forged transaction", r.newMac(), r.apple.JWSWith(t, map[string]any{"originalTransactionId": "1000"}, testkit.OtherKey(t), true), 401, "invalid_transaction"},
		{"another app's purchase", r.newMac(), r.tx(map[string]any{"bundleId": "com.other"}), 403, "wrong_app"},
	}
	for _, tc := range cases {
		code, body := r.enroll(tc.mac, tc.jws)
		if code != tc.code || (tc.error != "" && body["error"] != tc.error) {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	// A device key that already belongs to account 2 cannot be enrolled into account 1.
	other := r.newMac()
	r.signupWith(other, "4444", "6f1c2d3e-0000-4000-8000-000000000044")
	if code, body := r.enroll(other, r.tx(nil)); code != 409 || body["error"] != "device_bound" {
		t.Errorf("foreign device key: %d %v", code, body)
	}
	// Two accounts claim one purchase: subscription -> account 1, token -> account 2.
	mix := r.tx(map[string]any{"appAccountToken": "6f1c2d3e-0000-4000-8000-000000000044"})
	if code, body := r.enroll(r.newMac(), mix); code != 409 || body["error"] != "account_mismatch" {
		t.Errorf("mismatch: %d %v", code, body)
	}
}

func TestDeviceCapsPerPlan(t *testing.T) {
	for _, tc := range []struct {
		tier string
		cap  int
	}{{"starter", 2}, {"standard", 4}, {"large", 8}, {"max", 8}} {
		t.Run(tc.tier, func(t *testing.T) {
			r := newRig(t, false)
			jws := r.tx(map[string]any{"productId": fmt.Sprintf("com.ivy.whisperer.cloud.%s.monthly", tc.tier)})
			m := r.newMac()
			if code, body := r.createAccount(m, jws); code != 201 {
				t.Fatalf("create: %d %v", code, body)
			}
			_, tok := r.session2(m)
			r.withLibrary(tok)
			for i := 1; i < tc.cap; i++ {
				mm := r.newMac()
				code, body := r.enroll(mm, jws)
				if code != 200 {
					t.Fatalf("device %d: %d %v", i+1, code, body)
				}
				if code, body := r.confirm(mm, proofFor(mm, body["enrollChallenge"].(string), "")); code != 200 {
					t.Fatalf("confirm %d: %d %v", i+1, code, body)
				}
			}
			code, body := r.enroll(r.newMac(), jws)
			if code != 403 || body["error"] != "device_limit" {
				t.Fatalf("device %d should exceed the %s cap: %d %v", tc.cap+1, tc.tier, code, body)
			}
		})
	}
}

func TestTheCapIsRecheckedWhenAPendingDeviceConfirms(t *testing.T) {
	r := newRig(t, false)
	starter := r.tx(map[string]any{"productId": "com.ivy.whisperer.cloud.starter.monthly"})
	m := r.newMac()
	r.createAccount(m, starter)
	_, tok := r.session2(m)
	r.withLibrary(tok)
	a, b := r.newMac(), r.newMac()
	_, ea := r.enroll(a, starter)
	_, eb := r.enroll(b, starter) // both pass the early check: only one authorized device so far
	if code, body := r.confirm(a, proofFor(a, ea["enrollChallenge"].(string), "")); code != 200 {
		t.Fatalf("first confirm: %d %v", code, body)
	}
	if code, body := r.confirm(b, proofFor(b, eb["enrollChallenge"].(string), "")); code != 403 || body["error"] != "device_limit" {
		t.Fatalf("second confirm must hit the cap: %d %v", code, body)
	}
}

func TestPendingDevicesAreBoundedAndExpireAfterSevenDays(t *testing.T) {
	r := newRig(t, false)
	_, tok := r.signup()
	r.withLibrary(tok)
	var first *mac
	var firstChallenge string
	for i := 0; i < account.MaxPending; i++ {
		m := r.newMac()
		code, body := r.enroll(m, r.tx(nil))
		if code != 200 {
			t.Fatalf("pending %d: %d %v", i, code, body)
		}
		if i == 0 {
			first, firstChallenge = m, body["enrollChallenge"].(string)
		}
	}
	if code, body := r.enroll(r.newMac(), r.tx(nil)); code != 429 || body["error"] != "too_many_pending" {
		t.Fatalf("pending spam: %d %v", code, body)
	}
	*r.clock = r.clock.Add(account.PendingTTL + time.Minute)
	code, body := r.confirm(first, proofFor(first, firstChallenge, ""))
	if code != 403 || body["error"] != "enrollment_expired" {
		t.Fatalf("expired enrolment: %d %v", code, body)
	}
	if code, body := r.session(first, ""); code != 403 || body["error"] != "enrollment_expired" {
		t.Fatalf("expired enrolment session: %d %v", code, body)
	}
	if code, body := r.enroll(first, r.tx(nil)); code != 200 { // expired pendings do not count; enrolling again refreshes
		t.Fatalf("re-enrol after expiry: %d %v", code, body)
	}
}

func TestConfirmRefusalsAndTheFiveAnHourLimit(t *testing.T) {
	r := newRig(t, false)
	_, tok := r.signup()
	r.withLibrary(tok)
	m := r.newMac()
	_, body := r.enroll(m, r.tx(nil))
	challenge := body["enrollChallenge"].(string)
	stranger := r.newMac()

	forgedSig := merge(map[string]any{"deviceId": m.id, "keyProof": proofFor(m, challenge, "")}, r.forgedSig(m, stranger, devauth.PurposeDeviceConfirm))
	if code, b := r.do("POST", "/v1/devices/confirm", forgedSig, ""); code != 401 || b["error"] != "bad_signature" {
		t.Errorf("forged signature: %d %v", code, b)
	}
	if code, b := r.confirm(stranger, "00"); code != 404 || b["error"] != "unknown_device" {
		t.Errorf("unknown device: %d %v", code, b)
	}
	otherKey := newOtherVerifierProof(m, challenge)
	for i := 1; i <= 5; i++ {
		if code, b := r.confirm(m, otherKey); code != 403 || b["error"] != "bad_key_proof" {
			t.Fatalf("wrong proof #%d: %d %v", i, code, b)
		}
	}
	// Sixth attempt: blocked even though the proof is now right.
	if code, b := r.confirm(m, proofFor(m, challenge, "")); code != 429 || b["error"] != "rate_limited" {
		t.Fatalf("rate limit: %d %v", code, b)
	}
	*r.clock = r.clock.Add(61 * time.Minute)
	if code, b := r.confirm(m, proofFor(m, challenge, "")); code != 200 {
		t.Fatalf("after the hour: %d %v", code, b)
	}
}

func TestAStaleEnrollChallengeDoesNotConfirm(t *testing.T) {
	r := newRig(t, false)
	_, tok := r.signup()
	r.withLibrary(tok)
	m := r.newMac()
	_, first := r.enroll(m, r.tx(nil))
	_, second := r.enroll(m, r.tx(nil))
	if first["enrollChallenge"] == second["enrollChallenge"] {
		t.Fatal("each enrolment gets a fresh challenge")
	}
	if code, b := r.confirm(m, proofFor(m, first["enrollChallenge"].(string), "")); code != 403 {
		t.Fatalf("stale challenge: %d %v", code, b)
	}
	if code, b := r.confirm(m, proofFor(m, second["enrollChallenge"].(string), "")); code != 200 {
		t.Fatalf("current challenge: %d %v", code, b)
	}
}

func TestConfirmWithNoLibraryAuthorizesButUploadsStayRefused(t *testing.T) {
	r := newRig(t, false)
	r.signup()
	m := r.newMac()
	_, body := r.enroll(m, r.tx(nil))
	if body["library"].(map[string]any)["exists"] != false {
		t.Fatalf("library info: %v", body)
	}
	if code, b := r.confirm(m, ""); code != 200 {
		t.Fatalf("nothing to prove yet: %d %v", code, b)
	}
}

func TestSessionRefusals(t *testing.T) {
	r := newRig(t, false)
	m, tok := r.signup()
	r.withLibrary(tok)
	pending := r.newMac()
	r.enroll(pending, r.tx(nil))
	revoked, _ := r.enrolConfirmed()
	r.do("DELETE", "/v1/devices/"+revoked.id, nil, tok)
	unknown := r.newMac()
	attacker := r.newMac()

	forged := merge(map[string]any{"deviceId": m.id}, r.forgedSig(m, attacker, devauth.PurposeSession))
	wrongPurpose := merge(map[string]any{"deviceId": m.id}, r.signed(m, devauth.PurposeReset))
	oldShape := map[string]any{"transactionJWS": r.tx(nil), "deviceID": "mac-1"}
	cases := []struct {
		name  string
		body  map[string]any
		code  int
		error string
	}{
		{"forged signature", forged, 401, "bad_signature"},
		{"signature for another purpose", wrongPurpose, 401, "bad_signature"},
		{"the old JWS-only request has no way in", oldShape, 400, "bad_request"},
		{"JWS only, no signature", map[string]any{"deviceId": m.id, "transactionJWS": r.tx(nil)}, 401, "bad_nonce"},
	}
	for _, tc := range cases {
		code, body := r.do("POST", "/v1/session", tc.body, "")
		if code != tc.code || body["error"] != tc.error {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	for _, tc := range []struct {
		name  string
		m     *mac
		code  int
		error string
	}{
		{"unknown device", unknown, 404, "unknown_device"},
		{"pending device", pending, 403, "device_pending"},
		{"revoked device", revoked, 403, "device_revoked"},
	} {
		code, body := r.session(tc.m, r.tx(nil)) // a perfectly valid JWS does not open the door
		if code != tc.code || body["error"] != tc.error {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	if code, body := r.session(m, "garbage"); code != 401 || body["error"] != "invalid_transaction" {
		t.Errorf("garbage JWS: %d %v", code, body)
	}
}

func TestSessionJWSMustBelongToTheDevicesAccount(t *testing.T) {
	r := newRig(t, false)
	m, _ := r.signup()
	other := r.newMac()
	r.signupWith(other, "5555", "6f1c2d3e-0000-4000-8000-000000000055")
	foreign := r.tx(map[string]any{"originalTransactionId": "5555", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000055"})
	if code, body := r.session(m, foreign); code != 409 || body["error"] != "wrong_account" {
		t.Fatalf("another account's purchase: %d %v", code, body)
	}
	unmapped := r.tx(map[string]any{"originalTransactionId": "6666", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000066"})
	if code, body := r.session(m, unmapped); code != 409 || body["error"] != "wrong_account" {
		t.Fatalf("a purchase that maps nowhere must not bind: %d %v", code, body)
	}
	if _, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("6666")); ok {
		t.Fatal("subscription 6666 got bound")
	}
}

func TestResubscribeBindsANewSubscriptionFromAnEnrolledDevice(t *testing.T) {
	r := newRig(t, false)
	m, _ := r.signup()
	next := r.tx(map[string]any{"originalTransactionId": "8000", "transactionId": "8001"}) // same appAccountToken, new chain
	code, body := r.session(m, next)
	if code != 200 || body["state"] != "active" {
		t.Fatalf("resubscribe: %d %v", code, body)
	}
	if id, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("8000")); !ok || id != r.accountID(m) {
		t.Fatalf("new subscription -> %q", id)
	}
	// A pending device holding that JWS cannot bind anything: enrolment refuses nothing but binds nothing.
	p := r.newMac()
	r.enroll(p, r.tx(map[string]any{"originalTransactionId": "8100", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000001"}))
	if _, ok, _ := r.accounts.ResolveSub(t.Context(), r.srv.SubKey("8100")); ok {
		t.Fatal("enrolment must never bind a subscription")
	}
}

func TestAnEndedSubscriptionHasNoSession(t *testing.T) {
	r := newRig(t, false)
	m, _ := r.signup()
	*r.clock = r.clock.Add(400 * 24 * time.Hour)
	code, body := r.session(m, "")
	if code != 402 || body["error"] != "subscription_expired" {
		t.Fatalf("%d %v", code, body)
	}
}

func TestAccountListsDevicesAndRevocation(t *testing.T) {
	r := newRig(t, false)
	m1, tok1 := r.signup()
	r.withLibrary(tok1)
	m2, _ := r.enrolConfirmed()
	pending := r.newMac()
	r.enroll(pending, r.tx(nil))
	_, acct := r.do("GET", "/v1/account", nil, tok1)
	devs := acct["devices"].([]any)
	if len(devs) != 3 || acct["deviceLimit"].(float64) != 4 {
		t.Fatalf("devices: %v", acct)
	}
	for _, d := range devs {
		v := d.(map[string]any)
		if v["id"] == m1.id && v["current"] != true || v["id"] != m1.id && v["current"] == true {
			t.Errorf("current flag: %v", v)
		}
	}
	cases := []struct {
		name, path, token string
		code              int
	}{
		{"no token", "/v1/devices/" + m2.id, "", 401},
		{"bad id", "/v1/devices/xyz", tok1, 400},
		{"unknown device", "/v1/devices/ffffffffffffffffffffffffffffffff", tok1, 404},
		{"revoke", "/v1/devices/" + m2.id, tok1, 204},
		{"revoke again is idempotent", "/v1/devices/" + m2.id, tok1, 204},
		{"revoke a pending enrolment", "/v1/devices/" + pending.id, tok1, 204},
	}
	for _, tc := range cases {
		if code, body := r.do("DELETE", tc.path, nil, tc.token); code != tc.code {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	_, acct = r.do("GET", "/v1/account", nil, tok1)
	if len(acct["devices"].([]any)) != 1 {
		t.Fatalf("revoked devices must disappear from the list: %v", acct["devices"])
	}
	if code, body := r.session(m2, ""); code != 403 || body["error"] != "device_revoked" {
		t.Fatalf("revoked session: %d %v", code, body)
	}
}

func TestADeviceCannotRevokeAnotherAccountsDevice(t *testing.T) {
	r := newRig(t, false)
	_, tok1 := r.signup()
	other := r.newMac()
	r.signupWith(other, "5555", "6f1c2d3e-0000-4000-8000-000000000055")
	if code, _ := r.do("DELETE", "/v1/devices/"+other.id, nil, tok1); code != 404 {
		t.Fatalf("cross-account revoke: %d", code)
	}
	if d, _, _ := r.accounts.GetDevice(t.Context(), other.id); d.State != account.DeviceAuthorized {
		t.Fatal("the foreign device was revoked")
	}
}

func TestARevokedDeviceCannotRevokeOrChangeTheAccount(t *testing.T) {
	r := newRig(t, false)
	_, tok1 := r.signup()
	r.withLibrary(tok1)
	m2, tok2 := r.enrolConfirmed()
	r.do("DELETE", "/v1/devices/"+m2.id, nil, tok1)
	if code, body := r.do("POST", "/v1/library", map[string]any{"keyVerifier": verifierHex()}, tok2); code != 403 || body["error"] != "device_revoked" {
		t.Fatalf("revoked create library: %d %v", code, body)
	}
}

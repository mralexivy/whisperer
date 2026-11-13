package server_test

import (
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/devauth"
	"github.com/mralexivy/whisperer/server/internal/server"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

func TestCreateLibraryIsCreateIfAbsent(t *testing.T) {
	r := newRig(t, false)
	_, tok := r.signup()
	_, tok2 := r.enrolConfirmedNoLibrary()
	good := map[string]any{"keyVerifier": verifierHex(), "recovery": map[string]string{"wrapped": "d3JhcHBlZA==", "kdf": "hkdf-sha256-v1"}}
	cases := []struct {
		name  string
		body  map[string]any
		token string
		code  int
		error string
	}{
		{"no session", good, "", 401, ""},
		{"verifier too short", map[string]any{"keyVerifier": "abcd"}, tok, 400, "bad_request"},
		{"verifier not hex", map[string]any{"keyVerifier": "zz" + verifierHex()[2:]}, tok, 400, "bad_request"},
		{"recovery without kdf", map[string]any{"keyVerifier": verifierHex(), "recovery": map[string]string{"wrapped": "x"}}, tok, 400, "bad_request"},
		{"created", good, tok, 201, ""},
		{"second Mac racing the first loses", map[string]any{"keyVerifier": verifierHex()}, tok2, 409, "library_exists"},
		{"the winner cannot overwrite it either", good, tok, 409, "library_exists"},
	}
	for _, tc := range cases {
		code, body := r.do("POST", "/v1/library", tc.body, tc.token)
		if code != tc.code || (tc.error != "" && body["error"] != tc.error) {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
		if tc.code == 409 {
			lib := body["library"].(map[string]any)
			if lib["exists"] != true || lib["recoveryAvailable"] != true {
				t.Errorf("%s: 409 must describe the existing library: %v", tc.name, body)
			}
		}
	}
}

func TestCreateLibraryNeedsAnActiveSubscription(t *testing.T) {
	r := newRig(t, false)
	m, tok := r.signup()
	*r.clock = r.clock.Add(40 * 24 * time.Hour)
	tok = r.tokenFor(r.accountID(m), m.id)
	if code, body := r.do("POST", "/v1/library", map[string]any{"keyVerifier": verifierHex()}, tok); code != 403 || body["error"] != "read_only" {
		t.Fatalf("lapsed: %d %v", code, body)
	}
}

func TestReplaceRecoveryNeedsAKeyProof(t *testing.T) {
	r := newRig(t, false)
	m, tok := r.signup()
	put := func(body map[string]any, token string) (int, map[string]any) {
		return r.do("PUT", "/v1/library/recovery", body, token)
	}
	blob := func(m *mac, nonce, proof string) map[string]any {
		return map[string]any{"wrapped": "bmV3", "kdf": "k2", "nonce": nonce, "keyProof": proof}
	}
	nonce := r.challenge(m.id)
	if code, body := put(blob(m, nonce, proofFor(m, nonce, devauth.PurposeRecovery)), tok); code != 404 || body["error"] != "no_library" {
		t.Fatalf("no library yet: %d %v", code, body)
	}
	r.withLibrary(tok)
	nonce = r.challenge(m.id)
	good := proofFor(m, nonce, devauth.PurposeRecovery)
	other := r.newMac()
	cases := []struct {
		name  string
		body  map[string]any
		token string
		code  int
		error string
	}{
		{"no session", blob(m, nonce, good), "", 401, ""},
		{"missing blob", map[string]any{"nonce": nonce, "keyProof": good}, tok, 400, "bad_request"},
		{"wrong proof", blob(m, nonce, "00"+good[2:]), tok, 403, "bad_key_proof"},
		{"proof made for enrolment, not recovery", blob(m, nonce, proofFor(m, nonce, "")), tok, 403, "bad_key_proof"},
		{"proof bound to another device", blob(m, nonce, proofFor(other, nonce, devauth.PurposeRecovery)), tok, 403, "bad_key_proof"},
		{"nonce for another device", blob(m, r.challenge(other.id), good), tok, 401, "bad_nonce"},
		{"correct", blob(m, nonce, good), tok, 204, ""},
	}
	for _, tc := range cases {
		code, body := put(tc.body, tc.token)
		if code != tc.code || (tc.error != "" && body["error"] != tc.error) {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	a, _, _ := r.accounts.GetAccount(t.Context(), r.accountID(m))
	if a.Library.Recovery == nil || a.Library.Recovery.Wrapped != "bmV3" || a.Library.Recovery.Kdf != "k2" {
		t.Fatalf("recovery after replace: %+v", a.Library.Recovery)
	}
}

func TestReplaceRecoveryWrongProofsAreRateLimited(t *testing.T) {
	r := newRig(t, false)
	m, tok := r.signup()
	r.withLibrary(tok)
	for i := 0; i < 5; i++ {
		nonce := r.challenge(m.id)
		code, _ := r.do("PUT", "/v1/library/recovery", map[string]any{"wrapped": "x", "kdf": "k", "nonce": nonce, "keyProof": proofFor(m, "00"+nonce[2:], devauth.PurposeRecovery)}, tok)
		if code != 403 {
			t.Fatalf("attempt %d: %d", i, code)
		}
	}
	nonce := r.challenge(m.id)
	if code, body := r.do("PUT", "/v1/library/recovery", map[string]any{"wrapped": "x", "kdf": "k", "nonce": nonce, "keyProof": proofFor(m, nonce, devauth.PurposeRecovery)}, tok); code != 429 {
		t.Fatalf("after five failures: %d %v", code, body)
	}
}

func (r *rig) blobRequest(m *mac, jws string) (int, map[string]any) {
	body := merge(map[string]any{"deviceId": m.id, "transactionJWS": jws}, r.signed(m, devauth.PurposeRecoveryBlob))
	return r.do("POST", "/v1/library/recovery-blob", body, "")
}

func TestRecoveryBlobForAPendingDevice(t *testing.T) {
	r := newRig(t, false)
	_, tok := r.signup()
	if code, body := r.do("POST", "/v1/library", map[string]any{"keyVerifier": verifierHex()}, tok); code != 201 {
		t.Fatalf("%d %v", code, body)
	}
	pending := r.newMac()
	r.enroll(pending, r.tx(nil))
	if code, body := r.blobRequest(pending, r.tx(nil)); code != 404 || body["error"] != "no_recovery" {
		t.Fatalf("library without a recovery blob: %d %v", code, body)
	}
	// Give the library a recovery blob (an authorized device does it, with a proof).
	m, tok2 := r.enrolledAuthorized(t)
	n := r.challenge(m.id)
	if code, body := r.do("PUT", "/v1/library/recovery", map[string]any{"wrapped": "d3JhcHBlZA==", "kdf": "hkdf-sha256-v1", "nonce": n, "keyProof": proofFor(m, n, devauth.PurposeRecovery)}, tok2); code != 204 {
		t.Fatalf("put recovery: %d %v", code, body)
	}

	unknown := r.newMac()
	cases := []struct {
		name  string
		m     *mac
		jws   string
		code  int
		error string
	}{
		{"pending device with a valid purchase", pending, r.tx(nil), 200, ""},
		{"unknown device", unknown, r.tx(nil), 404, "unknown_device"},
		{"forged purchase", pending, r.apple.JWSWith(t, map[string]any{"originalTransactionId": "1000"}, testkit.OtherKey(t), true), 401, "invalid_transaction"},
		{"another account's purchase", pending, r.tx(map[string]any{"originalTransactionId": "7777", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000077"}), 403, "wrong_account"},
		{"no purchase", pending, "", 400, "bad_request"},
	}
	for _, tc := range cases {
		code, body := r.blobRequest(tc.m, tc.jws)
		if code != tc.code || (tc.error != "" && body["error"] != tc.error) {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
		if tc.code == 200 && (body["wrapped"] != "d3JhcHBlZA==" || body["kdf"] != "hkdf-sha256-v1" || body["keyVersion"].(float64) != 1) {
			t.Errorf("%s: %v", tc.name, body)
		}
	}
	// A forged signature is refused.
	forged := merge(map[string]any{"deviceId": pending.id, "transactionJWS": r.tx(nil)}, r.signed(unknown, devauth.PurposeRecoveryBlob))
	if code, body := r.do("POST", "/v1/library/recovery-blob", forged, ""); code != 401 {
		t.Errorf("forged signature: %d %v", code, body)
	}
	// A revoked device loses even this.
	r.do("DELETE", "/v1/devices/"+pending.id, nil, tok)
	if code, body := r.blobRequest(pending, r.tx(nil)); code != 403 || body["error"] != "device_revoked" {
		t.Errorf("revoked: %d %v", code, body)
	}
}

// enrolledAuthorized adds an authorized device to the (single) account of the rig's default subscription.
func (r *rig) enrolledAuthorized(t *testing.T) (*mac, string) {
	return r.enrolConfirmed()
}

func (r *rig) enrolConfirmedNoLibrary() (*mac, string) {
	m := r.newMac()
	if code, body := r.enroll(m, r.tx(nil)); code != 200 {
		r.t.Fatalf("enroll: %d %v", code, body)
	}
	code, body := r.confirm(m, "")
	if code != 200 {
		r.t.Fatalf("confirm: %d %v", code, body)
	}
	return m, body["token"].(string)
}

func newResetRig(t *testing.T) (*syncRig, *mac, string) {
	r := newSyncRig(t)
	m2, tok2 := r.enrolConfirmed()
	// some data in epoch 1
	_, up := r.do("POST", "/v1/sync/upload", objs("changes", 1, 500), r.token)
	r.blobs.Put(up["grants"].([]any)[0].(map[string]any)["name"].(string), 500, 9)
	r.do("POST", "/v1/sync/commit", map[string]any{"device": device, "seq": 1, "crc": 9}, r.token)
	return r, m2, tok2
}

func TestResetBumpsTheEpochAndQueuesTheOldOne(t *testing.T) {
	r, _, _ := newResetRig(t)
	for _, tc := range []struct {
		name string
		body map[string]any
		code int
	}{
		{"no phrase", map[string]any{}, 400},
		{"wrong phrase", map[string]any{"confirm": "reset"}, 400},
	} {
		if code, body := r.do("POST", "/v1/library/reset", tc.body, r.token); code != tc.code || body["error"] != "confirmation_required" {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	code, body := r.do("POST", "/v1/library/reset", map[string]any{"confirm": server.ResetPhrase}, r.token)
	if code != 200 || body["epoch"].(float64) != 2 || body["token"] == "" || body["library"].(map[string]any)["exists"] != false {
		t.Fatalf("reset: %d %v", code, body)
	}
	a, _, _ := r.accounts.GetAccount(t.Context(), r.acct)
	if a.Epoch != 2 || a.Library.Exists || a.Library.Verifier != "" || a.Library.Recovery != nil {
		t.Fatalf("account after reset: %+v", a)
	}
	if len(a.EpochsToDelete) != 1 || a.EpochsToDelete[0].Epoch != 1 || a.EpochQueue != "pending" {
		t.Fatalf("old epoch must be queued for deletion: %+v", a.EpochsToDelete)
	}
	h, _ := r.sp.GetHeads(t.Context(), r.acct)
	u, _ := r.sp.GetUsage(t.Context(), r.acct)
	if h.Epoch != 2 || len(h.Heads) != 0 || h.Snapshot != nil || h.Version < 2 || u.Committed != 0 || u.Reserved != 0 {
		t.Fatalf("sync state after reset: heads=%+v usage=%+v", h, u)
	}
	// The old objects are still there (the retention sweep deletes them), under the old prefix only.
	if r.blobs.Count(syncplane.Prefix("whisperer", r.acct, 1)) != 1 {
		t.Fatal("reset must not delete synchronously")
	}
	// A new library, then uploads go under epoch 2.
	newTok := body["token"].(string)
	r.withLibrary(newTok)
	_, up := r.do("POST", "/v1/sync/upload", objs("changes", 1, 10), newTok)
	if name := up["grants"].([]any)[0].(map[string]any)["name"].(string); name != syncplane.Prefix("whisperer", r.acct, 2)+"changes/"+device+"/000000000001" {
		t.Fatalf("upload after reset: %s", name)
	}
	// The same stale token resetting again converges instead of bumping twice.
	if code, body := r.do("POST", "/v1/library/reset", map[string]any{"confirm": server.ResetPhrase}, r.token); code != 200 || body["epoch"].(float64) != 2 {
		t.Fatalf("a repeated reset: %d %v", code, body)
	}
}

func TestResetRefusals(t *testing.T) {
	r, m2, tok2 := newResetRig(t)
	r.do("DELETE", "/v1/devices/"+m2.id, nil, r.token)
	phrase := map[string]any{"confirm": server.ResetPhrase}
	if code, body := r.do("POST", "/v1/library/reset", phrase, tok2); code != 403 || body["error"] != "device_revoked" {
		t.Fatalf("revoked device: %d %v", code, body)
	}
	if code, body := r.do("POST", "/v1/library/reset", phrase, "garbage"); code != 401 {
		t.Fatalf("bad token: %d %v", code, body)
	}
	if code, _ := r.do("POST", "/v1/library/reset", phrase, ""); code != 400 {
		t.Fatalf("no credentials at all must not reset: %d", code)
	}
	a, _, _ := r.accounts.GetAccount(t.Context(), r.acct)
	if a.Epoch != 1 || !a.Library.Exists {
		t.Fatalf("a refused reset changed the account: %+v", a)
	}
}

func TestResetFromALostKeyDevice(t *testing.T) {
	r := newSyncRig(t)
	lost := r.newMac()
	r.enroll(lost, r.tx(nil)) // enrolled but never confirmed: the key is gone
	phrase := server.ResetPhrase
	signedBody := func(m *mac, jws, confirm string) map[string]any {
		return merge(map[string]any{"deviceId": m.id, "transactionJWS": jws, "confirm": confirm}, r.signed(m, devauth.PurposeReset))
	}
	other := r.newMac()
	cases := []struct {
		name  string
		body  map[string]any
		code  int
		error string
	}{
		{"no phrase", signedBody(lost, r.tx(nil), ""), 400, "confirmation_required"},
		{"forged signature", merge(map[string]any{"deviceId": lost.id, "transactionJWS": r.tx(nil), "confirm": phrase}, r.forgedSig(lost, other, devauth.PurposeReset)), 401, "bad_signature"},
		{"another account's purchase", signedBody(lost, r.tx(map[string]any{"originalTransactionId": "7777", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000077"}), phrase), 403, "wrong_account"},
		{"unknown device", signedBody(other, r.tx(nil), phrase), 404, "unknown_device"},
	}
	for _, tc := range cases {
		code, body := r.do("POST", "/v1/library/reset", tc.body, "")
		if code != tc.code || body["error"] != tc.error {
			t.Errorf("%s: %d %v", tc.name, code, body)
		}
	}
	if a, _, _ := r.accounts.GetAccount(t.Context(), r.acct); a.Epoch != 1 {
		t.Fatal("a refused reset bumped the epoch")
	}
	code, body := r.do("POST", "/v1/library/reset", signedBody(lost, r.tx(nil), phrase), "")
	if code != 200 || body["epoch"].(float64) != 2 {
		t.Fatalf("reset: %d %v", code, body)
	}
	if d, _, _ := r.accounts.GetDevice(t.Context(), lost.id); d.State != account.DeviceAuthorized {
		t.Fatalf("the resetting device is authorized afterwards: %+v", d)
	}
	r.withLibrary(body["token"].(string)) // it can now create the new library
}

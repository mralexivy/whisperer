package server_test

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/devauth"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/server"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

var now = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

type rig struct {
	t        *testing.T
	apple    *testkit.Apple
	srv      *server.Server
	h        http.Handler
	store    *entitlement.Memory
	accounts *account.Memory
	clock    *time.Time
	signer   *auth.Signer
}

func newRig(t *testing.T, allowSandbox bool) *rig {
	a := testkit.New(t, now)
	clock := now
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	store, accounts := entitlement.NewMemory(), account.NewMemory()
	cfg := server.Config{
		BundleID: "com.ivy.whisperer", AllowSandbox: allowSandbox, UIDSecret: []byte("test-secret"), RateLimit: 100000,
		Now: func() time.Time { return clock },
	}
	a.Now = clock
	signer := auth.NewSigner(priv, "k1")
	s := server.New(cfg, a.Verifier, store, accounts, signer, nil)
	return &rig{t: t, apple: a, srv: s, h: s.Handler(), store: store, accounts: accounts, clock: &clock, signer: signer}
}

func (r *rig) tx(overrides map[string]any) string {
	p := map[string]any{
		"originalTransactionId": "1000", "transactionId": "1001", "bundleId": "com.ivy.whisperer",
		"productId": "com.ivy.whisperer.cloud.standard.monthly", "type": "Auto-Renewable Subscription", "environment": "Production",
		"appAccountToken": "6f1c2d3e-0000-4000-8000-000000000001",
		"expiresDate":     now.Add(30 * 24 * time.Hour).UnixMilli(), "signedDate": now.UnixMilli(),
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

// mac is a test Mac: a P-256 device key.
type mac struct {
	key *ecdsa.PrivateKey
	id  string
	pub string
}

func (r *rig) newMac() *mac {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		r.t.Fatal(err)
	}
	return &mac{key: k, id: devauth.DeviceID(&k.PublicKey), pub: devauth.EncodePublicKey(&k.PublicKey)}
}

// challenge asks the server for a nonce over HTTP, as a Mac would.
func (r *rig) challenge(deviceID string) string {
	code, body := r.do("POST", "/v1/auth/challenge", map[string]string{"deviceId": deviceID}, "")
	if code != 200 {
		r.t.Fatalf("challenge: %d %v", code, body)
	}
	return body["nonce"].(string)
}

// signed returns {nonce, sig} for purpose.
func (r *rig) signed(m *mac, purpose string) map[string]any {
	nonce := r.challenge(m.id)
	sig, err := devauth.Sign(m.key, nonce, purpose)
	if err != nil {
		r.t.Fatal(err)
	}
	return map[string]any{"nonce": nonce, "sig": sig}
}

func merge(a map[string]any, more map[string]any) map[string]any {
	for k, v := range more {
		a[k] = v
	}
	return a
}

func (r *rig) createAccount(m *mac, jws string) (int, map[string]any) {
	body := merge(map[string]any{"transactionJWS": jws, "devicePublicKey": m.pub}, r.signed(m, devauth.PurposeAccountCreate))
	return r.do("POST", "/v1/accounts", body, "")
}

func (r *rig) enroll(m *mac, jws string) (int, map[string]any) {
	body := merge(map[string]any{"transactionJWS": jws, "devicePublicKey": m.pub}, r.signed(m, devauth.PurposeDeviceEnroll))
	return r.do("POST", "/v1/devices", body, "")
}

func (r *rig) confirm(m *mac, keyProof string) (int, map[string]any) {
	body := merge(map[string]any{"deviceId": m.id, "keyProof": keyProof}, r.signed(m, devauth.PurposeDeviceConfirm))
	return r.do("POST", "/v1/devices/confirm", body, "")
}

func (r *rig) session(m *mac, jws string) (int, map[string]any) {
	body := merge(map[string]any{"deviceId": m.id}, r.signed(m, devauth.PurposeSession))
	if jws != "" {
		body["transactionJWS"] = jws
	}
	return r.do("POST", "/v1/session", body, "")
}

// Library key material for tests: authKey -> verifier = SHA-256(authKey), hex.
var authKey = sha256.Sum256([]byte("test auth key"))

func verifierHex() string {
	v := sha256.Sum256(authKey[:])
	return hex.EncodeToString(v[:])
}

func proofFor(m *mac, challenge, suffix string) string {
	p, _ := devauth.KeyProof(verifierHex(), challenge, m.id, suffix)
	return p
}

// signup creates the account for the default test subscription from a fresh Mac and returns the Mac and its token.
func (r *rig) signup() (*mac, string) {
	m := r.newMac()
	code, body := r.createAccount(m, r.tx(nil))
	if code != 201 {
		r.t.Fatalf("create account: %d %v", code, body)
	}
	return m, body["token"].(string)
}

// withLibrary creates the library (verifier + recovery blob) from an authorized device.
func (r *rig) withLibrary(token string) {
	code, body := r.do("POST", "/v1/library", map[string]any{"keyVerifier": verifierHex(), "recovery": map[string]string{"wrapped": "d3JhcHBlZA==", "kdf": "hkdf-sha256-v1"}}, token)
	if code != 201 {
		r.t.Fatalf("create library: %d %v", code, body)
	}
}

// enrolConfirmed adds another Mac to an existing account with a library, proving the key.
func (r *rig) enrolConfirmed() (*mac, string) {
	m := r.newMac()
	code, body := r.enroll(m, r.tx(nil))
	if code != 200 {
		r.t.Fatalf("enroll: %d %v", code, body)
	}
	code, body = r.confirm(m, proofFor(m, body["enrollChallenge"].(string), ""))
	if code != 200 {
		r.t.Fatalf("confirm: %d %v", code, body)
	}
	return m, body["token"].(string)
}

// tokenFor issues a session token at the rig's clock for the default account and a device.
func (r *rig) tokenFor(accountID, deviceID string) string {
	a, _, _ := r.accounts.GetAccount(r.t.Context(), accountID)
	tok, _ := r.signer.Issue(accountID, deviceID, a.Epoch, "active", false, *r.clock)
	return tok
}

func (r *rig) accountID(m *mac) string {
	d, ok, _ := r.accounts.GetDevice(r.t.Context(), m.id)
	if !ok {
		r.t.Fatal("device not found")
	}
	return d.AccountID
}

// newLimitedRig is a rig whose per-address limit is `perMinute`.
func newLimitedRig(t *testing.T, perMinute int) *rig {
	a := testkit.New(t, now)
	clock := now
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	store, accounts := entitlement.NewMemory(), account.NewMemory()
	cfg := server.Config{BundleID: "com.ivy.whisperer", UIDSecret: []byte("test-secret"), RateLimit: perMinute, Now: func() time.Time { return clock }}
	signer := auth.NewSigner(priv, "k1")
	s := server.New(cfg, a.Verifier, store, accounts, signer, nil)
	return &rig{t: t, apple: a, srv: s, h: s.Handler(), store: store, accounts: accounts, clock: &clock, signer: signer}
}

// signupWith creates an account for the subscription/token pair from a specific Mac.
func (r *rig) signupWith(m *mac, origTx, token string) string {
	code, body := r.createAccount(m, r.tx(map[string]any{"originalTransactionId": origTx, "appAccountToken": token}))
	if code != 201 {
		r.t.Fatalf("signup %s: %d %v", origTx, code, body)
	}
	return body["token"].(string)
}

// signup2 creates a second, unrelated account.
func (r *rig) signup2() (*mac, string) {
	m := r.newMac()
	return m, r.signupWith(m, "9999", "6f1c2d3e-0000-4000-8000-000000000099")
}

// session2 opens a session for a Mac with no JWS and returns its token.
func (r *rig) session2(m *mac) (int, string) {
	code, body := r.session(m, "")
	if code != 200 {
		r.t.Fatalf("session: %d %v", code, body)
	}
	return code, body["token"].(string)
}

// newOtherVerifierProof is a proof made with a different library key.
func newOtherVerifierProof(m *mac, challenge string) string {
	other := sha256.Sum256([]byte("a different library"))
	v := sha256.Sum256(other[:])
	p, _ := devauth.KeyProof(hex.EncodeToString(v[:]), challenge, m.id, "")
	return p
}

// forgedSig is a signature made by `attacker` over a genuine nonce issued for `victim`.
func (r *rig) forgedSig(victim, attacker *mac, purpose string) map[string]any {
	nonce := r.challenge(victim.id)
	sig, _ := devauth.Sign(attacker.key, nonce, purpose)
	return map[string]any{"nonce": nonce, "sig": sig}
}

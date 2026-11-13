package retention_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/retention"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

type fakeAppleAPI struct {
	kit        *testkit.Apple
	t          *testing.T
	pub        *ecdsa.PublicKey
	prod       map[string][]map[string]any // originalTransactionId -> lastTransactions (production)
	sandbox    map[string][]map[string]any
	badAuth    int
	prodStatus int
}

func (f *fakeAppleAPI) entry(status int, expires time.Time, grace time.Time) map[string]any {
	tx := f.kit.JWS(f.t, map[string]any{"originalTransactionId": "1000", "bundleId": "com.ivy.whisperer", "productId": "com.ivy.whisperer.cloud.standard.monthly",
		"type": "Auto-Renewable Subscription", "environment": "Production", "expiresDate": expires.UnixMilli(), "signedDate": t0.UnixMilli()})
	renewal := map[string]any{"originalTransactionId": "1000", "autoRenewStatus": 0, "signedDate": t0.UnixMilli()}
	if !grace.IsZero() {
		renewal["gracePeriodExpiresDate"] = grace.UnixMilli()
	}
	return map[string]any{"status": status, "signedTransactionInfo": tx, "signedRenewalInfo": f.kit.JWS(f.t, renewal)}
}

func (f *fakeAppleAPI) handler(w http.ResponseWriter, r *http.Request) {
	if !f.verifyJWT(r.Header.Get("Authorization")) {
		f.badAuth++
		w.WriteHeader(401)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/inApps/v1/subscriptions/")
	table := f.prod
	if strings.HasPrefix(r.Host, "sandbox") || r.Header.Get("X-Env") == "sandbox" {
		table = f.sandbox
	}
	if f.prodStatus != 0 {
		w.WriteHeader(f.prodStatus)
		return
	}
	entries, ok := table[id]
	if !ok {
		w.WriteHeader(404)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"lastTransactions": entries}}})
}

func (f *fakeAppleAPI) verifyJWT(header string) bool {
	tok, ok := strings.CutPrefix(header, "Bearer ")
	parts := strings.Split(tok, ".")
	if !ok || len(parts) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(f.pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return false
	}
	body, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims map[string]any
	_ = json.Unmarshal(body, &claims)
	headBytes, _ := base64.RawURLEncoding.DecodeString(parts[0])
	var head map[string]string
	_ = json.Unmarshal(headBytes, &head)
	exp, iat := int64(claims["exp"].(float64)), int64(claims["iat"].(float64))
	return head["alg"] == "ES256" && head["kid"] == "KEYID" && claims["iss"] == "ISSUER" && claims["aud"] == "appstoreconnect-v1" &&
		claims["bid"] == "com.ivy.whisperer" && exp-iat <= 20*60
}

func setup(t *testing.T) (retention.AppleServerAPI, *fakeAppleAPI) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	parsed, err := apple.ParseP8(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	if err != nil {
		t.Fatal(err)
	}
	kit := testkit.New(t, t0)
	f := &fakeAppleAPI{kit: kit, t: t, pub: &key.PublicKey, prod: map[string][]map[string]any{}, sandbox: map[string][]map[string]any{}}
	prodSrv := httptest.NewServer(http.HandlerFunc(f.handler))
	sandSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { r.Header.Set("X-Env", "sandbox"); f.handler(w, r) }))
	t.Cleanup(prodSrv.Close)
	t.Cleanup(sandSrv.Close)
	api := &apple.ServerAPI{KeyID: "KEYID", IssuerID: "ISSUER", BundleID: "com.ivy.whisperer", Key: parsed, Verifier: kit.Verifier,
		ProductionBase: prodSrv.URL, SandboxBase: sandSrv.URL, Now: func() time.Time { return t0 }}
	return retention.AppleServerAPI{API: api}, f
}

func TestStatusMapsEveryAppleStateAndReadsTheDates(t *testing.T) {
	a, f := setup(t)
	exp, grace := t0.Add(5*24*time.Hour), t0.Add(21*24*time.Hour)
	for id, want := range map[int]retention.Status{apple.StatusActive: retention.StatusActive, apple.StatusExpired: retention.StatusExpired,
		apple.StatusRetry: retention.StatusRetry, apple.StatusGrace: retention.StatusGrace, apple.StatusRevoked: retention.StatusRevoked} {
		f.prod["1000"] = []map[string]any{f.entry(id, exp, grace)}
		ans, err := a.Status(context.Background(), "1000")
		if err != nil || ans.Status != want || !ans.ExpiresAt.Equal(exp.UTC().Truncate(time.Millisecond)) || !ans.GraceUntil.Equal(grace.UTC().Truncate(time.Millisecond)) {
			t.Errorf("status %d: %+v %v", id, ans, err)
		}
	}
}

func TestTheMostAliveEntryWins(t *testing.T) {
	a, f := setup(t)
	f.prod["1000"] = []map[string]any{f.entry(apple.StatusExpired, t0.Add(-9*24*time.Hour), time.Time{}), f.entry(apple.StatusActive, t0.Add(20*24*time.Hour), time.Time{})}
	ans, err := a.Status(context.Background(), "1000")
	if err != nil || ans.Status != retention.StatusActive {
		t.Fatalf("%+v %v", ans, err)
	}
}

func TestSandboxPurchasesAreFoundWhenProductionHasNoSuchTransaction(t *testing.T) {
	a, f := setup(t)
	f.sandbox["1000"] = []map[string]any{f.entry(apple.StatusActive, t0.Add(time.Hour), time.Time{})}
	if ans, err := a.Status(context.Background(), "1000"); err != nil || ans.Status != retention.StatusActive {
		t.Fatalf("%+v %v", ans, err)
	}
}

func TestAnythingUncertainIsAnErrorAndNeverAnExpiry(t *testing.T) {
	a, f := setup(t)
	if _, err := a.Status(context.Background(), "nobody"); err == nil {
		t.Fatal("a transaction Apple does not know must not read as expired")
	}
	f.prodStatus = 500
	if _, err := a.Status(context.Background(), "1000"); err == nil {
		t.Fatal("an Apple outage must not read as expired")
	}
	f.prodStatus = 0
	f.prod["1000"] = []map[string]any{{"status": 9, "signedTransactionInfo": f.entry(1, t0, time.Time{})["signedTransactionInfo"]}}
	if _, err := a.Status(context.Background(), "1000"); err == nil {
		t.Fatal("an unknown status code must not read as expired")
	}
	forged := f.entry(apple.StatusExpired, t0, time.Time{})
	forged["signedTransactionInfo"] = f.kit.JWSWith(t, map[string]any{"originalTransactionId": "1000", "bundleId": "com.ivy.whisperer"}, testkit.OtherKey(t), true)
	f.prod["1000"] = []map[string]any{forged}
	if _, err := a.Status(context.Background(), "1000"); err == nil {
		t.Fatal("a transaction not signed by Apple must be refused")
	}
}

func TestTheJWTIsValidES256WithTheRightClaims(t *testing.T) {
	a, f := setup(t)
	f.prod["1000"] = []map[string]any{f.entry(apple.StatusActive, t0.Add(time.Hour), time.Time{})}
	if _, err := a.Status(context.Background(), "1000"); err != nil || f.badAuth != 0 {
		t.Fatalf("the fake rejected our token: err=%v rejected=%d", err, f.badAuth)
	}
}

func TestParseP8RefusesOtherKeys(t *testing.T) {
	if _, err := apple.ParseP8([]byte("not pem")); err == nil {
		t.Fatal("garbage accepted")
	}
	rsa := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte{1, 2, 3}})
	if _, err := apple.ParseP8(rsa); err == nil {
		t.Fatal("a non-EC key accepted")
	}
}

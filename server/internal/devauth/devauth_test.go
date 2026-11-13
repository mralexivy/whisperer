package devauth_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/devauth"
)

var now = time.Date(2026, 11, 13, 12, 0, 30, 0, time.UTC)

func newKey(t *testing.T) *ecdsa.PrivateKey {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestPublicKeyAndDeviceIDRoundTrip(t *testing.T) {
	k := newKey(t)
	enc := devauth.EncodePublicKey(&k.PublicKey)
	pub, err := devauth.ParsePublicKey(enc)
	if err != nil || !pub.Equal(&k.PublicKey) {
		t.Fatalf("round trip: %v", err)
	}
	raw, _ := base64.StdEncoding.DecodeString(enc)
	sum := sha256.Sum256(raw)
	if id := devauth.DeviceID(pub); id != hex.EncodeToString(sum[:16]) || len(id) != 32 {
		t.Fatalf("deviceId %q is not the first 16 bytes of SHA-256 of the x9.63 key", id)
	}
	bad := map[string]string{
		"empty": "", "not base64": "!!!", "short": base64.StdEncoding.EncodeToString(raw[:64]),
		"compressed prefix": base64.StdEncoding.EncodeToString(append([]byte{2}, raw[1:]...)),
		"off curve":         base64.StdEncoding.EncodeToString(append(append([]byte{4}, raw[1:33]...), make([]byte, 32)...)),
	}
	for name, s := range bad {
		if _, err := devauth.ParsePublicKey(s); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

func TestNonceWindow(t *testing.T) {
	c := devauth.NewChallenger([]byte("secret"))
	id := "0123456789abcdef0123456789abcdef"
	n := c.Nonce(id, now) // issued at :30 of minute m
	cases := []struct {
		name   string
		dev    string
		nonce  string
		at     time.Time
		wantOK bool
	}{
		{"same minute", id, n, now, true},
		{"next minute (still inside 120 s)", id, n, now.Add(45 * time.Second), true},
		{"two minutes later", id, n, now.Add(95 * time.Second), false},
		{"far future", id, n, now.Add(time.Hour), false},
		{"another device", "ffffffffffffffffffffffffffffffff", n, now, false},
		{"garbage", id, "zz", now, false},
		{"truncated", id, n[:60], now, false},
	}
	for _, tc := range cases {
		_, err := c.NonceBytes(tc.dev, tc.nonce, tc.at)
		if (err == nil) != tc.wantOK {
			t.Errorf("%s: err=%v", tc.name, err)
		}
	}
	if devauth.NewChallenger([]byte("other")).Nonce(id, now) == n {
		t.Error("nonces must depend on the server secret")
	}
}

func TestSignatureVerification(t *testing.T) {
	c := devauth.NewChallenger([]byte("secret"))
	k, other := newKey(t), newKey(t)
	id := devauth.DeviceID(&k.PublicKey)
	nonce := c.Nonce(id, now)
	good, _ := devauth.Sign(k, nonce, devauth.PurposeSession)
	forged, _ := devauth.Sign(other, nonce, devauth.PurposeSession)
	otherPurpose, _ := devauth.Sign(k, nonce, devauth.PurposeReset)
	derSig := mustDER(t, k, nonce, devauth.PurposeSession)
	cases := []struct {
		name    string
		sig     string
		purpose string
		nonce   string
		at      time.Time
		ok      bool
	}{
		{"valid raw", good, devauth.PurposeSession, nonce, now, true},
		{"valid DER", derSig, devauth.PurposeSession, nonce, now, true},
		{"forged by another key", forged, devauth.PurposeSession, nonce, now, false},
		{"signed for another purpose", otherPurpose, devauth.PurposeSession, nonce, now, false},
		{"expired nonce", good, devauth.PurposeSession, nonce, now.Add(3 * time.Minute), false},
		{"not base64", "%%%", devauth.PurposeSession, nonce, now, false},
		{"wrong length", base64.StdEncoding.EncodeToString([]byte("short")), devauth.PurposeSession, nonce, now, false},
	}
	for _, tc := range cases {
		err := c.Verify(&k.PublicKey, id, tc.nonce, tc.purpose, tc.sig, tc.at)
		if (err == nil) != tc.ok {
			t.Errorf("%s: err=%v", tc.name, err)
		}
	}
}

func mustDER(t *testing.T, k *ecdsa.PrivateKey, nonce, purpose string) string {
	nb, _ := hex.DecodeString(nonce)
	digest := sha256.Sum256(append(nb, purpose...))
	der, err := ecdsa.SignASN1(rand.Reader, k, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func TestKeyProof(t *testing.T) {
	authKey := sha256.Sum256([]byte("auth key"))
	verifier := sha256.Sum256(authKey[:])
	v := hex.EncodeToString(verifier[:])
	id := "0123456789abcdef0123456789abcdef"
	ch := devauth.NewRandomHex(16)
	p, err := devauth.KeyProof(v, ch, id, "")
	if err != nil || len(p) != 64 {
		t.Fatalf("proof: %q %v", p, err)
	}
	cases := []struct {
		name                          string
		verifier, challenge, dev, sfx string
		ok                            bool
	}{
		{"right", v, ch, id, "", true},
		{"other challenge", v, devauth.NewRandomHex(16), id, "", false},
		{"other device", v, ch, "ffffffffffffffffffffffffffffffff", "", false},
		{"other purpose", v, ch, id, "library.recovery", false},
		{"other verifier", hex.EncodeToString(authKey[:]), ch, id, "", false},
	}
	for _, tc := range cases {
		if got := devauth.CheckKeyProof(tc.verifier, tc.challenge, tc.dev, tc.sfx, p); got != tc.ok {
			t.Errorf("%s: got %v", tc.name, got)
		}
	}
	if devauth.CheckKeyProof(v, ch, id, "", "") {
		t.Error("empty proof accepted")
	}
}

package auth_test

import (
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/auth"
)

var now = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

func pair(t *testing.T) (*auth.Signer, *auth.Verifier) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	return auth.NewSigner(priv, "k1"), auth.NewVerifier(pub)
}

func TestRoundTrip(t *testing.T) {
	s, v := pair(t)
	tok, _ := s.Issue("uid1", "dev1", true, now)
	c, err := v.Verify(tok, now.Add(time.Minute))
	if err != nil || c.UID != "uid1" || c.Dev != "dev1" || !c.ReadOnly {
		t.Fatalf("%+v %v", c, err)
	}
}

func TestExpires(t *testing.T) {
	s, v := pair(t)
	tok, _ := s.Issue("u", "d", false, now)
	if _, err := v.Verify(tok, now.Add(auth.TTL+time.Second)); err == nil {
		t.Fatal("expired token accepted")
	}
}

func TestRejectsTamperingAndOtherKeys(t *testing.T) {
	s, v := pair(t)
	_, other := pair(t)
	tok, _ := s.Issue("u", "d", false, now)
	if _, err := other.Verify(tok, now); err == nil {
		t.Fatal("token verified under another key")
	}
	parts := strings.Split(tok, ".")
	forged, _ := s.Issue("someone-else", "d", false, now)
	if _, err := v.Verify(parts[0]+"."+strings.Split(forged, ".")[1]+"."+parts[2], now); err == nil {
		t.Fatal("swapped payload accepted")
	}
	for _, bad := range []string{"", "a.b", "a.b.c"} {
		if _, err := v.Verify(bad, now); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
}

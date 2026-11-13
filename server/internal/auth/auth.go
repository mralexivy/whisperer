// Package auth issues and checks the service's own short-lived session tokens (compact JWS, EdDSA). The
// only thing a device proves to the server is "Apple says this subscription is current"; this token is the
// receipt for that proof, good for an hour, so Apple's JWS is not re-verified on every request.
package auth

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

var ErrInvalid = errors.New("auth: invalid token")

// TTL is how long a session token lives.
const TTL = time.Hour

type Claims struct {
	// Acct is the server-minted account id; Dev the device id (hash of its public key); Epoch the library
	// epoch at issue time (informational: the epoch that counts is read from the account at each grant).
	Acct  string `json:"acct"`
	Dev   string `json:"dev"`
	Epoch int    `json:"epoch"`
	// State is the entitlement state at issue time (informational; sync routes re-read the entitlement).
	State string `json:"state,omitempty"`
	// ReadOnly is set for a lapsed subscription: it may download and export but not upload.
	ReadOnly bool  `json:"ro,omitempty"`
	Iat      int64 `json:"iat"`
	Exp      int64 `json:"exp"`
}

type Signer struct {
	priv ed25519.PrivateKey
	KID  string
}

func NewSigner(priv ed25519.PrivateKey, kid string) *Signer { return &Signer{priv: priv, KID: kid} }

func (s *Signer) Public() ed25519.PublicKey { return s.priv.Public().(ed25519.PublicKey) }

func (s *Signer) Issue(acct, device string, epoch int, state string, readOnly bool, now time.Time) (string, Claims) {
	c := Claims{Acct: acct, Dev: device, Epoch: epoch, State: state, ReadOnly: readOnly, Iat: now.Unix(), Exp: now.Add(TTL).Unix()}
	head, _ := json.Marshal(map[string]string{"alg": "EdDSA", "typ": "JWT", "kid": s.KID})
	body, _ := json.Marshal(c)
	signing := base64.RawURLEncoding.EncodeToString(head) + "." + base64.RawURLEncoding.EncodeToString(body)
	sig := ed25519.Sign(s.priv, []byte(signing))
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), c
}

type Verifier struct{ pub ed25519.PublicKey }

func NewVerifier(pub ed25519.PublicKey) *Verifier { return &Verifier{pub: pub} }

func (v *Verifier) Verify(token string, now time.Time) (Claims, error) {
	var c Claims
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return c, ErrInvalid
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !ed25519.Verify(v.pub, []byte(parts[0]+"."+parts[1]), sig) {
		return c, ErrInvalid
	}
	body, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(body, &c) != nil || c.Acct == "" || c.Dev == "" {
		return c, ErrInvalid
	}
	if now.Unix() >= c.Exp || now.Unix() < c.Iat-60 {
		return c, ErrInvalid
	}
	return c, nil
}

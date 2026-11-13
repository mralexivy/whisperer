// Package devauth is device identity: each Mac holds a P-256 key pair, the server knows it by a deviceId
// derived from the public key, and proves a request comes from it with a signature over a server nonce.
// Nothing here is stored — the nonce is a MAC, so a challenge costs no database write.
//
// Wire formats (the Swift client must match these byte for byte):
//
//	devicePublicKey  base64 (standard alphabet, padded) of the 65-byte ANSI X9.63 uncompressed point
//	                 0x04 || X(32) || Y(32)  — CryptoKit P256.Signing.PublicKey.x963Representation.
//	deviceId         lowercase hex of the first 16 bytes of SHA-256(those 65 bytes): 32 hex chars.
//	nonce            lowercase hex (64 chars) of HMAC-SHA256(nonceKey, deviceId || bigEndianUint64(minute)),
//	                 where deviceId is the 32 ASCII hex chars and minute = unixSeconds / 60 at issue time.
//	                 Accepted while minute is the current or the previous minute: valid 60 to 120 s.
//	signature        ECDSA P-256 over SHA-256(M) where M = nonceBytes || purpose:
//	                 nonceBytes = the 32 raw bytes the hex nonce decodes to (NOT the hex text),
//	                 purpose    = the route's ASCII purpose string (constants below), no separator, no length.
//	                 With CryptoKit this is key.signature(for: nonceBytes + Data(purpose.utf8)).
//	                 Encoded as base64 (standard, padded) of the 64-byte raw r||s (rawRepresentation);
//	                 the ASN.1 DER form (derRepresentation) is accepted as well.
//	keyProof         lowercase hex of HMAC-SHA256(key = verifier, msg = challengeBytes || deviceId || suffix)
//	                 where verifier = SHA-256(authKey) (32 raw bytes), challengeBytes are the raw bytes of the
//	                 hex challenge (16 for an enrolChallenge, 32 for a nonce), deviceId is the 32 ASCII hex
//	                 chars and suffix is the purpose string ("" for device enrolment).
//	                 (The plan's literal "HMAC(authKey, …)" cannot be checked by a server that stores only
//	                 SHA-256(authKey); keying with the verifier is the verifiable form of the same proof.)
package devauth

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math/big"
	"strings"
	"time"
)

// Purposes: a signature made for one route is worthless on another.
const (
	PurposeAccountCreate = "account.create"
	PurposeDeviceEnroll  = "device.enroll"
	PurposeDeviceConfirm = "device.confirm"
	PurposeSession       = "session"
	PurposeRecoveryBlob  = "library.recovery-blob"
	PurposeReset         = "library.reset"
	// PurposeRecovery is the key-proof suffix (not a signature purpose) for replacing the recovery blob.
	PurposeRecovery = "library.recovery"
)

var (
	ErrBadKey       = errors.New("devauth: not a P-256 public key")
	ErrBadDeviceID  = errors.New("devauth: bad device id")
	ErrBadNonce     = errors.New("devauth: nonce invalid or expired")
	ErrBadSignature = errors.New("devauth: signature does not verify")
)

// ParsePublicKey decodes the wire form of a device public key and checks the point is on the curve.
func ParsePublicKey(b64 string) (*ecdsa.PublicKey, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) != 65 || raw[0] != 4 {
		return nil, ErrBadKey
	}
	if _, err := ecdh.P256().NewPublicKey(raw); err != nil { // rejects points not on the curve
		return nil, ErrBadKey
	}
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(raw[1:33]), Y: new(big.Int).SetBytes(raw[33:])}, nil
}

// EncodePublicKey is the inverse of ParsePublicKey (used by tests and tools).
func EncodePublicKey(k *ecdsa.PublicKey) string {
	raw := make([]byte, 65)
	raw[0] = 4
	k.X.FillBytes(raw[1:33])
	k.Y.FillBytes(raw[33:])
	return base64.StdEncoding.EncodeToString(raw)
}

// DeviceID is the first 16 bytes of SHA-256 of the 65-byte public key, hex.
func DeviceID(k *ecdsa.PublicKey) string {
	raw := make([]byte, 65)
	raw[0] = 4
	k.X.FillBytes(raw[1:33])
	k.Y.FillBytes(raw[33:])
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:16])
}

// ValidDeviceID reports whether s is 32 lowercase hex chars.
func ValidDeviceID(s string) bool { return isHex(s, 32) }

func isHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// Challenger mints and checks stateless nonces.
type Challenger struct{ key []byte }

// NewChallenger derives its MAC key from the server secret (domain-separated, so the secret that names
// subscriptions is never used directly as a MAC key here).
func NewChallenger(secret []byte) *Challenger {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte("whisperer-nonce-v1"))
	return &Challenger{key: m.Sum(nil)}
}

func (c *Challenger) mac(deviceID string, minute int64) []byte {
	m := hmac.New(sha256.New, c.key)
	m.Write([]byte(deviceID))
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(minute))
	m.Write(b[:])
	return m.Sum(nil)
}

// Nonce is the challenge for deviceID at `now`.
func (c *Challenger) Nonce(deviceID string, now time.Time) string {
	return hex.EncodeToString(c.mac(deviceID, now.Unix()/60))
}

// NonceBytes validates a nonce for deviceID and returns its raw bytes.
func (c *Challenger) NonceBytes(deviceID, nonce string, now time.Time) ([]byte, error) {
	if !ValidDeviceID(deviceID) || !isHex(nonce, 64) {
		return nil, ErrBadNonce
	}
	got, _ := hex.DecodeString(nonce)
	minute := now.Unix() / 60
	for _, m := range []int64{minute, minute - 1} {
		if hmac.Equal(got, c.mac(deviceID, m)) {
			return got, nil
		}
	}
	return nil, ErrBadNonce
}

// Verify checks that `sig` is the device key's signature over nonce||purpose and that the nonce is fresh
// for deviceID (the id derived from the key — callers must pass DeviceID(pub), never a client claim).
func (c *Challenger) Verify(pub *ecdsa.PublicKey, deviceID, nonce, purpose, sigB64 string, now time.Time) error {
	nb, err := c.NonceBytes(deviceID, nonce, now)
	if err != nil {
		return err
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		return ErrBadSignature
	}
	digest := sha256.Sum256(append(append([]byte{}, nb...), purpose...))
	switch {
	case len(sig) == 64:
		if !ecdsa.Verify(pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
			return ErrBadSignature
		}
	case ecdsa.VerifyASN1(pub, digest[:], sig):
	default:
		return ErrBadSignature
	}
	return nil
}

// Sign is the client side of Verify; the server never calls it, tests and tools do.
func Sign(priv *ecdsa.PrivateKey, nonce, purpose string) (string, error) {
	nb, err := hex.DecodeString(nonce)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(append(nb, purpose...))
	r, s, err := ecdsa.Sign(rand.Reader, priv, digest[:])
	if err != nil {
		return "", err
	}
	raw := make([]byte, 64)
	r.FillBytes(raw[:32])
	s.FillBytes(raw[32:])
	return base64.StdEncoding.EncodeToString(raw), nil
}

// Verifier is what the server stores for a library: SHA-256(authKey), hex.
func ValidVerifier(s string) bool { return isHex(s, 64) }

// KeyProof computes the proof the client sends and the server recomputes (see the package comment).
func KeyProof(verifierHex, challengeHex, deviceID, suffix string) (string, error) {
	v, err := hex.DecodeString(verifierHex)
	if err != nil || len(v) != 32 {
		return "", ErrBadKey
	}
	ch, err := hex.DecodeString(challengeHex)
	if err != nil || len(ch) == 0 {
		return "", ErrBadNonce
	}
	m := hmac.New(sha256.New, v)
	m.Write(ch)
	m.Write([]byte(deviceID))
	m.Write([]byte(suffix))
	return hex.EncodeToString(m.Sum(nil)), nil
}

// CheckKeyProof compares in constant time.
func CheckKeyProof(verifierHex, challengeHex, deviceID, suffix, proof string) bool {
	want, err := KeyProof(verifierHex, challengeHex, deviceID, suffix)
	if err != nil {
		return false
	}
	return hmac.Equal([]byte(strings.ToLower(proof)), []byte(want))
}

// NewRandomHex returns n random bytes as hex (account ids, enrolment challenges).
func NewRandomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic("devauth: no randomness: " + err.Error())
	}
	return hex.EncodeToString(b)
}

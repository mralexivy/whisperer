// Package apple verifies what Apple signs — StoreKit transactions and App Store Server Notifications V2 —
// without any dependency beyond the standard library.
//
// Both are compact JWS signed with ES256 by a leaf certificate carried in the header (`x5c`). The chain must
// lead to Apple Root CA - G3 (embedded here; SHA-256 63:34:3A:BF:…:3E:91:79) and carry Apple's marker
// extensions. The chain is checked at the time Apple signed the payload, not at "now": a transaction signed
// last month by a since-expired leaf is still a genuine transaction.
package apple

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

//go:embed AppleRootCA-G3.pem
var appleRootG3PEM []byte

var (
	// Apple's marker extensions: the leaf of a StoreKit/ASSN signing chain and the intermediate above it.
	oidLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}

	ErrMalformed = errors.New("apple: malformed JWS")
	ErrUntrusted = errors.New("apple: certificate chain is not Apple's")
	ErrSignature = errors.New("apple: bad signature")
)

// Verifier checks Apple-signed JWS values.
type Verifier struct {
	Roots *x509.CertPool
	// RequireAppleOIDs rejects chains lacking Apple's marker extensions. Always true outside tests.
	RequireAppleOIDs bool
	// Now is the clock used to refuse payloads signed in the future.
	Now func() time.Time
}

// NewVerifier trusts the embedded Apple Root CA - G3.
func NewVerifier() (*Verifier, error) {
	block, _ := pem.Decode(appleRootG3PEM)
	if block == nil {
		return nil, errors.New("apple: embedded root is unreadable")
	}
	root, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	pool.AddCert(root)
	return &Verifier{Roots: pool, RequireAppleOIDs: true, Now: time.Now}, nil
}

// RootFingerprint is the SHA-256 of the embedded root, for a startup log line and a test.
func RootFingerprint() string {
	block, _ := pem.Decode(appleRootG3PEM)
	sum := sha256.Sum256(block.Bytes)
	parts := make([]string, len(sum))
	for i, b := range sum {
		parts[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(parts, ":")
}

type header struct {
	Alg string   `json:"alg"`
	X5C []string `json:"x5c"`
}

// Verify returns the JSON payload of a JWS only if it was signed by a chain that leads to Apple's root.
func (v *Verifier) Verify(compact string) ([]byte, error) {
	parts := strings.Split(compact, ".")
	if len(parts) != 3 {
		return nil, ErrMalformed
	}
	headBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, ErrMalformed
	}
	var h header
	if json.Unmarshal(headBytes, &h) != nil || h.Alg != "ES256" || len(h.X5C) < 2 {
		return nil, ErrMalformed
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, ErrMalformed
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return nil, ErrMalformed
	}

	certs := make([]*x509.Certificate, len(h.X5C))
	for i, c := range h.X5C {
		der, err := base64.StdEncoding.DecodeString(c)
		if err != nil {
			return nil, ErrMalformed
		}
		if certs[i], err = x509.ParseCertificate(der); err != nil {
			return nil, ErrMalformed
		}
	}
	leaf := certs[0]

	// The chain is valid *when Apple signed*, so read signedDate before trusting anything.
	effective := v.now()
	var stamp struct {
		SignedDate int64 `json:"signedDate"`
	}
	if json.Unmarshal(payload, &stamp) == nil && stamp.SignedDate > 0 {
		at := time.UnixMilli(stamp.SignedDate)
		if at.After(v.now().Add(5 * time.Minute)) {
			return nil, fmt.Errorf("%w: signed in the future", ErrUntrusted)
		}
		effective = at
	}
	inter := x509.NewCertPool()
	for _, c := range certs[1:] {
		inter.AddCert(c)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots: v.Roots, Intermediates: inter, CurrentTime: effective,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUntrusted, err)
	}
	if v.RequireAppleOIDs && !(hasOID(leaf, oidLeaf) && hasOID(certs[1], oidIntermediate)) {
		return nil, fmt.Errorf("%w: missing Apple marker extensions", ErrUntrusted)
	}

	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, ErrUntrusted
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, digest[:], r, s) {
		return nil, ErrSignature
	}
	return payload, nil
}

func (v *Verifier) now() time.Time {
	if v.Now != nil {
		return v.Now()
	}
	return time.Now()
}

func hasOID(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}

// Transaction is the part of a StoreKit transaction the service uses. Dates are milliseconds since 1970.
type Transaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	Type                  string `json:"type"`
	Environment           string `json:"environment"`
	ExpiresDate           int64  `json:"expiresDate"`
	RevocationDate        int64  `json:"revocationDate"`
	SignedDate            int64  `json:"signedDate"`
	AppAccountToken       string `json:"appAccountToken"`
}

// RenewalInfo carries billing-retry and grace-period state.
type RenewalInfo struct {
	OriginalTransactionID  string `json:"originalTransactionId"`
	AutoRenewStatus        int    `json:"autoRenewStatus"`
	IsInBillingRetryPeriod bool   `json:"isInBillingRetryPeriod"`
	GracePeriodExpiresDate int64  `json:"gracePeriodExpiresDate"`
	SignedDate             int64  `json:"signedDate"`
}

// Notification is an App Store Server Notification V2 body, after the outer JWS is verified.
type Notification struct {
	NotificationType string `json:"notificationType"`
	Subtype          string `json:"subtype"`
	NotificationUUID string `json:"notificationUUID"`
	SignedDate       int64  `json:"signedDate"`
	Data             struct {
		Environment           string `json:"environment"`
		BundleID              string `json:"bundleId"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
		SignedRenewalInfo     string `json:"signedRenewalInfo"`
	} `json:"data"`
}

func (v *Verifier) Transaction(jws string) (Transaction, error) {
	var t Transaction
	payload, err := v.Verify(jws)
	if err != nil {
		return t, err
	}
	if err := json.Unmarshal(payload, &t); err != nil || t.OriginalTransactionID == "" {
		return t, ErrMalformed
	}
	return t, nil
}

func (v *Verifier) RenewalInfo(jws string) (RenewalInfo, error) {
	var r RenewalInfo
	payload, err := v.Verify(jws)
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(payload, &r); err != nil {
		return r, ErrMalformed
	}
	return r, nil
}

func (v *Verifier) Notification(jws string) (Notification, error) {
	var n Notification
	payload, err := v.Verify(jws)
	if err != nil {
		return n, err
	}
	if err := json.Unmarshal(payload, &n); err != nil || n.NotificationUUID == "" {
		return n, ErrMalformed
	}
	return n, nil
}

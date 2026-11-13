// Package testkit builds a private "Apple" for tests: a root, an intermediate and a leaf with Apple's marker
// extensions, and signs StoreKit-style JWS with them. Nothing here ships in the service binary.
package testkit

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
)

type Apple struct {
	Root     *x509.Certificate
	Inter    *x509.Certificate
	Leaf     *x509.Certificate
	LeafKey  *ecdsa.PrivateKey
	Pool     *x509.CertPool
	Now      time.Time
	Verifier *apple.Verifier
	leafDER  []byte
	interDER []byte
}

func New(t testing.TB, now time.Time) *Apple {
	t.Helper()
	a := &Apple{Now: now}
	rootKey := key(t)
	root := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test Apple Root"},
		NotBefore: now.Add(-10 * 365 * 24 * time.Hour), NotAfter: now.Add(10 * 365 * 24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	rootDER := sign(t, root, root, &rootKey.PublicKey, rootKey)
	a.Root, _ = x509.ParseCertificate(rootDER)

	interKey := key(t)
	inter := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "Test Apple Intermediate"},
		NotBefore: now.Add(-5 * 365 * 24 * time.Hour), NotAfter: now.Add(5 * 365 * 24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
		ExtraExtensions: []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}, Value: []byte{5, 0}}},
	}
	a.interDER = sign(t, inter, a.Root, &interKey.PublicKey, rootKey)
	a.Inter, _ = x509.ParseCertificate(a.interDER)

	a.LeafKey = key(t)
	leaf := &x509.Certificate{
		SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "Test Apple Leaf"},
		NotBefore: now.Add(-30 * 24 * time.Hour), NotAfter: now.Add(300 * 24 * time.Hour),
		KeyUsage:        x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}, Value: []byte{5, 0}}},
	}
	a.leafDER = sign(t, leaf, a.Inter, &a.LeafKey.PublicKey, interKey)
	a.Leaf, _ = x509.ParseCertificate(a.leafDER)

	a.Pool = x509.NewCertPool()
	a.Pool.AddCert(a.Root)
	a.Verifier = &apple.Verifier{Roots: a.Pool, RequireAppleOIDs: true, Now: func() time.Time { return a.Now }}
	return a
}

func key(t testing.TB) *ecdsa.PrivateKey {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func sign(t testing.TB, tpl, parent *x509.Certificate, pub *ecdsa.PublicKey, signer *ecdsa.PrivateKey) []byte {
	der, err := x509.CreateCertificate(rand.Reader, tpl, parent, pub, signer)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

// JWS signs `payload` (any JSON-able value) the way Apple does.
func (a *Apple) JWS(t testing.TB, payload any) string { return a.JWSWith(t, payload, a.LeafKey, true) }

// JWSWith lets a test sign with the wrong key or leave the chain out.
func (a *Apple) JWSWith(t testing.TB, payload any, signer *ecdsa.PrivateKey, withChain bool) string {
	t.Helper()
	chain := []string{base64.StdEncoding.EncodeToString(a.leafDER), base64.StdEncoding.EncodeToString(a.interDER)}
	if !withChain {
		chain = chain[:1]
	}
	head, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": chain})
	body, _ := json.Marshal(payload)
	signing := base64.RawURLEncoding.EncodeToString(head) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, signer, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// OtherKey is a key that is not Apple's, for forgery tests.
func OtherKey(t testing.TB) *ecdsa.PrivateKey { return key(t) }

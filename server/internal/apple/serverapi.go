package apple

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// ServerAPI is the App Store Server API: the authority on whether a subscription is alive. The server calls
// it when it binds a subscription, and always before deleting anyone's data — Firestore holds a cache of
// Apple's truth, never the truth itself.
type ServerAPI struct {
	KeyID, IssuerID, BundleID string
	Key                       *ecdsa.PrivateKey
	Verifier                  *Verifier
	Client                    *http.Client
	Now                       func() time.Time
	// Test hooks.
	ProductionBase, SandboxBase string
}

// Subscription status values reported by the API.
const (
	StatusActive  = 1
	StatusExpired = 2
	StatusRetry   = 3 // billing retry
	StatusGrace   = 4
	StatusRevoked = 5
)

// SubscriptionStatus is one verified entry of the API's answer.
type SubscriptionStatus struct {
	Status      int
	Transaction Transaction
	Renewal     RenewalInfo
}

// ParseP8 reads the In-App Purchase key downloaded from App Store Connect (PKCS #8 PEM, P-256).
func ParseP8(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("apple: the key is not PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apple: parsing key: %w", err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok || ec.Curve.Params().BitSize != 256 {
		return nil, errors.New("apple: the key is not a P-256 key")
	}
	return ec, nil
}

func (a *ServerAPI) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

func (a *ServerAPI) client() *http.Client {
	if a.Client != nil {
		return a.Client
	}
	return &http.Client{Timeout: 10 * time.Second}
}

// jwt is the ES256 bearer token the API requires: valid for at most 20 minutes, we use five.
func (a *ServerAPI) jwt() (string, error) {
	now := a.now()
	head, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.KeyID, "typ": "JWT"})
	body, _ := json.Marshal(map[string]any{"iss": a.IssuerID, "iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix(), "aud": "appstoreconnect-v1", "bid": a.BundleID})
	signing := base64.RawURLEncoding.EncodeToString(head) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, a.Key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64) // JWS wants raw r||s, 32 bytes each
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// ErrNotFound means Apple has no such transaction in the environment asked.
var ErrNotFound = errors.New("apple: transaction not found")

func (a *ServerAPI) get(ctx context.Context, base, originalTransactionID string) ([]byte, error) {
	token, err := a.jwt()
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, "GET", base+"/inApps/v1/subscriptions/"+url.PathEscape(originalTransactionID), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := a.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	switch {
	case resp.StatusCode == 404:
		return nil, ErrNotFound
	case resp.StatusCode != 200:
		return nil, fmt.Errorf("apple: server API answered %d", resp.StatusCode)
	}
	return data, nil
}

// Statuses asks Apple for the subscription's status — production first, then the sandbox (TestFlight and
// Xcode purchases live there). Every JWS in the answer is verified against Apple's root.
func (a *ServerAPI) Statuses(ctx context.Context, originalTransactionID string) ([]SubscriptionStatus, error) {
	prod, sandbox := a.ProductionBase, a.SandboxBase
	if prod == "" {
		prod = "https://api.storekit.itunes.apple.com"
	}
	if sandbox == "" {
		sandbox = "https://api.storekit-sandbox.itunes.apple.com"
	}
	data, err := a.get(ctx, prod, originalTransactionID)
	if errors.Is(err, ErrNotFound) {
		data, err = a.get(ctx, sandbox, originalTransactionID)
	}
	if err != nil {
		return nil, err
	}
	var resp struct {
		Data []struct {
			LastTransactions []struct {
				Status                int    `json:"status"`
				SignedTransactionInfo string `json:"signedTransactionInfo"`
				SignedRenewalInfo     string `json:"signedRenewalInfo"`
			} `json:"lastTransactions"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("apple: reading the server API answer: %w", err)
	}
	var out []SubscriptionStatus
	for _, group := range resp.Data {
		for _, last := range group.LastTransactions {
			tx, err := a.Verifier.Transaction(last.SignedTransactionInfo)
			if err != nil {
				return nil, fmt.Errorf("apple: a transaction in the server API answer is not signed by Apple: %w", err)
			}
			if a.BundleID != "" && tx.BundleID != a.BundleID {
				continue
			}
			s := SubscriptionStatus{Status: last.Status, Transaction: tx}
			if last.SignedRenewalInfo != "" {
				if ri, err := a.Verifier.RenewalInfo(last.SignedRenewalInfo); err == nil {
					s.Renewal = ri
				}
			}
			out = append(out, s)
		}
	}
	if len(out) == 0 {
		return nil, ErrNotFound
	}
	return out, nil
}

// Package gcp talks to Google Cloud over REST with nothing but the standard library: Firestore for the
// control plane, Cloud Storage for ciphertext, IAM Credentials for signing URLs. On Cloud Run the access
// token comes from the metadata server — there is no key file anywhere.
package gcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// TokenSource yields OAuth2 access tokens for the service account the process runs as.
type TokenSource interface {
	Token(ctx context.Context) (string, error)
	// Email is the service account's address (needed to sign URLs as it).
	Email(ctx context.Context) (string, error)
}

const metadataBase = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/"

// MetadataTokens reads tokens from the Cloud Run / GCE metadata server and caches them until a minute
// before expiry.
type MetadataTokens struct {
	Base   string // test hook; defaults to the real metadata server
	Client *http.Client

	mu     sync.Mutex
	token  string
	expiry time.Time
	email  string
}

func (m *MetadataTokens) base() string {
	if m.Base != "" {
		return m.Base
	}
	return metadataBase
}

func (m *MetadataTokens) client() *http.Client {
	if m.Client != nil {
		return m.Client
	}
	return &http.Client{Timeout: 5 * time.Second}
}

func (m *MetadataTokens) get(ctx context.Context, path string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", m.base()+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	resp, err := m.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("gcp: metadata %s: %d", path, resp.StatusCode)
	}
	return body, nil
}

func (m *MetadataTokens) Token(ctx context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.token != "" && time.Now().Before(m.expiry.Add(-time.Minute)) {
		return m.token, nil
	}
	body, err := m.get(ctx, "token")
	if err != nil {
		return "", err
	}
	var t struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &t); err != nil || t.AccessToken == "" {
		return "", errors.New("gcp: bad metadata token response")
	}
	m.token, m.expiry = t.AccessToken, time.Now().Add(time.Duration(t.ExpiresIn)*time.Second)
	return m.token, nil
}

func (m *MetadataTokens) Email(ctx context.Context) (string, error) {
	m.mu.Lock()
	if m.email != "" {
		defer m.mu.Unlock()
		return m.email, nil
	}
	m.mu.Unlock()
	body, err := m.get(ctx, "email")
	if err != nil {
		return "", err
	}
	m.mu.Lock()
	m.email = string(body)
	m.mu.Unlock()
	return string(body), nil
}

// StaticTokens is for local development and integration tests: a token from `gcloud auth print-access-token`
// and an explicit service-account email. Never used in production.
type StaticTokens struct{ AccessToken, ServiceAccount string }

func (s StaticTokens) Token(context.Context) (string, error) { return s.AccessToken, nil }
func (s StaticTokens) Email(context.Context) (string, error) { return s.ServiceAccount, nil }

// do sends an authenticated JSON request and decodes a JSON reply.
func do(ctx context.Context, c *http.Client, ts TokenSource, method, url string, body any, out any) (int, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return 0, err
		}
		rdr = bytesReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, rdr)
	if err != nil {
		return 0, err
	}
	tok, err := ts.Token(ctx)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode >= 300 {
		return resp.StatusCode, &APIError{Status: resp.StatusCode, Body: truncate(string(data), 300)}
	}
	if out != nil && len(data) > 0 {
		if err := json.Unmarshal(data, out); err != nil {
			return resp.StatusCode, err
		}
	}
	return resp.StatusCode, nil
}

// APIError is a non-2xx answer from a Google API.
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string { return fmt.Sprintf("gcp: HTTP %d: %s", e.Status, e.Body) }

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

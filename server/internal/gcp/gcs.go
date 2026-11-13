package gcp

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// Storage is Cloud Storage as the control plane needs it (syncplane.Blobs): object metadata, deletes and
// listing over the JSON API, and V4 signed URLs signed through IAM Credentials — the service account never
// holds a key file. The Mac talks to Cloud Storage directly with those URLs; this server never carries a byte
// of user data.
type Storage struct {
	Bucket string
	Tokens TokenSource
	Client *http.Client
	Now    func() time.Time
	// Test hooks; default to the real endpoints.
	APIBase, IAMBase, SignHost string
}

func (s *Storage) client() *http.Client {
	if s.Client != nil {
		return s.Client
	}
	return &http.Client{Timeout: 30 * time.Second}
}

func (s *Storage) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Storage) apiBase() string {
	if s.APIBase != "" {
		return s.APIBase
	}
	return "https://storage.googleapis.com"
}

func (s *Storage) iamBase() string {
	if s.IAMBase != "" {
		return s.IAMBase
	}
	return "https://iamcredentials.googleapis.com"
}

func (s *Storage) signHost() string {
	if s.SignHost != "" {
		return s.SignHost
	}
	return "storage.googleapis.com"
}

func (s *Storage) objectURL(name string) string {
	return fmt.Sprintf("%s/storage/v1/b/%s/o/%s", s.apiBase(), url.PathEscape(s.Bucket), url.PathEscape(name))
}

// Stat returns the stored size and crc32c.
func (s *Storage) Stat(ctx context.Context, name string) (int64, uint32, error) {
	var meta struct {
		Size   string `json:"size"`
		CRC32C string `json:"crc32c"`
	}
	status, err := do(ctx, s.client(), s.Tokens, "GET", s.objectURL(name)+"?fields=size,crc32c", nil, &meta)
	if status == 404 {
		return 0, 0, syncplane.ErrNotFound
	}
	if err != nil {
		return 0, 0, err
	}
	size, err := strconv.ParseInt(meta.Size, 10, 64)
	if err != nil {
		return 0, 0, errors.New("gcp: bad object size")
	}
	raw, err := base64.StdEncoding.DecodeString(meta.CRC32C)
	if err != nil || len(raw) != 4 {
		return 0, 0, errors.New("gcp: bad object crc32c")
	}
	return size, binary.BigEndian.Uint32(raw), nil
}

// Delete removes an object; a missing one is not an error.
func (s *Storage) Delete(ctx context.Context, name string) error {
	status, err := do(ctx, s.client(), s.Tokens, "DELETE", s.objectURL(name), nil, nil)
	if status == 404 {
		return nil
	}
	return err
}

// List returns up to n object names under prefix that sort after `after`.
func (s *Storage) List(ctx context.Context, prefix, after string, n int) ([]string, bool, error) {
	q := url.Values{"prefix": {prefix}, "maxResults": {strconv.Itoa(n + 1)}, "fields": {"items(name)"}}
	if after != "" {
		q.Set("startOffset", after)
	}
	var out struct {
		Items []struct {
			Name string `json:"name"`
		} `json:"items"`
	}
	u := fmt.Sprintf("%s/storage/v1/b/%s/o?%s", s.apiBase(), url.PathEscape(s.Bucket), q.Encode())
	if _, err := do(ctx, s.client(), s.Tokens, "GET", u, nil, &out); err != nil {
		return nil, false, err
	}
	var names []string
	for _, it := range out.Items {
		if it.Name > after { // startOffset is inclusive
			names = append(names, it.Name)
		}
	}
	if len(names) > n {
		return names[:n], true, nil
	}
	return names, false, nil
}

// MARK: V4 signed URLs

// SignPut returns a URL that creates `name` only if it does not exist (x-goog-if-generation-match: 0) and no
// larger than maxSize (x-goog-content-length-range), plus the headers the client must send with it —
// they are part of the signature. For resumable uploads (large objects) the URL is for the POST that
// starts the session (x-goog-resumable: start); the client then uploads to the session URI it gets back.
func (s *Storage) SignPut(name string, maxSize int64, ttl time.Duration, resumable bool) (string, map[string]string, error) {
	headers := map[string]string{
		"x-goog-content-length-range": "0," + strconv.FormatInt(maxSize, 10),
		"x-goog-if-generation-match":  "0",
	}
	method := "PUT"
	if resumable {
		method = "POST"
		headers["x-goog-resumable"] = "start"
	}
	u, err := s.signURL(context.Background(), method, name, ttl, headers)
	return u, headers, err
}

func (s *Storage) SignGet(name string, ttl time.Duration) (string, error) {
	return s.signURL(context.Background(), "GET", name, ttl, nil)
}

func (s *Storage) signURL(ctx context.Context, method, name string, ttl time.Duration, extra map[string]string) (string, error) {
	if ttl <= 0 || ttl > 7*24*time.Hour {
		return "", errors.New("gcp: signed URL lifetime must be between 1 s and 7 days")
	}
	email, err := s.Tokens.Email(ctx)
	if err != nil {
		return "", err
	}
	now := s.now().UTC()
	stringToSign, finish := V4StringToSign(method, s.Bucket, name, s.signHost(), email, now, ttl, extra)
	sig, err := s.signBlob(ctx, email, []byte(stringToSign))
	if err != nil {
		return "", err
	}
	return finish(hex.EncodeToString(sig)), nil
}

// V4StringToSign builds the canonical request and the string to sign for a Cloud Storage V4 signed URL, and a
// function that assembles the final URL from the hex signature. Exported so the algorithm can be tested
// against Google's documented format without any credentials.
func V4StringToSign(method, bucket, object, host, email string, now time.Time, ttl time.Duration, extra map[string]string) (stringToSign string, finish func(sigHex string) string) {
	date := now.Format("20060102")
	datetime := now.Format("20060102T150405Z")
	scope := date + "/auto/storage/goog4_request"

	headers := map[string]string{"host": host}
	for k, v := range extra {
		headers[strings.ToLower(k)] = strings.TrimSpace(v)
	}
	names := make([]string, 0, len(headers))
	for k := range headers {
		names = append(names, k)
	}
	sort.Strings(names)
	signed := strings.Join(names, ";")
	var canonicalHeaders strings.Builder
	for _, k := range names {
		canonicalHeaders.WriteString(k + ":" + headers[k] + "\n")
	}

	query := map[string]string{
		"X-Goog-Algorithm":     "GOOG4-RSA-SHA256",
		"X-Goog-Credential":    email + "/" + scope,
		"X-Goog-Date":          datetime,
		"X-Goog-Expires":       strconv.FormatInt(int64(ttl.Seconds()), 10),
		"X-Goog-SignedHeaders": signed,
	}
	keys := make([]string, 0, len(query))
	for k := range query {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, len(keys))
	for i, k := range keys {
		pairs[i] = uriEncode(k, true) + "=" + uriEncode(query[k], true)
	}
	canonicalQuery := strings.Join(pairs, "&")

	path := "/" + bucket + "/" + object
	canonicalPath := uriEncode(path, false)
	canonicalRequest := strings.Join([]string{method, canonicalPath, canonicalQuery, canonicalHeaders.String(), signed, "UNSIGNED-PAYLOAD"}, "\n")
	hash := sha256.Sum256([]byte(canonicalRequest))
	stringToSign = strings.Join([]string{"GOOG4-RSA-SHA256", datetime, scope, hex.EncodeToString(hash[:])}, "\n")
	finish = func(sigHex string) string {
		return "https://" + host + canonicalPath + "?" + canonicalQuery + "&X-Goog-Signature=" + sigHex
	}
	return stringToSign, finish
}

// uriEncode is the V4 encoding: unreserved characters stay, everything else is %XX; '/' stays in paths.
func uriEncode(s string, encodeSlash bool) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		case c == '/' && !encodeSlash:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// signBlob asks IAM Credentials to sign as the service account. The runtime account needs
// roles/iam.serviceAccountTokenCreator on itself.
func (s *Storage) signBlob(ctx context.Context, email string, payload []byte) ([]byte, error) {
	var out struct {
		SignedBlob string `json:"signedBlob"`
	}
	u := fmt.Sprintf("%s/v1/projects/-/serviceAccounts/%s:signBlob", s.iamBase(), url.PathEscape(email))
	if _, err := do(ctx, s.client(), s.Tokens, "POST", u, map[string]string{"payload": base64.StdEncoding.EncodeToString(payload)}, &out); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(out.SignedBlob)
}

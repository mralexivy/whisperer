package gcp_test

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/gcp"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

const sa = "whisperer-api@whisperer-491716.iam.gserviceaccount.com"

type fakeGCS struct {
	objects map[string][]byte
	crc     map[string]uint32
	signed  [][]byte
}

func newGCS(t *testing.T) (*gcp.Storage, *fakeGCS) {
	f := &fakeGCS{objects: map[string][]byte{}, crc: map[string]uint32{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/storage/v1/b/bkt/o/", func(w http.ResponseWriter, r *http.Request) {
		name, _ := url.PathUnescape(strings.TrimPrefix(r.URL.EscapedPath(), "/storage/v1/b/bkt/o/"))
		data, ok := f.objects[name]
		switch {
		case !ok:
			w.WriteHeader(404)
		case r.Method == "DELETE":
			delete(f.objects, name)
			w.WriteHeader(204)
		default:
			crc := make([]byte, 4)
			binary.BigEndian.PutUint32(crc, f.crc[name])
			_ = json.NewEncoder(w).Encode(map[string]string{"size": itoa(len(data)), "crc32c": base64.StdEncoding.EncodeToString(crc)})
		}
	})
	mux.HandleFunc("/storage/v1/b/bkt/o", func(w http.ResponseWriter, r *http.Request) {
		prefix, start := r.URL.Query().Get("prefix"), r.URL.Query().Get("startOffset")
		var items []map[string]string
		for _, name := range sortedKeys(f.objects) {
			if strings.HasPrefix(name, prefix) && name >= start {
				items = append(items, map[string]string{"name": name})
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
	})
	mux.HandleFunc("/v1/projects/-/serviceAccounts/", func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Payload string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		raw, _ := base64.StdEncoding.DecodeString(body.Payload)
		f.signed = append(f.signed, raw)
		_ = json.NewEncoder(w).Encode(map[string]string{"signedBlob": base64.StdEncoding.EncodeToString([]byte("SIG"))})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &gcp.Storage{Bucket: "bkt", Tokens: gcp.StaticTokens{AccessToken: "t", ServiceAccount: sa}, APIBase: srv.URL, IAMBase: srv.URL,
		Now: func() time.Time { return t0 }}, f
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func sortedKeys(m map[string][]byte) []string {
	var k []string
	for key := range m {
		k = append(k, key)
	}
	for i := range k {
		for j := i + 1; j < len(k); j++ {
			if k[j] < k[i] {
				k[i], k[j] = k[j], k[i]
			}
		}
	}
	return k
}

var _ syncplane.Blobs = (*gcp.Storage)(nil)

func TestStatDeleteAndListOverTheJSONAPI(t *testing.T) {
	s, f := newGCS(t)
	f.objects["whisperer/users/a/e1/audio/x"] = []byte("12345")
	f.crc["whisperer/users/a/e1/audio/x"] = 0xDEADBEEF
	f.objects["whisperer/users/a/e1/audio/y"] = []byte("1")
	ctx := context.Background()
	size, crc, err := s.Stat(ctx, "whisperer/users/a/e1/audio/x")
	if err != nil || size != 5 || crc != 0xDEADBEEF {
		t.Fatalf("stat: %d %x %v", size, crc, err)
	}
	if _, _, err := s.Stat(ctx, "nope"); err != syncplane.ErrNotFound {
		t.Fatalf("missing: %v", err)
	}
	names, more, err := s.List(ctx, "whisperer/users/a/", "whisperer/users/a/e1/audio/x", 10)
	if err != nil || more || len(names) != 1 || names[0] != "whisperer/users/a/e1/audio/y" {
		t.Fatalf("list after x: %v %v %v", names, more, err)
	}
	if err := s.Delete(ctx, "whisperer/users/a/e1/audio/x"); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(ctx, "whisperer/users/a/e1/audio/x"); err != nil {
		t.Fatalf("deleting a missing object must not fail: %v", err)
	}
}

func TestSignedPutURLCarriesTheSignedHeadersAndSignature(t *testing.T) {
	s, f := newGCS(t)
	u, headers, err := s.SignPut("whisperer/users/a/e1/audio/abc", 4096, 15*time.Minute, false)
	if err != nil {
		t.Fatal(err)
	}
	if headers["x-goog-if-generation-match"] != "0" || headers["x-goog-content-length-range"] != "0,4096" {
		t.Fatalf("headers: %v", headers)
	}
	parsed, _ := url.Parse(u)
	q := parsed.Query()
	if parsed.Host != "storage.googleapis.com" || parsed.Path != "/bkt/whisperer/users/a/e1/audio/abc" {
		t.Fatalf("url: %s", u)
	}
	if q.Get("X-Goog-Algorithm") != "GOOG4-RSA-SHA256" || q.Get("X-Goog-Expires") != "900" || q.Get("X-Goog-Date") != "20261113T120000Z" ||
		q.Get("X-Goog-Credential") != sa+"/20261113/auto/storage/goog4_request" ||
		q.Get("X-Goog-SignedHeaders") != "host;x-goog-content-length-range;x-goog-if-generation-match" ||
		q.Get("X-Goog-Signature") != "534947" { // hex of "SIG" from the fake IAM
		t.Fatalf("query: %v", q)
	}
	lines := strings.Split(string(f.signed[0]), "\n")
	if len(lines) != 4 || lines[0] != "GOOG4-RSA-SHA256" || lines[1] != "20261113T120000Z" || lines[2] != "20261113/auto/storage/goog4_request" || len(lines[3]) != 64 {
		t.Fatalf("string to sign: %q", f.signed[0])
	}
}

func TestResumableSigningUsesPOSTWithTheStartHeader(t *testing.T) {
	s, _ := newGCS(t)
	u, headers, err := s.SignPut("o", 10<<20, time.Hour, true)
	if err != nil || headers["x-goog-resumable"] != "start" || !strings.Contains(u, "x-goog-resumable") {
		t.Fatalf("%v %v %s", err, headers, u)
	}
}

func TestV4CanonicalRequestIsStableAndEncodesLikeGoogleDocuments(t *testing.T) {
	sts1, finish := gcp.V4StringToSign("GET", "b", "a b/ü.txt", "storage.googleapis.com", sa, t0, time.Minute, nil)
	sts2, _ := gcp.V4StringToSign("GET", "b", "a b/ü.txt", "storage.googleapis.com", sa, t0, time.Minute, nil)
	if sts1 != sts2 {
		t.Fatal("signing must be deterministic")
	}
	u := finish("00")
	if !strings.Contains(u, "/b/a%20b/%C3%BC.txt?") || !strings.HasSuffix(u, "&X-Goog-Signature=00") {
		t.Fatalf("path encoding: %s", u)
	}
	// Different header sets give different signatures (the headers are signed).
	other, _ := gcp.V4StringToSign("GET", "b", "a b/ü.txt", "storage.googleapis.com", sa, t0, time.Minute, map[string]string{"x-goog-resumable": "start"})
	if other == sts1 {
		t.Fatal("an extra signed header must change the string to sign")
	}
}

func TestSignedURLLifetimeIsBounded(t *testing.T) {
	s, _ := newGCS(t)
	if _, err := s.SignGet("o", 8*24*time.Hour); err == nil {
		t.Fatal("more than 7 days must be refused")
	}
	if _, err := s.SignGet("o", 0); err == nil {
		t.Fatal("zero lifetime must be refused")
	}
}

func TestMetadataTokensAreCachedAndCarryTheFlavorHeader(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Metadata-Flavor") != "Google" {
			w.WriteHeader(403)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/email") {
			_, _ = w.Write([]byte(sa))
			return
		}
		calls++
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "tok", "expires_in": 3600})
	}))
	defer srv.Close()
	m := &gcp.MetadataTokens{Base: srv.URL + "/"}
	for i := 0; i < 3; i++ {
		if tok, err := m.Token(context.Background()); err != nil || tok != "tok" {
			t.Fatalf("token: %q %v", tok, err)
		}
	}
	if calls != 1 {
		t.Fatalf("token fetched %d times, want 1 (cached)", calls)
	}
	if e, err := m.Email(context.Background()); err != nil || e != sa {
		t.Fatalf("email: %q %v", e, err)
	}
}

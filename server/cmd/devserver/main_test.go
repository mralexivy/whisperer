package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/devauth"
	"github.com/mralexivy/whisperer/server/internal/devstore"
	"github.com/mralexivy/whisperer/server/internal/quota"
)

func TestRefuseDeployments(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	cases := []struct {
		name string
		env  map[string]string
		addr string
		bad  bool
	}{
		{"local", nil, "127.0.0.1:8787", false},
		{"localhost", nil, "localhost:1", false},
		{"ipv6 loopback", nil, "[::1]:8787", false},
		{"production", map[string]string{"ENV": "production"}, "127.0.0.1:8787", true},
		{"cloud run", map[string]string{"K_SERVICE": "api"}, "127.0.0.1:8787", true},
		{"gcp project", map[string]string{"GCP_PROJECT": "p"}, "127.0.0.1:8787", true},
		{"all interfaces", nil, "0.0.0.0:8080", true},
		{"public name", nil, "example.com:80", true},
		{"no port", nil, "127.0.0.1", true},
	}
	for _, c := range cases {
		if got := refuse(env(c.env), c.addr) != ""; got != c.bad {
			t.Errorf("%s: refused=%v want %v", c.name, got, c.bad)
		}
	}
}

type client struct {
	t    *testing.T
	base string
}

func (c client) post(path string, body any, token string, out any) int {
	var buf bytes.Buffer
	_ = json.NewEncoder(&buf).Encode(body)
	req, _ := http.NewRequest("POST", c.base+path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	if out != nil {
		_ = json.NewDecoder(res.Body).Decode(out)
	}
	return res.StatusCode
}

// TestEndToEndAgainstFakeStorage runs the real handlers, a minted test-Apple purchase and the fake bucket:
// account -> library -> large resumable upload with a cut connection -> commit -> ranged download.
func TestEndToEndAgainstFakeStorage(t *testing.T) {
	ts := httptest.NewUnstartedServer(nil)
	h, bucket := build("http://"+ts.Listener.Addr().String(), nil)
	ts.Config.Handler = h
	ts.Start()
	defer ts.Close()
	c := client{t, ts.URL}

	var minted struct{ JWS string }
	if code := c.post("/dev/mint-transaction", map[string]any{"productId": "com.ivy.whisperer.cloud.standard.monthly", "appAccountToken": "6f1c2d3e-0000-4000-8000-000000000009"}, "", &minted); code != 200 {
		t.Fatalf("mint: %d", code)
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	devID := devauth.DeviceID(&key.PublicKey)
	var ch struct{ Nonce string }
	c.post("/v1/auth/challenge", map[string]string{"deviceId": devID}, "", &ch)
	sig, _ := devauth.Sign(key, ch.Nonce, devauth.PurposeAccountCreate)
	var acct struct {
		Token string
		Epoch int
	}
	if code := c.post("/v1/accounts", map[string]any{"transactionJWS": minted.JWS, "devicePublicKey": devauth.EncodePublicKey(&key.PublicKey), "nonce": ch.Nonce, "sig": sig}, "", &acct); code != 201 {
		t.Fatalf("account: %d", code)
	}
	if code := c.post("/v1/library", map[string]any{"keyVerifier": fmt.Sprintf("%064x", 1)}, acct.Token, nil); code != 201 {
		t.Fatalf("library: %d", code)
	}

	// 9 MiB object: large enough that the server hands out a resumable session.
	data := make([]byte, 9<<20)
	_, _ = rand.Read(data)
	crc := crc32.Checksum(data, crc32.MakeTable(crc32.Castagnoli))
	devSeqObj := map[string]any{"kind": "audio", "id": fmt.Sprintf("%032x", 7)}
	var grants struct {
		Grants []struct {
			URL       string
			Resumable bool
			Headers   map[string]string
		}
	}
	if code := c.post("/v1/sync/upload", map[string]any{"objects": []any{map[string]any{"ref": devSeqObj, "size": len(data)}}}, acct.Token, &grants); code != 200 || !grants.Grants[0].Resumable {
		t.Fatalf("grant: %d %+v", code, grants)
	}
	g := grants.Grants[0]
	req, _ := http.NewRequest("POST", g.URL, nil)
	for k, v := range g.Headers {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != 201 {
		t.Fatalf("start session: %v %v", err, res)
	}
	session := res.Header.Get("Location")
	put := func(a, b int) int {
		req, _ := http.NewRequest("PUT", session, bytes.NewReader(data[a:b]))
		req.Header.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", a, b-1, len(data)))
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			return -1
		}
		res.Body.Close()
		return res.StatusCode
	}
	half := 4 << 20 // a multiple of 256 KiB
	if code := put(0, half); code != 308 {
		t.Fatalf("chunk 1: %d", code)
	}
	var f devstore.Faults
	f.DropChunks.Count, f.DropChunks.Persist = 1, true
	c.post("/dev/fault", f, "", nil)
	if code := put(half, len(data)); code != -1 {
		t.Fatalf("the cut final chunk should be a transport error, got %d", code)
	}
	// The final chunk was stored before the reply was lost, so a status query says the object is complete.
	req, _ = http.NewRequest("PUT", session, nil)
	req.Header.Set("Content-Range", fmt.Sprintf("bytes */%d", len(data)))
	res, err = http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != 200 {
		t.Fatalf("status query: %v %v", err, res)
	}
	size, gotCRC, err := bucket.Stat(context.Background(), "whisperer-dev/users/"+nameOf(t, ts.URL, acct.Token)+"audio/"+devSeqObj["id"].(string))
	if err != nil || size != int64(len(data)) || gotCRC != crc {
		t.Fatalf("stat: %d %x %v", size, gotCRC, err)
	}

	// Commit needs a change batch (the engine's job); here just check the data plane serves ranges back.
	var dl struct{ Grants []struct{ URL string } }
	if code := c.post("/v1/sync/download", map[string]any{"objects": []any{devSeqObj}}, acct.Token, &dl); code != 200 {
		t.Fatalf("download grant: %d", code)
	}
	req, _ = http.NewRequest("GET", dl.Grants[0].URL, nil)
	req.Header.Set("Range", "bytes=100-199")
	res, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(res.Body)
	if res.StatusCode != 206 || !bytes.Equal(got, data[100:200]) {
		t.Fatalf("ranged get: %d", res.StatusCode)
	}
	if st := bucket.Stats(); st.SessionStarts != 1 || st.Dropped != 1 || st.StatusQueries != 1 {
		t.Fatalf("stats: %+v", st)
	}
}

// nameOf recovers the account's object prefix from the session token's claims.
func nameOf(t *testing.T, _ string, token string) string {
	parts := strings.Split(token, ".")
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var c struct {
		Acct  string `json:"acct"`
		Epoch int    `json:"epoch"`
	}
	_ = json.Unmarshal(raw, &c)
	return fmt.Sprintf("%s/e%d/", c.Acct, c.Epoch)
}

// TestInspectionEndpoints: the dev API a test uses to look into the bucket (list, read, grep, overwrite) and to shrink a plan.
func TestInspectionEndpoints(t *testing.T) {
	ts := httptest.NewUnstartedServer(nil)
	h, bucket := build("http://"+ts.Listener.Addr().String(), nil)
	ts.Config.Handler = h
	ts.Start()
	defer ts.Close()

	url, headers, err := bucket.SignPut("whisperer-dev/users/x/e1/audio/"+fmt.Sprintf("%032x", 1), 1<<20, time.Minute, false)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("PUT", url, strings.NewReader("hello PLAINTEXT world"))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode/100 != 2 {
		t.Fatalf("put: %v %v", err, res)
	}
	name := "whisperer-dev/users/x/e1/audio/" + fmt.Sprintf("%032x", 1)
	get := func(path string) (int, string) {
		res, err := http.Get(ts.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		b, _ := io.ReadAll(res.Body)
		return res.StatusCode, string(b)
	}
	if code, body := get("/dev/objects?prefix=whisperer-dev/users/x/"); code != 200 || !strings.Contains(body, name) {
		t.Fatalf("objects: %d %s", code, body)
	}
	c := client{t, ts.URL}
	var found struct {
		Matches []string
		Scanned int
	}
	c.post("/dev/grep", map[string]string{"marker": "PLAINTEXT"}, "", &found)
	if len(found.Matches) != 1 || found.Scanned != 1 {
		t.Fatalf("grep: %+v", found)
	}
	req, _ = http.NewRequest("PUT", ts.URL+"/dev/object?name="+name, strings.NewReader("tampered"))
	if res, err := http.DefaultClient.Do(req); err != nil || res.StatusCode != 200 {
		t.Fatalf("overwrite: %v %v", err, res)
	}
	if _, body := get("/dev/object?name=" + name); body != "tampered" {
		t.Fatalf("object: %q", body)
	}
	if code, _ := get("/dev/object?name=nope"); code != 404 {
		t.Fatalf("missing: %d", code)
	}
	c.post("/dev/grep", map[string]string{"marker": "PLAINTEXT"}, "", &found)
	if len(found.Matches) != 0 {
		t.Fatalf("grep after overwrite: %+v", found)
	}

	original := append([]quota.Plan(nil), quota.Plans...)
	defer func() { copy(quota.Plans, original) }()
	if code := c.post("/dev/set-plan", map[string]any{"tier": "starter", "storedBytes": 1234, "monthlyDownloadBytes": 5, "monthlyUploadGrants": 7}, "", nil); code != 200 {
		t.Fatalf("set-plan: %d", code)
	}
	if quota.Plans[0].StoredBytes != 1234 || quota.Plans[0].MonthlyUploadGrants != 7 {
		t.Fatalf("plan not updated: %+v", quota.Plans[0])
	}
	if code := c.post("/dev/set-plan", map[string]any{"tier": "nope"}, "", nil); code != 404 {
		t.Fatalf("unknown tier: %d", code)
	}
}

//go:build integration

package gcp_test

// Runs the REAL clients against REAL Google Cloud (Firestore and Cloud Storage) in a throwaway namespace.
//
//	GCP_IT_TOKEN=$(gcloud auth print-access-token) GCP_IT_PROJECT=whisperer-491716 \
//	GCP_IT_BUCKET=whisperer-491716-user-data GCP_IT_SA=whisperer-api@whisperer-491716.iam.gserviceaccount.com \
//	go test -tags integration -run TestReal -count=1 -v ./internal/gcp
//
// Everything it writes lives under envs/it-<random> (Firestore) and whisperer-it/<random>/ (bucket) and is
// deleted at the end.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"hash/crc32"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/account/accounttest"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/gcp"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

func itEnv(t *testing.T) (tokens gcp.StaticTokens, project, bucket string) {
	tok, project, bucket, sa := os.Getenv("GCP_IT_TOKEN"), os.Getenv("GCP_IT_PROJECT"), os.Getenv("GCP_IT_BUCKET"), os.Getenv("GCP_IT_SA")
	if tok == "" || project == "" || bucket == "" || sa == "" {
		t.Skip("set GCP_IT_TOKEN, GCP_IT_PROJECT, GCP_IT_BUCKET, GCP_IT_SA")
	}
	return gcp.StaticTokens{AccessToken: tok, ServiceAccount: sa}, project, bucket
}

func randHex(n int) string { b := make([]byte, n); _, _ = rand.Read(b); return hex.EncodeToString(b) }

var itCollections = []string{"accounts", "subscriptions", "tokens", "devices", "entitlements", "sync_heads", "sync_usage"}

// cleanup deletes every document the test created under its root.
func cleanup(t *testing.T, fs *gcp.Firestore, tokens gcp.StaticTokens) {
	t.Helper()
	for _, coll := range itCollections {
		for {
			url := "https://firestore.googleapis.com/v1/projects/" + fs.Project + "/databases/(default)/documents/" + fs.Root + "/" + coll + "?pageSize=100&mask.fieldPaths=x"
			req, _ := http.NewRequest("GET", url, nil)
			req.Header.Set("Authorization", "Bearer "+tokens.AccessToken)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				return
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			names := nameRe(string(body))
			if len(names) == 0 {
				break
			}
			for _, n := range names {
				path := strings.TrimPrefix(n, "projects/"+fs.Project+"/databases/(default)/documents/"+fs.Root+"/")
				_ = fs.Delete(context.Background(), path)
			}
		}
	}
}

func nameRe(body string) []string {
	var out []string
	for _, part := range strings.Split(body, "\"name\": \"")[1:] {
		out = append(out, part[:strings.Index(part, "\"")])
	}
	return out
}

func newRealFS(t *testing.T) *gcp.Firestore {
	tokens, project, _ := itEnv(t)
	fs := &gcp.Firestore{Project: project, Root: "envs/it-" + randHex(6), Tokens: tokens}
	t.Cleanup(func() { cleanup(t, fs, tokens) })
	return fs
}

func TestRealFirestoreRoundTripAndTransactions(t *testing.T) {
	fs := newRealFS(t)
	ctx := context.Background()
	in := doc{Name: "x", N: 1 << 40, Ratio: 0.5, On: true, Tags: []string{"a"}, Nested: map[string]int64{"k": 7}, At: t0}
	if err := fs.Set(ctx, "sync_usage/rt", in); err != nil {
		t.Fatal(err)
	}
	var out doc
	if err := fs.Get(ctx, "sync_usage/rt", &out); err != nil || out.N != 1<<40 || !out.At.Equal(t0) || out.Nested["k"] != 7 {
		t.Fatalf("round trip: %+v %v", out, err)
	}
	if err := fs.Get(ctx, "sync_usage/absent", &out); err != gcp.ErrNotFound {
		t.Fatalf("absent: %v", err)
	}
	// Real transactions under real contention: no update may be lost.
	store := gcp.SyncStore{FS: fs}
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := store.UpdateUsage(ctx, "acct", func(u *syncplane.Usage) error { u.Committed += 10; return nil }); err != nil {
				t.Errorf("update: %v", err)
			}
		}()
	}
	wg.Wait()
	if u, _ := store.GetUsage(ctx, "acct"); u.Committed != 120 {
		t.Fatalf("committed = %d, want 120: a real transactional update was lost", u.Committed)
	}
	// An aborted transaction writes nothing.
	_ = store.UpdateUsage(ctx, "acct", func(u *syncplane.Usage) error { u.Committed = 1; return syncplane.ErrReadOnly })
	if u, _ := store.GetUsage(ctx, "acct"); u.Committed != 120 {
		t.Fatalf("an aborted update leaked: %d", u.Committed)
	}
}

func TestRealEntitlementQueries(t *testing.T) {
	fs := newRealFS(t)
	store := gcp.EntitlementStore{FS: fs}
	ctx := context.Background()
	now := time.Now().UTC()
	old := lapsedEntitlement("old", "tx-"+randHex(4), 300, now)
	paid := lapsedEntitlement("paid", "tx-"+randHex(4), -20, now)
	for _, e := range []entitlement.Entitlement{old, paid} {
		if err := store.Put(ctx, e); err != nil {
			t.Fatal(err)
		}
	}
	// Firestore indexes are eventually built for new fields; the single-field index is automatic.
	var due []entitlement.Entitlement
	var err error
	for i := 0; i < 10; i++ {
		if due, err = store.Due(ctx, now, 10); err == nil && len(due) == 1 {
			break
		}
		time.Sleep(time.Second)
	}
	if err != nil || len(due) != 1 || due[0].UID != "old" {
		t.Fatalf("due: %+v %v", due, err)
	}
	if by, ok, err := store.ByOriginalTransactionID(ctx, old.OriginalTransactionID); err != nil || !ok || by.UID != "old" {
		t.Fatalf("by transaction: %+v %v %v", by, ok, err)
	}
}

func TestRealAccountStoreContract(t *testing.T) {
	itEnv(t)
	accounttest.Contract(t, func(t *testing.T) account.Store { return gcp.AccountStore{FS: newRealFS(t)} })
}

func TestRealStorageSignedURLsAndObjectOperations(t *testing.T) {
	tokens, _, bucket := itEnv(t)
	s := &gcp.Storage{Bucket: bucket, Tokens: tokens}
	ctx := context.Background()
	prefix := "whisperer-it/" + randHex(6) + "/"
	name := prefix + "audio/" + randHex(16)
	t.Cleanup(func() { _ = s.Delete(ctx, name); _ = s.Delete(ctx, name+"-big") })
	data := bytes.Repeat([]byte("ciphertext-"), 1000)

	putURL, headers, err := s.SignPut(name, int64(len(data)), 5*time.Minute, false)
	if err != nil {
		t.Fatalf("sign put (needs signBlob permission): %v", err)
	}
	send := func(method, url string, body []byte, h map[string]string) *http.Response {
		req, _ := http.NewRequest(method, url, bytes.NewReader(body))
		for k, v := range h {
			req.Header.Set(k, v)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	resp := send("PUT", putURL, data, headers)
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("signed PUT failed: %d %s", resp.StatusCode, b)
	}
	// The same URL again must not overwrite: x-goog-if-generation-match: 0.
	resp = send("PUT", putURL, []byte("overwrite"), headers)
	resp.Body.Close()
	if resp.StatusCode != 412 {
		t.Fatalf("a second PUT must be refused with 412, got %d", resp.StatusCode)
	}
	size, crc, err := s.Stat(ctx, name)
	if err != nil || size != int64(len(data)) || crc != crc32.Checksum(data, crc32.MakeTable(crc32.Castagnoli)) {
		t.Fatalf("stat: size=%d crc=%x err=%v", size, crc, err)
	}
	// Too large for the signed content-length-range.
	bigURL, bigHeaders, _ := s.SignPut(name+"-big", 10, time.Minute, false)
	resp = send("PUT", bigURL, data, bigHeaders)
	resp.Body.Close()
	if resp.StatusCode < 400 {
		t.Fatalf("an object above the signed size limit must be refused, got %d", resp.StatusCode)
	}
	// Download through a signed GET.
	getURL, err := s.SignGet(name, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	resp = send("GET", getURL, nil, nil)
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !bytes.Equal(got, data) {
		t.Fatalf("signed GET: %d (%d bytes)", resp.StatusCode, len(got))
	}
	// A tampered URL (different object name) must fail.
	resp = send("GET", strings.Replace(getURL, "/audio/", "/audio/x", 1), nil, nil)
	resp.Body.Close()
	if resp.StatusCode == 200 {
		t.Fatal("a URL for another object name must not validate")
	}
	// Resumable start: POST with the signed headers returns a session URI.
	rURL, rHeaders, err := s.SignPut(name+"-big", 10<<20, time.Hour, true)
	if err != nil {
		t.Fatal(err)
	}
	resp = send("POST", rURL, nil, rHeaders)
	resp.Body.Close()
	if resp.StatusCode != 201 || resp.Header.Get("Location") == "" {
		t.Fatalf("resumable start: %d, Location %q", resp.StatusCode, resp.Header.Get("Location"))
	}
	// List and delete.
	names, _, err := s.List(ctx, prefix, "", 10)
	if err != nil || len(names) != 1 || names[0] != name {
		t.Fatalf("list: %v %v", names, err)
	}
	if err := s.Delete(ctx, name); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Stat(ctx, name); err != syncplane.ErrNotFound {
		t.Fatalf("after delete: %v", err)
	}
}

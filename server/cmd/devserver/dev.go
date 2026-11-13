package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/mralexivy/whisperer/server/internal/devstore"
	"github.com/mralexivy/whisperer/server/internal/quota"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

// clock is real time plus an offset a test can advance, so "the subscription expired" needs no waiting.
type clock struct {
	mu     sync.Mutex
	offset time.Duration
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Now().Add(c.offset)
}

func (c *clock) advance(d time.Duration) { c.mu.Lock(); c.offset += d; c.mu.Unlock() }

// panicTB lets testkit (written for *testing.T) run in a binary.
type panicTB struct{}

func (panicTB) Helper()        {}
func (panicTB) Fatal(a ...any) { panic(a) }

// devAPI is everything under /dev/: the knobs a test needs that production does not have.
type devAPI struct {
	apple  *testkit.Apple
	clock  *clock
	bucket *devstore.Bucket
	txSeq  int
	mu     sync.Mutex
}

func newDevAPI(c *clock, b *devstore.Bucket) *devAPI {
	return &devAPI{apple: testkit.New(panicTB{}, c.Now()), clock: c, bucket: b}
}

func (d *devAPI) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /dev/mint-transaction", d.mint)
	mux.HandleFunc("POST /dev/advance-clock", d.advance)
	mux.HandleFunc("POST /dev/fault", d.fault)
	mux.HandleFunc("GET /dev/stats", d.stats)
	mux.HandleFunc("GET /dev/objects", d.objects)
	mux.HandleFunc("GET /dev/object", d.getObject)
	mux.HandleFunc("PUT /dev/object", d.putObject)
	mux.HandleFunc("POST /dev/grep", d.grep)
	mux.HandleFunc("POST /dev/set-plan", d.setPlan)
	return mux
}

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// mint signs a StoreKit-style transaction with the test Apple root the server trusts.
func (d *devAPI) mint(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ProductID             string `json:"productId"`
		OriginalTransactionID string `json:"originalTransactionId"`
		AppAccountToken       string `json:"appAccountToken"`
		ExpiresInSeconds      int64  `json:"expiresInSeconds"`
		Environment           string `json:"environment"`
		Revoked               bool   `json:"revoked"`
		BundleID              string `json:"bundleId"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil || req.ProductID == "" {
		reply(w, 400, map[string]string{"error": "bad_request", "message": "productId is required"})
		return
	}
	if req.OriginalTransactionID == "" {
		raw := make([]byte, 6)
		_, _ = rand.Read(raw)
		req.OriginalTransactionID = "dev-" + hex.EncodeToString(raw)
	}
	if req.Environment == "" {
		req.Environment = "Sandbox"
	}
	if req.BundleID == "" {
		req.BundleID = "com.ivy.whisperer"
	}
	if req.ExpiresInSeconds == 0 {
		req.ExpiresInSeconds = 30 * 24 * 3600
	}
	d.mu.Lock()
	d.txSeq++
	seq := d.txSeq
	d.mu.Unlock()
	now := d.clock.Now()
	expires := now.Add(time.Duration(req.ExpiresInSeconds) * time.Second)
	payload := map[string]any{
		"originalTransactionId": req.OriginalTransactionID, "transactionId": req.OriginalTransactionID + "-" + strconv.Itoa(seq),
		"bundleId": req.BundleID, "productId": req.ProductID, "type": "Auto-Renewable Subscription", "environment": req.Environment,
		"expiresDate": expires.UnixMilli(), "signedDate": now.UnixMilli(),
	}
	if req.AppAccountToken != "" {
		payload["appAccountToken"] = req.AppAccountToken
	}
	if req.Revoked {
		payload["revocationDate"] = now.UnixMilli()
	}
	reply(w, 200, map[string]any{"jws": d.apple.JWS(panicTB{}, payload), "originalTransactionId": req.OriginalTransactionID, "expiresDate": expires.UnixMilli()})
}

func (d *devAPI) advance(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Seconds int64 `json:"seconds"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
		reply(w, 400, map[string]string{"error": "bad_request"})
		return
	}
	d.clock.advance(time.Duration(req.Seconds) * time.Second)
	reply(w, 200, map[string]any{"now": d.clock.Now().UTC()})
}

func (d *devAPI) fault(w http.ResponseWriter, r *http.Request) {
	var f devstore.Faults
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&f); err != nil {
		reply(w, 400, map[string]string{"error": "bad_request"})
		return
	}
	d.bucket.SetFaults(f)
	reply(w, 200, f)
}

func (d *devAPI) stats(w http.ResponseWriter, _ *http.Request) { reply(w, 200, d.bucket.Stats()) }

// objects lists what the bucket holds under ?prefix= (name -> size): the test's window onto "what Google can see".
func (d *devAPI) objects(w http.ResponseWriter, r *http.Request) {
	reply(w, 200, d.bucket.Names(r.URL.Query().Get("prefix")))
}

func (d *devAPI) getObject(w http.ResponseWriter, r *http.Request) {
	data, ok := d.bucket.Raw(r.URL.Query().Get("name"))
	if !ok {
		reply(w, 404, map[string]string{"error": "not_found"})
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(data)
}

// putObject replaces an existing object's bytes: a tampering (or "restore the original") test.
func (d *devAPI) putObject(w http.ResponseWriter, r *http.Request) {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<20))
	if err != nil || !d.bucket.Overwrite(r.URL.Query().Get("name"), data) {
		reply(w, 404, map[string]string{"error": "not_found"})
		return
	}
	reply(w, 200, map[string]int{"size": len(data)})
}

// grep reports which stored objects contain `marker` (plaintext that must never reach the bucket).
func (d *devAPI) grep(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Marker string `json:"marker"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil || req.Marker == "" {
		reply(w, 400, map[string]string{"error": "bad_request"})
		return
	}
	matches, scanned := d.bucket.Grep([]byte(req.Marker))
	reply(w, 200, map[string]any{"matches": matches, "scanned": scanned})
}

// setPlan rewrites one tier's limits in place (e.g. a 1 MB "starter") so a test can hit the quota without
// uploading gigabytes. Development only: it mutates the process-wide plan table the real handlers read.
func (d *devAPI) setPlan(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Tier                 string `json:"tier"`
		StoredBytes          int64  `json:"storedBytes"`
		MonthlyDownloadBytes int64  `json:"monthlyDownloadBytes"`
		MonthlyUploadGrants  int    `json:"monthlyUploadGrants"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<10)).Decode(&req); err != nil {
		reply(w, 400, map[string]string{"error": "bad_request"})
		return
	}
	for i := range quota.Plans {
		if quota.Plans[i].Name == req.Tier {
			quota.Plans[i].Limits = quota.Limits{StoredBytes: req.StoredBytes, MonthlyDownloadBytes: req.MonthlyDownloadBytes, MonthlyUploadGrants: req.MonthlyUploadGrants}
			reply(w, 200, quota.Plans[i])
			return
		}
	}
	reply(w, 404, map[string]string{"error": "unknown_tier"})
}

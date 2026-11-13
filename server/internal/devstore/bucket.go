// Package devstore is a fake Cloud Storage for development and end-to-end tests: an in-process bucket that
// implements syncplane.Blobs (what the control plane needs) and serves the signed-URL data plane the Mac talks
// to (simple PUT with ifGenerationMatch=0 and a content-length range, resumable sessions with the Content-Range
// chunk protocol and "bytes */N" status queries, ranged GET). It exists so the Mac's real HTTP transport runs
// against the real server handlers. It is NOT a security boundary and must never be deployed: only
// cmd/devserver (which refuses ENV=production) uses it.
package devstore

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// ChunkMultiple is the granularity Cloud Storage demands of every non-final resumable chunk.
const ChunkMultiple = 256 << 10

var castagnoli = crc32.MakeTable(crc32.Castagnoli)

type object struct {
	data []byte
	crc  uint32
	gen  int64
}

type session struct {
	name   string
	max    int64
	data   []byte
	total  int64 // -1 until a final chunk announces it
	done   bool
	failed bool // finalised with 412: the object existed
}

// Stats counts what the data plane has seen, so a test can prove a resume really happened.
type Stats struct {
	SimplePuts    int `json:"simplePuts"`
	SessionStarts int `json:"sessionStarts"`
	ChunkPuts     int `json:"chunkPuts"`
	StatusQueries int `json:"statusQueries"`
	Gets          int `json:"gets"`
	RangedGets    int `json:"rangedGets"`
	Dropped       int `json:"dropped"`
	Errors        int `json:"errors"`
}

// Faults are one-shot knobs for failure injection; they apply to the next requests that match.
type Faults struct {
	// DropChunks: after `After` chunk PUTs have been accepted, the next `Count` chunk PUTs are cut: the
	// connection is closed with no response. With Persist the bytes are stored first (the reply was lost);
	// without it they are discarded (the request died on the way).
	DropChunks struct {
		After   int  `json:"after"`
		Count   int  `json:"count"`
		Persist bool `json:"persist"`
	} `json:"dropChunks"`
	// DropGets: cut the next `Count` GETs after sending half the requested bytes.
	DropGets struct {
		After int `json:"after"`
		Count int `json:"count"`
	} `json:"dropGets"`
	// ErrorNext answers the next `Count` data-plane requests with `Code`.
	ErrorNext struct {
		Code  int `json:"code"`
		Count int `json:"count"`
	} `json:"errorNext"`
}

type Bucket struct {
	Base string // "http://127.0.0.1:PORT": where signed URLs point
	Now  func() time.Time

	secret []byte
	mu     sync.Mutex
	objs   map[string]*object
	sess   map[string]*session
	gen    int64
	stats  Stats
	faults Faults
	chunks int // accepted chunk PUTs, for Faults.DropChunks.After
	gets   int
}

func New(base string, now func() time.Time) *Bucket {
	if now == nil {
		now = time.Now
	}
	secret := make([]byte, 32)
	_, _ = rand.Read(secret)
	return &Bucket{Base: strings.TrimRight(base, "/"), Now: now, secret: secret, objs: map[string]*object{}, sess: map[string]*session{}}
}

func (b *Bucket) Stats() Stats { b.mu.Lock(); defer b.mu.Unlock(); return b.stats }

func (b *Bucket) SetFaults(f Faults) {
	b.mu.Lock()
	b.faults, b.chunks, b.gets = f, 0, 0
	b.mu.Unlock()
}

// MARK: syncplane.Blobs

func (b *Bucket) Stat(_ context.Context, name string) (int64, uint32, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	o, ok := b.objs[name]
	if !ok {
		return 0, 0, syncplane.ErrNotFound
	}
	return int64(len(o.data)), o.crc, nil
}

func (b *Bucket) Delete(_ context.Context, name string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.objs, name)
	return nil
}

func (b *Bucket) List(_ context.Context, prefix, after string, n int) ([]string, bool, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	var all []string
	for k := range b.objs {
		if strings.HasPrefix(k, prefix) && k > after {
			all = append(all, k)
		}
	}
	sort.Strings(all)
	if len(all) > n {
		return all[:n], true, nil
	}
	return all, false, nil
}

// Count is the number of stored objects under prefix.
func (b *Bucket) Count(prefix string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := 0
	for k := range b.objs {
		if strings.HasPrefix(k, prefix) {
			n++
		}
	}
	return n
}

func (b *Bucket) sign(method, name string, exp int64, max int64, resumable bool) string {
	m := hmac.New(sha256.New, b.secret)
	fmt.Fprintf(m, "%s\n%s\n%d\n%d\n%t", method, name, exp, max, resumable)
	return hex.EncodeToString(m.Sum(nil))
}

func (b *Bucket) signedURL(method, name string, ttl time.Duration, max int64, resumable bool) string {
	exp := b.Now().Add(ttl).Unix()
	q := url.Values{"exp": {strconv.FormatInt(exp, 10)}, "max": {strconv.FormatInt(max, 10)}, "sig": {b.sign(method, name, exp, max, resumable)}}
	if resumable {
		q.Set("r", "1")
	}
	return b.Base + "/storage/o/" + name + "?" + q.Encode()
}

// SignPut mirrors gcp.Storage.SignPut: the same required headers, a URL the data plane below verifies.
func (b *Bucket) SignPut(name string, maxSize int64, ttl time.Duration, resumable bool) (string, map[string]string, error) {
	headers := map[string]string{
		"x-goog-content-length-range": "0," + strconv.FormatInt(maxSize, 10),
		"x-goog-if-generation-match":  "0",
	}
	method := "PUT"
	if resumable {
		method = "POST"
		headers["x-goog-resumable"] = "start"
	}
	return b.signedURL(method, name, ttl, maxSize, resumable), headers, nil
}

func (b *Bucket) SignGet(name string, ttl time.Duration) (string, error) {
	return b.signedURL("GET", name, ttl, 0, false), nil
}

// MARK: data plane

// Handler serves /storage/o/{name} (signed URLs) and /storage/session/{id} (resumable session URIs).
func (b *Bucket) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/storage/o/", b.handleObject)
	mux.HandleFunc("/storage/session/", b.handleSession)
	return mux
}

func xmlError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/xml")
	w.WriteHeader(status)
	fmt.Fprintf(w, "<?xml version='1.0' encoding='UTF-8'?><Error><Code>%s</Code></Error>", code)
}

// injected reports whether an ErrorNext fault answers this request.
func (b *Bucket) injected(w http.ResponseWriter) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.faults.ErrorNext.Count > 0 {
		b.faults.ErrorNext.Count--
		b.stats.Errors++
		xmlError(w, b.faults.ErrorNext.Code, "InjectedFault")
		return true
	}
	return false
}

func cut(w http.ResponseWriter) {
	if h, ok := w.(http.Hijacker); ok {
		if c, _, err := h.Hijack(); err == nil {
			_ = c.Close()
			return
		}
	}
	panic(http.ErrAbortHandler)
}

// verify checks the signed URL (method, expiry, signature) and the headers the signature covers.
func (b *Bucket) verify(w http.ResponseWriter, r *http.Request, method, name string) (max int64, resumable bool, ok bool) {
	q := r.URL.Query()
	exp, err1 := strconv.ParseInt(q.Get("exp"), 10, 64)
	max, err2 := strconv.ParseInt(q.Get("max"), 10, 64)
	resumable = q.Get("r") == "1"
	if err1 != nil || err2 != nil || r.Method != method {
		xmlError(w, 403, "SignatureDoesNotMatch")
		return 0, false, false
	}
	want := b.sign(method, name, exp, max, resumable)
	if !hmac.Equal([]byte(want), []byte(q.Get("sig"))) {
		xmlError(w, 403, "SignatureDoesNotMatch")
		return 0, false, false
	}
	if b.Now().Unix() > exp {
		xmlError(w, 403, "ExpiredToken")
		return 0, false, false
	}
	if method != "GET" {
		if r.Header.Get("x-goog-if-generation-match") != "0" || r.Header.Get("x-goog-content-length-range") != "0,"+strconv.FormatInt(max, 10) ||
			(resumable && r.Header.Get("x-goog-resumable") != "start") {
			xmlError(w, 403, "SignatureDoesNotMatch") // a signed header is missing or changed
			return 0, false, false
		}
	}
	return max, resumable, true
}

func (b *Bucket) handleObject(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/storage/o/")
	if b.injected(w) {
		return
	}
	switch r.Method {
	case "PUT":
		b.simplePut(w, r, name)
	case "POST":
		b.startSession(w, r, name)
	case "GET":
		b.get(w, r, name)
	default:
		xmlError(w, 405, "MethodNotAllowed")
	}
}

func (b *Bucket) store(name string, data []byte) bool {
	if _, exists := b.objs[name]; exists {
		return false
	}
	b.gen++
	b.objs[name] = &object{data: data, crc: crc32.Checksum(data, castagnoli), gen: b.gen}
	return true
}

func (b *Bucket) simplePut(w http.ResponseWriter, r *http.Request, name string) {
	max, resumable, ok := b.verify(w, r, "PUT", name)
	if !ok {
		return
	}
	if resumable {
		xmlError(w, 403, "SignatureDoesNotMatch")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, max+1))
	if err != nil {
		return // the client went away mid-body: nothing is stored
	}
	if int64(len(body)) > max {
		xmlError(w, 400, "EntityTooLarge")
		return
	}
	b.mu.Lock()
	b.stats.SimplePuts++
	stored := b.store(name, body)
	b.mu.Unlock()
	if !stored {
		xmlError(w, 412, "PreconditionFailed")
		return
	}
	w.WriteHeader(200)
}

func (b *Bucket) startSession(w http.ResponseWriter, r *http.Request, name string) {
	max, resumable, ok := b.verify(w, r, "POST", name)
	if !ok {
		return
	}
	if !resumable {
		xmlError(w, 403, "SignatureDoesNotMatch")
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.stats.SessionStarts++
	if _, exists := b.objs[name]; exists {
		xmlError(w, 412, "PreconditionFailed")
		return
	}
	raw := make([]byte, 16)
	_, _ = rand.Read(raw)
	id := hex.EncodeToString(raw)
	b.sess[id] = &session{name: name, max: max, total: -1}
	w.Header().Set("Location", b.Base+"/storage/session/"+id)
	w.WriteHeader(201)
}

func (b *Bucket) get(w http.ResponseWriter, r *http.Request, name string) {
	if _, _, ok := b.verify(w, r, "GET", name); !ok {
		return
	}
	b.mu.Lock()
	b.stats.Gets++
	b.gets++
	o, exists := b.objs[name]
	var data []byte
	var crc uint32
	var gen int64
	if exists {
		data, crc, gen = o.data, o.crc, o.gen
	}
	drop := b.faults.DropGets.Count > 0 && b.gets > b.faults.DropGets.After
	if drop {
		b.faults.DropGets.Count--
		b.stats.Dropped++
	}
	ranged := r.Header.Get("Range") != ""
	if ranged {
		b.stats.RangedGets++
	}
	b.mu.Unlock()
	if !exists {
		xmlError(w, 404, "NoSuchKey")
		return
	}
	size := int64(len(data))
	start, end := int64(0), size-1
	status := 200
	if ranged {
		var ok bool
		if start, end, ok = parseRange(r.Header.Get("Range"), size); !ok {
			w.Header().Set("Content-Range", "bytes */"+strconv.FormatInt(size, 10))
			xmlError(w, 416, "InvalidRange")
			return
		}
		status = 206
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
	}
	crcBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(crcBytes, crc)
	w.Header().Set("x-goog-hash", "crc32c="+base64.StdEncoding.EncodeToString(crcBytes))
	w.Header().Set("x-goog-generation", strconv.FormatInt(gen, 10))
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	w.WriteHeader(status)
	body := data[start : end+1]
	if drop {
		_, _ = w.Write(body[:len(body)/2])
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		panic(http.ErrAbortHandler) // truncated body: the client sees a connection error
	}
	_, _ = w.Write(body)
}

// parseRange handles "bytes=a-b", "bytes=a-" and "bytes=-n".
func parseRange(h string, size int64) (start, end int64, ok bool) {
	spec, found := strings.CutPrefix(h, "bytes=")
	if !found || size == 0 {
		return 0, 0, false
	}
	from, to, found := strings.Cut(spec, "-")
	if !found {
		return 0, 0, false
	}
	switch {
	case from == "":
		n, err := strconv.ParseInt(to, 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, false
		}
		if n > size {
			n = size
		}
		return size - n, size - 1, true
	default:
		a, err := strconv.ParseInt(from, 10, 64)
		if err != nil || a >= size || a < 0 {
			return 0, 0, false
		}
		e := size - 1
		if to != "" {
			if e2, err := strconv.ParseInt(to, 10, 64); err != nil || e2 < a {
				return 0, 0, false
			} else if e2 < e {
				e = e2
			}
		}
		return a, e, true
	}
}

// MARK: resumable session

// parseContentRange handles "bytes a-b/total", "bytes a-b/*" and "bytes */total".
func parseContentRange(h string) (a, bEnd, total int64, query bool, ok bool) {
	spec, found := strings.CutPrefix(h, "bytes ")
	if !found {
		return 0, 0, 0, false, false
	}
	rng, tot, found := strings.Cut(spec, "/")
	if !found {
		return 0, 0, 0, false, false
	}
	total = -1
	if tot != "*" {
		t, err := strconv.ParseInt(tot, 10, 64)
		if err != nil || t < 0 {
			return 0, 0, 0, false, false
		}
		total = t
	}
	if rng == "*" {
		return 0, 0, total, true, true
	}
	from, to, found := strings.Cut(rng, "-")
	if !found {
		return 0, 0, 0, false, false
	}
	a, err1 := strconv.ParseInt(from, 10, 64)
	e, err2 := strconv.ParseInt(to, 10, 64)
	if err1 != nil || err2 != nil || a < 0 || e < a {
		return 0, 0, 0, false, false
	}
	return a, e, total, false, true
}

func (b *Bucket) handleSession(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/storage/session/")
	if r.Method != "PUT" {
		xmlError(w, 405, "MethodNotAllowed")
		return
	}
	if b.injected(w) {
		return
	}
	a, e, total, query, ok := parseContentRange(r.Header.Get("Content-Range"))
	if !ok {
		xmlError(w, 400, "InvalidRange")
		return
	}
	var body []byte
	if !query {
		var err error
		if body, err = io.ReadAll(io.LimitReader(r.Body, e-a+2)); err != nil {
			return
		}
		if int64(len(body)) != e-a+1 {
			xmlError(w, 400, "InvalidRange")
			return
		}
	}
	b.mu.Lock()
	s, found := b.sess[id]
	if !found {
		b.mu.Unlock()
		xmlError(w, 404, "NoSuchUpload")
		return
	}
	if query {
		b.stats.StatusQueries++
		b.answer(w, s)
		b.mu.Unlock()
		return
	}
	b.stats.ChunkPuts++
	if s.done {
		b.answer(w, s)
		b.mu.Unlock()
		return
	}
	received := int64(len(s.data))
	last := total >= 0 && e+1 == total
	if !last && int64(len(body))%ChunkMultiple != 0 {
		b.mu.Unlock()
		xmlError(w, 400, "ChunkSizeNotMultipleOf256KiB")
		return
	}
	if total > s.max || e+1 > s.max {
		b.mu.Unlock()
		xmlError(w, 400, "EntityTooLarge")
		return
	}
	drop := b.faults.DropChunks.Count > 0 && b.chunks >= b.faults.DropChunks.After
	out := w
	if drop { // answer into the void, then cut the connection once the books are settled
		out = discard{http.Header{}}
		defer cut(w)
	}
	if !drop {
		b.chunks++
	}
	if a > received { // a gap: tell the client what we really have
		b.answer(out, s)
		b.mu.Unlock()
		return
	}
	persist := !drop || b.faults.DropChunks.Persist
	if drop {
		b.faults.DropChunks.Count--
		b.stats.Dropped++
	}
	if persist && a+int64(len(body)) > received {
		s.data = append(s.data, body[received-a:]...)
	}
	if last && persist {
		s.total = total
		if int64(len(s.data)) == total {
			if !b.store(s.name, s.data) {
				s.done, s.failed = true, true
				b.mu.Unlock()
				xmlError(out, 412, "PreconditionFailed")
				return
			}
			s.done = true
			s.data = nil
			size := total
			b.mu.Unlock()
			out.Header().Set("Content-Type", "application/json")
			out.WriteHeader(200)
			_ = json.NewEncoder(out).Encode(map[string]any{"name": s.name, "size": strconv.FormatInt(size, 10)})
			return
		}
	}
	b.answer(out, s)
	b.mu.Unlock()
}

// discard is a ResponseWriter that drops everything.
type discard struct{ h http.Header }

func (d discard) Header() http.Header         { return d.h }
func (d discard) Write(p []byte) (int, error) { return len(p), nil }
func (d discard) WriteHeader(int)             {}

// answer replies to a status query or a non-final chunk. Callers hold b.mu.
func (b *Bucket) answer(w http.ResponseWriter, s *session) {
	if s.done {
		if s.failed {
			xmlError(w, 412, "PreconditionFailed")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		_ = json.NewEncoder(w).Encode(map[string]any{"name": s.name, "total": s.total})
		return
	}
	if n := len(s.data); n > 0 {
		w.Header().Set("Range", "bytes=0-"+strconv.Itoa(n-1))
	}
	w.WriteHeader(308)
}

// MARK: test inspection (development only)

// Names lists the stored object names under prefix with their sizes, sorted.
func (b *Bucket) Names(prefix string) map[string]int {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := map[string]int{}
	for k, o := range b.objs {
		if strings.HasPrefix(k, prefix) {
			out[k] = len(o.data)
		}
	}
	return out
}

// Raw returns a copy of an object's bytes.
func (b *Bucket) Raw(name string) ([]byte, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	o, ok := b.objs[name]
	if !ok {
		return nil, false
	}
	return append([]byte(nil), o.data...), true
}

// Overwrite replaces an existing object's bytes (a tampering test). It reports whether the object existed.
func (b *Bucket) Overwrite(name string, data []byte) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	o, ok := b.objs[name]
	if !ok {
		return false
	}
	b.gen++
	b.objs[name] = &object{data: append([]byte(nil), data...), crc: crc32.Checksum(data, castagnoli), gen: b.gen}
	_ = o
	return true
}

// Grep returns the names of the objects whose bytes contain marker, and how many objects it looked at.
func (b *Bucket) Grep(marker []byte) (matches []string, scanned int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for k, o := range b.objs {
		scanned++
		if bytesContains(o.data, marker) {
			matches = append(matches, k)
		}
	}
	sort.Strings(matches)
	return matches, scanned
}

func bytesContains(data, sub []byte) bool { return len(sub) > 0 && bytes.Contains(data, sub) }

package devstore

import (
	"bytes"
	"context"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

func newTest(t *testing.T) (*Bucket, *httptest.Server, *time.Time) {
	t.Helper()
	clock := time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)
	b := New("", func() time.Time { return clock })
	srv := httptest.NewServer(b.Handler())
	t.Cleanup(srv.Close)
	b.Base = srv.URL
	return b, srv, &clock
}

func do(t *testing.T, method, url string, headers map[string]string, body []byte) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(method, url, bytes.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { res.Body.Close() })
	return res
}

func payload(n int) []byte {
	p := make([]byte, n)
	for i := range p {
		p[i] = byte(i*7 + i/251)
	}
	return p
}

func TestSimplePutIsCreateOnceAndBounded(t *testing.T) {
	b, _, _ := newTest(t)
	url, h, _ := b.SignPut("w/u/e1/changes/x", 100, time.Minute, false)
	if res := do(t, "PUT", url, h, payload(50)); res.StatusCode != 200 {
		t.Fatalf("first put: %d", res.StatusCode)
	}
	size, crc, err := b.Stat(context.Background(), "w/u/e1/changes/x")
	if err != nil || size != 50 || crc != crc32.Checksum(payload(50), castagnoli) {
		t.Fatalf("stat: %d %x %v", size, crc, err)
	}
	if res := do(t, "PUT", url, h, payload(50)); res.StatusCode != 412 {
		t.Fatalf("second put should be 412, got %d", res.StatusCode)
	}
	url2, h2, _ := b.SignPut("w/u/e1/changes/y", 10, time.Minute, false)
	if res := do(t, "PUT", url2, h2, payload(11)); res.StatusCode != 400 {
		t.Fatalf("oversize: %d", res.StatusCode)
	}
	// A signed header that is missing or altered fails like a bad signature.
	if res := do(t, "PUT", url, map[string]string{"x-goog-if-generation-match": "0"}, payload(5)); res.StatusCode != 403 {
		t.Fatalf("missing header: %d", res.StatusCode)
	}
}

func TestSignatureAndExpiry(t *testing.T) {
	b, _, clock := newTest(t)
	b.objs["n"] = &object{data: []byte("hello"), crc: 1, gen: 1}
	url, _ := b.SignGet("n", time.Minute)
	if res := do(t, "GET", url, nil, nil); res.StatusCode != 200 {
		t.Fatalf("get: %d", res.StatusCode)
	}
	if res := do(t, "GET", strings.Replace(url, "n?", "m?", 1), nil, nil); res.StatusCode != 403 {
		t.Fatalf("other name: %d", res.StatusCode)
	}
	*clock = clock.Add(2 * time.Minute)
	if res := do(t, "GET", url, nil, nil); res.StatusCode != 403 {
		t.Fatalf("expired: %d", res.StatusCode)
	}
}

func TestRangedGet(t *testing.T) {
	b, _, _ := newTest(t)
	data := payload(1000)
	b.objs["n"] = &object{data: data, crc: 1, gen: 9}
	url, _ := b.SignGet("n", time.Minute)
	res := do(t, "GET", url, map[string]string{"Range": "bytes=100-199"}, nil)
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 206 || !bytes.Equal(body, data[100:200]) || res.Header.Get("Content-Range") != "bytes 100-199/1000" || res.Header.Get("x-goog-generation") != "9" {
		t.Fatalf("range: %d %q %q", res.StatusCode, res.Header.Get("Content-Range"), res.Header.Get("x-goog-generation"))
	}
	res = do(t, "GET", url, map[string]string{"Range": "bytes=900-5000"}, nil)
	if body, _ = io.ReadAll(res.Body); res.StatusCode != 206 || !bytes.Equal(body, data[900:]) {
		t.Fatalf("clamped range: %d len %d", res.StatusCode, len(body))
	}
	if res = do(t, "GET", url, map[string]string{"Range": "bytes=1000-1999"}, nil); res.StatusCode != 416 {
		t.Fatalf("past end: %d", res.StatusCode)
	}
}

func start(t *testing.T, b *Bucket, name string, size int64) string {
	t.Helper()
	url, h, _ := b.SignPut(name, size, time.Hour, true)
	res := do(t, "POST", url, h, nil)
	if res.StatusCode != 201 || res.Header.Get("Location") == "" {
		t.Fatalf("start: %d", res.StatusCode)
	}
	return res.Header.Get("Location")
}

func chunk(t *testing.T, session string, data []byte, a, b, total int) *http.Response {
	t.Helper()
	return do(t, "PUT", session, map[string]string{"Content-Range": fmt.Sprintf("bytes %d-%d/%d", a, b, total)}, data[a:b+1])
}

func TestResumableUploadWithStatusQuery(t *testing.T) {
	b, _, _ := newTest(t)
	const total = 3*ChunkMultiple + 1000
	data := payload(total)
	session := start(t, b, "w/audio/a", total)

	if res := chunk(t, session, data, 0, ChunkMultiple-1, total); res.StatusCode != 308 || res.Header.Get("Range") != fmt.Sprintf("bytes=0-%d", ChunkMultiple-1) {
		t.Fatalf("first chunk: %d %q", res.StatusCode, res.Header.Get("Range"))
	}
	// A chunk that is not a multiple of 256 KiB and not the last one is refused.
	if res := chunk(t, session, data, ChunkMultiple, ChunkMultiple+99, total); res.StatusCode != 400 {
		t.Fatalf("odd chunk: %d", res.StatusCode)
	}
	// Status query.
	q := do(t, "PUT", session, map[string]string{"Content-Range": fmt.Sprintf("bytes */%d", total)}, nil)
	if q.StatusCode != 308 || q.Header.Get("Range") != fmt.Sprintf("bytes=0-%d", ChunkMultiple-1) {
		t.Fatalf("status: %d %q", q.StatusCode, q.Header.Get("Range"))
	}
	if res := chunk(t, session, data, ChunkMultiple, 3*ChunkMultiple-1, total); res.StatusCode != 308 {
		t.Fatalf("middle: %d", res.StatusCode)
	}
	if res := chunk(t, session, data, 3*ChunkMultiple, total-1, total); res.StatusCode != 200 {
		t.Fatalf("final: %d", res.StatusCode)
	}
	size, crc, err := b.Stat(context.Background(), "w/audio/a")
	if err != nil || size != total || crc != crc32.Checksum(data, castagnoli) {
		t.Fatalf("stat: %d %v", size, err)
	}
	// After completion a status query still says 200 (the reply to the last chunk may have been lost).
	q = do(t, "PUT", session, map[string]string{"Content-Range": fmt.Sprintf("bytes */%d", total)}, nil)
	if q.StatusCode != 200 {
		t.Fatalf("status after done: %d", q.StatusCode)
	}
	if st := b.Stats(); st.SessionStarts != 1 || st.StatusQueries != 2 {
		t.Fatalf("stats: %+v", st)
	}
}

func TestResumableStartOnExistingObjectIs412(t *testing.T) {
	b, _, _ := newTest(t)
	b.objs["w/audio/a"] = &object{data: []byte{1}}
	url, h, _ := b.SignPut("w/audio/a", 10<<20, time.Hour, true)
	if res := do(t, "POST", url, h, nil); res.StatusCode != 412 {
		t.Fatalf("start on existing: %d", res.StatusCode)
	}
}

func TestDroppedChunkLeavesResumableState(t *testing.T) {
	b, srv, _ := newTest(t)
	const total = 2*ChunkMultiple + 5
	data := payload(total)
	session := start(t, b, "w/audio/b", total)
	b.SetFaults(func() Faults {
		var f Faults
		f.DropChunks.After, f.DropChunks.Count, f.DropChunks.Persist = 1, 1, true
		return f
	}())
	if res := chunk(t, session, data, 0, ChunkMultiple-1, total); res.StatusCode != 308 {
		t.Fatalf("first: %d", res.StatusCode)
	}
	req, _ := http.NewRequest("PUT", session, bytes.NewReader(data[ChunkMultiple:2*ChunkMultiple]))
	req.Header.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", ChunkMultiple, 2*ChunkMultiple-1, total))
	if _, err := srv.Client().Do(req); err == nil {
		t.Fatal("the cut chunk should surface as a transport error")
	}
	// The bytes were persisted although the reply was lost: the status query says so.
	q := do(t, "PUT", session, map[string]string{"Content-Range": fmt.Sprintf("bytes */%d", total)}, nil)
	if q.Header.Get("Range") != fmt.Sprintf("bytes=0-%d", 2*ChunkMultiple-1) {
		t.Fatalf("status after drop: %d %q", q.StatusCode, q.Header.Get("Range"))
	}
	if res := chunk(t, session, data, 2*ChunkMultiple, total-1, total); res.StatusCode != 200 {
		t.Fatalf("final: %d", res.StatusCode)
	}
	if b.Stats().Dropped != 1 {
		t.Fatalf("stats: %+v", b.Stats())
	}
}

func TestErrorNextAndBlobsContract(t *testing.T) {
	b, _, _ := newTest(t)
	var f Faults
	f.ErrorNext.Code, f.ErrorNext.Count = 503, 1
	b.SetFaults(f)
	url, h, _ := b.SignPut("w/x", 10, time.Minute, false)
	if res := do(t, "PUT", url, h, []byte("a")); res.StatusCode != 503 {
		t.Fatalf("fault: %d", res.StatusCode)
	}
	if res := do(t, "PUT", url, h, []byte("a")); res.StatusCode != 200 {
		t.Fatalf("after fault: %d", res.StatusCode)
	}
	if _, _, err := b.Stat(context.Background(), "nope"); err != syncplane.ErrNotFound {
		t.Fatalf("stat missing: %v", err)
	}
	names, more, _ := b.List(context.Background(), "w/", "", 10)
	if len(names) != 1 || more || b.Count("w/") != 1 {
		t.Fatalf("list: %v", names)
	}
	_ = b.Delete(context.Background(), "w/x")
	if b.Count("w/") != 0 {
		t.Fatal("delete")
	}
}

func TestDroppedFinalChunkStillCompletesWhenPersisted(t *testing.T) {
	b, srv, _ := newTest(t)
	const total = ChunkMultiple + 10
	data := payload(total)
	session := start(t, b, "w/audio/c", total)
	var f Faults
	f.DropChunks.Count, f.DropChunks.Persist = 1, true
	b.SetFaults(f)
	req, _ := http.NewRequest("PUT", session, bytes.NewReader(data))
	req.Header.Set("Content-Range", fmt.Sprintf("bytes 0-%d/%d", total-1, total))
	if _, err := srv.Client().Do(req); err == nil {
		t.Fatal("expected a cut connection")
	}
	// The whole object arrived before the cut, so the session finalised: a status query reports completion.
	q := do(t, "PUT", session, map[string]string{"Content-Range": fmt.Sprintf("bytes */%d", total)}, nil)
	if q.StatusCode != 200 {
		t.Fatalf("status: %d", q.StatusCode)
	}
	if size, _, err := b.Stat(context.Background(), "w/audio/c"); err != nil || size != total {
		t.Fatalf("stat: %d %v", size, err)
	}
}

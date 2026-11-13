package gcp_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// fakeFirestore implements just enough of the Firestore REST API to test the client: documents,
// transactions with optimistic conflict detection, commits and simple queries.
type fakeFirestore struct {
	t       *testing.T
	mu      sync.Mutex
	docs    map[string]map[string]any // full name -> fields
	version map[string]int
	txs     map[string]map[string]int // tx id -> doc -> version read
	next    int
	// failCommits makes the next n transactional commits answer 409 (contention).
	failCommits int
	requests    int
}

func newFake(t *testing.T) (*fakeFirestore, *httptest.Server) {
	f := &fakeFirestore{t: t, docs: map[string]map[string]any{}, version: map[string]int{}, txs: map[string]map[string]int{}}
	srv := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(srv.Close)
	return f, srv
}

func (f *fakeFirestore) reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (f *fakeFirestore) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests++
	if r.Header.Get("Authorization") != "Bearer test-token" {
		f.reply(w, 401, map[string]any{"error": "unauthenticated"})
		return
	}
	const marker = "/documents"
	path := r.URL.Path[strings.Index(r.URL.Path, marker)+len(marker):]
	var body map[string]any
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	switch {
	case strings.HasSuffix(path, ":beginTransaction"):
		f.next++
		id := "tx" + strconv.Itoa(f.next)
		f.txs[id] = map[string]int{}
		f.reply(w, 200, map[string]any{"transaction": id})
	case strings.HasSuffix(path, ":rollback"):
		delete(f.txs, body["transaction"].(string))
		f.reply(w, 200, map[string]any{})
	case strings.HasSuffix(path, ":commit"):
		f.commit(w, body)
	case strings.HasSuffix(path, ":runQuery"):
		f.query(w, path, body)
	case r.Method == "GET":
		name := "projects/p/databases/(default)/documents" + path
		if tx := r.URL.Query().Get("transaction"); tx != "" {
			f.txs[tx][name] = f.version[name] // a read of an absent document is a read too
		}
		doc, ok := f.docs[name]
		if !ok {
			f.reply(w, 404, map[string]any{"error": "not found"})
			return
		}
		f.reply(w, 200, map[string]any{"name": name, "fields": doc})
	default:
		f.reply(w, 400, map[string]any{"error": "unsupported " + r.Method + " " + path})
	}
}

func (f *fakeFirestore) commit(w http.ResponseWriter, body map[string]any) {
	tx, _ := body["transaction"].(string)
	writes, _ := body["writes"].([]any)
	if tx != "" {
		if f.failCommits > 0 {
			f.failCommits--
			f.reply(w, 409, map[string]any{"error": "aborted"})
			return
		}
		for _, wr := range writes {
			upd := wr.(map[string]any)["update"].(map[string]any)
			name := upd["name"].(string)
			if seen, ok := f.txs[tx][name]; ok && seen != f.version[name] {
				f.reply(w, 409, map[string]any{"error": "aborted: document changed"})
				return
			}
		}
	}
	for _, wr := range writes { // preconditions first: the commit is all-or-nothing
		m := wr.(map[string]any)
		if cd, ok := m["currentDocument"].(map[string]any); ok && cd["exists"] == false {
			if _, present := f.docs[m["update"].(map[string]any)["name"].(string)]; present {
				f.reply(w, 409, map[string]any{"error": map[string]any{"status": "ALREADY_EXISTS"}})
				return
			}
		}
	}
	for _, wr := range writes {
		m := wr.(map[string]any)
		if upd, ok := m["update"].(map[string]any); ok {
			name := upd["name"].(string)
			fields, _ := upd["fields"].(map[string]any)
			f.docs[name] = fields
			f.version[name]++
		} else if del, ok := m["delete"].(string); ok {
			delete(f.docs, del)
			f.version[del]++
		}
	}
	delete(f.txs, tx)
	f.reply(w, 200, map[string]any{})
}

func strField(doc map[string]any, field string) (string, bool) {
	v, ok := doc[field].(map[string]any)
	if !ok {
		return "", false
	}
	s, ok := v["stringValue"].(string)
	return s, ok
}

func (f *fakeFirestore) query(w http.ResponseWriter, parentPath string, body map[string]any) {
	q := body["structuredQuery"].(map[string]any)
	coll := q["from"].([]any)[0].(map[string]any)["collectionId"].(string)
	parent := "projects/p/databases/(default)/documents" + strings.TrimSuffix(parentPath, ":runQuery")
	var filters []map[string]any
	if wh, ok := q["where"].(map[string]any); ok {
		if ff, ok := wh["fieldFilter"].(map[string]any); ok {
			filters = append(filters, ff)
		}
	}
	type row struct {
		name   string
		fields map[string]any
	}
	var rows []row
	for name, doc := range f.docs {
		if !strings.HasPrefix(name, parent+"/"+coll+"/") {
			continue
		}
		ok := true
		for _, ff := range filters {
			field := ff["field"].(map[string]any)["fieldPath"].(string)
			want, _ := ff["value"].(map[string]any)["stringValue"].(string)
			got, present := strField(doc, field)
			switch ff["op"] {
			case "EQUAL":
				ok = ok && present && got == want
			case "LESS_THAN_OR_EQUAL":
				ok = ok && present && got <= want
			}
		}
		if ok {
			rows = append(rows, row{name, doc})
		}
	}
	if ob, ok := q["orderBy"].([]any); ok {
		field := ob[0].(map[string]any)["field"].(map[string]any)["fieldPath"].(string)
		sort.Slice(rows, func(i, j int) bool {
			a, _ := strField(rows[i].fields, field)
			b, _ := strField(rows[j].fields, field)
			return a < b
		})
	}
	limit := int(q["limit"].(float64))
	out := []any{}
	for i, r := range rows {
		if i >= limit {
			break
		}
		out = append(out, map[string]any{"document": map[string]any{"name": r.name, "fields": r.fields}})
	}
	if len(out) == 0 {
		out = append(out, map[string]any{"readTime": "now"})
	}
	f.reply(w, 200, out)
}

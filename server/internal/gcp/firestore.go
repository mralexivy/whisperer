package gcp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"net/http"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"time"
)

// Firestore is a small REST client: exactly the calls the control plane needs (get, set, transactional
// read-modify-write, one kind of query). Documents are Go structs; they travel as JSON, converted to
// Firestore's typed value encoding, so the same structs serve the API and the database. Times are RFC 3339
// strings (UTC), which sort correctly, and a zero time is simply not stored.
type Firestore struct {
	Project string
	// Root is the document every collection hangs under: "envs/prod" or "envs/sandbox" (separate roots, D14).
	Root   string
	Tokens TokenSource
	Client *http.Client
	// Base is a test hook; defaults to the real endpoint.
	Base string
}

var ErrNotFound = errors.New("gcp: document not found")

func (f *Firestore) client() *http.Client {
	if f.Client != nil {
		return f.Client
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (f *Firestore) docsURL() string {
	base := f.Base
	if base == "" {
		base = "https://firestore.googleapis.com"
	}
	return fmt.Sprintf("%s/v1/projects/%s/databases/(default)/documents", base, f.Project)
}

func (f *Firestore) docName(path string) string {
	return fmt.Sprintf("projects/%s/databases/(default)/documents/%s/%s", f.Project, f.Root, path)
}

func (f *Firestore) docURL(path string) string { return f.docsURL() + "/" + f.Root + "/" + path }

// MARK: value encoding

type fsValue map[string]any

// encode turns decoded JSON (numbers as json.Number) into Firestore fields.
func encodeFields(m map[string]any) map[string]fsValue {
	out := make(map[string]fsValue, len(m))
	for k, v := range m {
		if isZeroTime(v) {
			continue
		}
		out[k] = encodeValue(v)
	}
	return out
}

func isZeroTime(v any) bool { s, ok := v.(string); return ok && s == "0001-01-01T00:00:00Z" }

func encodeValue(v any) fsValue {
	switch x := v.(type) {
	case nil:
		return fsValue{"nullValue": nil}
	case bool:
		return fsValue{"booleanValue": x}
	case string:
		return fsValue{"stringValue": x}
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return fsValue{"integerValue": strconv.FormatInt(i, 10)}
		}
		f, _ := x.Float64()
		return fsValue{"doubleValue": f}
	case []any:
		vals := make([]fsValue, 0, len(x))
		for _, e := range x {
			vals = append(vals, encodeValue(e))
		}
		if len(vals) == 0 {
			return fsValue{"arrayValue": map[string]any{}}
		}
		return fsValue{"arrayValue": map[string]any{"values": vals}}
	case map[string]any:
		return fsValue{"mapValue": map[string]any{"fields": encodeFields(x)}}
	}
	return fsValue{"stringValue": fmt.Sprint(v)}
}

func decodeFields(fields map[string]map[string]any) map[string]any {
	out := make(map[string]any, len(fields))
	for k, v := range fields {
		out[k] = decodeValue(v)
	}
	return out
}

func decodeValue(v map[string]any) any {
	for kind, raw := range v {
		switch kind {
		case "nullValue":
			return nil
		case "booleanValue", "stringValue", "timestampValue":
			return raw
		case "integerValue":
			return json.Number(raw.(string))
		case "doubleValue":
			return raw
		case "arrayValue":
			m, _ := raw.(map[string]any)
			vals, _ := m["values"].([]any)
			out := make([]any, 0, len(vals))
			for _, e := range vals {
				em, _ := e.(map[string]any)
				out = append(out, decodeValue(em))
			}
			return out
		case "mapValue":
			m, _ := raw.(map[string]any)
			fm, _ := m["fields"].(map[string]any)
			out := make(map[string]any, len(fm))
			for k, e := range fm {
				em, _ := e.(map[string]any)
				out[k] = decodeValue(em)
			}
			return out
		}
	}
	return nil
}

type rawDoc struct {
	Name   string                    `json:"name"`
	Fields map[string]map[string]any `json:"fields"`
}

func toFields(doc any) (map[string]fsValue, error) {
	b, err := json.Marshal(doc)
	if err != nil {
		return nil, err
	}
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	if err := dec.Decode(&m); err != nil {
		return nil, err
	}
	return encodeFields(m), nil
}

func fromFields(fields map[string]map[string]any, into any) error {
	b, err := json.Marshal(decodeFields(fields))
	if err != nil {
		return err
	}
	return json.Unmarshal(b, into)
}

// MARK: operations

// Get reads one document into `into`. ErrNotFound when it does not exist.
func (f *Firestore) Get(ctx context.Context, path string, into any) error {
	var d rawDoc
	status, err := do(ctx, f.client(), f.Tokens, "GET", f.docURL(path), nil, &d)
	if status == 404 {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	return fromFields(d.Fields, into)
}

// Set replaces a document.
func (f *Firestore) Set(ctx context.Context, path string, doc any) error {
	fields, err := toFields(doc)
	if err != nil {
		return err
	}
	body := map[string]any{"writes": []any{map[string]any{"update": map[string]any{"name": f.docName(path), "fields": fields}}}}
	_, err = do(ctx, f.client(), f.Tokens, "POST", f.docsURL()+":commit", body, nil)
	return err
}

// Delete removes a document (a missing one is not an error).
func (f *Firestore) Delete(ctx context.Context, path string) error {
	body := map[string]any{"writes": []any{map[string]any{"delete": f.docName(path)}}}
	_, err := do(ctx, f.client(), f.Tokens, "POST", f.docsURL()+":commit", body, nil)
	return err
}

// Transact runs a read-modify-write on one document inside a Firestore transaction, retrying on contention.
// `fn` receives the current value (zero when absent) and may change it; returning an error aborts without
// writing. fn must be free of side effects: it can run more than once.
func (f *Firestore) Transact(ctx context.Context, path string, into any, fn func() error) error {
	var lastErr error
	for attempt := 0; attempt < 6; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(20+rand.IntN(60)<<attempt) * time.Millisecond):
			}
		}
		err := f.transactOnce(ctx, path, into, fn)
		var api *APIError
		if errors.As(err, &api) && (api.Status == 409 || api.Status == 429 || api.Status == 503) {
			lastErr = err
			continue
		}
		return err
	}
	return lastErr
}

func (f *Firestore) transactOnce(ctx context.Context, path string, into any, fn func() error) error {
	reflect.ValueOf(into).Elem().SetZero() // every attempt starts from the stored document, never from the last attempt's edits
	var begin struct {
		Transaction string `json:"transaction"`
	}
	if _, err := do(ctx, f.client(), f.Tokens, "POST", f.docsURL()+":beginTransaction", map[string]any{"options": map[string]any{"readWrite": map[string]any{}}}, &begin); err != nil {
		return err
	}
	rollback := func() {
		_, _ = do(ctx, f.client(), f.Tokens, "POST", f.docsURL()+":rollback", map[string]any{"transaction": begin.Transaction}, nil)
	}
	var d rawDoc
	status, err := do(ctx, f.client(), f.Tokens, "GET", f.docURL(path)+"?transaction="+url.QueryEscape(begin.Transaction), nil, &d)
	switch {
	case status == 404:
		// absent: fn starts from the zero value already in `into`
	case err != nil:
		rollback()
		return err
	default:
		if err := fromFields(d.Fields, into); err != nil {
			rollback()
			return err
		}
	}
	if err := fn(); err != nil {
		rollback()
		return err
	}
	fields, err := toFields(into)
	if err != nil {
		rollback()
		return err
	}
	body := map[string]any{
		"transaction": begin.Transaction,
		"writes":      []any{map[string]any{"update": map[string]any{"name": f.docName(path), "fields": fields}}},
	}
	_, err = do(ctx, f.client(), f.Tokens, "POST", f.docsURL()+":commit", body, nil)
	return err
}

// Filter is one field comparison of a Query.
type Filter struct {
	Field string
	Op    string // EQUAL, LESS_THAN_OR_EQUAL, ...
	Value any    // string, bool or an integer
}

// Query lists up to `limit` documents of a collection under the root, filtered and ordered by `orderBy`
// ascending. `decode` is called with each document's JSON-compatible fields.
func (f *Firestore) Query(ctx context.Context, collection string, filters []Filter, orderBy string, limit int, each func(fields map[string]any) error) error {
	var where []any
	for _, fl := range filters {
		where = append(where, map[string]any{"fieldFilter": map[string]any{
			"field": map[string]any{"fieldPath": fl.Field}, "op": fl.Op, "value": encodeValue(jsonScalar(fl.Value))}})
	}
	q := map[string]any{"from": []any{map[string]any{"collectionId": collection}}, "limit": limit}
	switch len(where) {
	case 0:
	case 1:
		q["where"] = where[0]
	default:
		q["where"] = map[string]any{"compositeFilter": map[string]any{"op": "AND", "filters": where}}
	}
	if orderBy != "" {
		q["orderBy"] = []any{map[string]any{"field": map[string]any{"fieldPath": orderBy}, "direction": "ASCENDING"}}
	}
	var rows []struct {
		Document *rawDoc `json:"document"`
	}
	parent := f.docsURL() + "/" + strings.TrimSuffix(f.Root, "/") + ":runQuery"
	if _, err := do(ctx, f.client(), f.Tokens, "POST", parent, map[string]any{"structuredQuery": q}, &rows); err != nil {
		return err
	}
	for _, r := range rows {
		if r.Document == nil {
			continue
		}
		if err := each(decodeFields(r.Document.Fields)); err != nil {
			return err
		}
	}
	return nil
}

func jsonScalar(v any) any {
	switch x := v.(type) {
	case int:
		return json.Number(strconv.Itoa(x))
	case int64:
		return json.Number(strconv.FormatInt(x, 10))
	}
	return v
}

// FromMap converts query output into a struct.
func FromMap(m map[string]any, into any) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, into)
}

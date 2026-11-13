package gcp

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// EntitlementStore keeps subscribers in Firestore (`entitlements/{uid}`). It implements entitlement.Store.
//
// Each document carries one extra, indexed field, `sweepAt`: the earliest moment the irreversible delete may
// run. It exists only while the data has not been deleted, so the retention query is a single ordered range
// over a field that never contains finished accounts.
type EntitlementStore struct{ FS *Firestore }

const sweepFormat = "2006-01-02T15:04:05.000Z"

func entPath(uid string) string { return "entitlements/" + uid }

func (s EntitlementStore) Get(ctx context.Context, uid string) (entitlement.Entitlement, bool, error) {
	var e entitlement.Entitlement
	err := s.FS.Get(ctx, entPath(uid), &e)
	if errors.Is(err, ErrNotFound) {
		return e, false, nil
	}
	return e, err == nil, err
}

func (s EntitlementStore) Put(ctx context.Context, e entitlement.Entitlement) error {
	b, err := json.Marshal(e)
	if err != nil {
		return err
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	if e.DataDeletedAt.IsZero() && !e.ExpiresAt.IsZero() {
		m["sweepAt"] = e.HardDeleteAt().UTC().Format(sweepFormat)
	}
	return s.FS.Set(ctx, entPath(e.UID), m)
}

func (s EntitlementStore) ByOriginalTransactionID(ctx context.Context, id string) (entitlement.Entitlement, bool, error) {
	var found entitlement.Entitlement
	ok := false
	err := s.FS.Query(ctx, "entitlements", []Filter{{"originalTransactionId", "EQUAL", id}}, "", 1, func(m map[string]any) error {
		ok = true
		return FromMap(m, &found)
	})
	return found, ok, err
}

func (s EntitlementStore) Due(ctx context.Context, now time.Time, limit int) ([]entitlement.Entitlement, error) {
	var due []entitlement.Entitlement
	err := s.FS.Query(ctx, "entitlements", []Filter{{"sweepAt", "LESS_THAN_OR_EQUAL", now.UTC().Format(sweepFormat)}}, "sweepAt", limit, func(m map[string]any) error {
		var e entitlement.Entitlement
		if err := FromMap(m, &e); err != nil {
			return err
		}
		if e.Due(now) { // the clock-based answer is authoritative, not the index
			due = append(due, e)
		}
		return nil
	})
	return due, err
}

// SyncStore keeps the sync heads and quota ledger in Firestore. It implements syncplane.Store.
type SyncStore struct{ FS *Firestore }

func headsPath(a string) string { return "sync_heads/" + a }
func usagePath(a string) string { return "sync_usage/" + a }

func normalise(h *syncplane.Heads) {
	if h.Epoch == 0 {
		h.Epoch = 1
	}
	if h.Heads == nil {
		h.Heads = map[string]syncplane.Head{}
	}
}

func (s SyncStore) GetHeads(ctx context.Context, a string) (syncplane.Heads, error) {
	var h syncplane.Heads
	if err := s.FS.Get(ctx, headsPath(a), &h); err != nil && !errors.Is(err, ErrNotFound) {
		return h, err
	}
	normalise(&h)
	return h, nil
}

func (s SyncStore) UpdateHeads(ctx context.Context, a string, fn func(*syncplane.Heads) error) error {
	var h syncplane.Heads
	return s.FS.Transact(ctx, headsPath(a), &h, func() error {
		normalise(&h)
		return fn(&h)
	})
}

func (s SyncStore) GetUsage(ctx context.Context, a string) (syncplane.Usage, error) {
	var u syncplane.Usage
	if err := s.FS.Get(ctx, usagePath(a), &u); err != nil && !errors.Is(err, ErrNotFound) {
		return u, err
	}
	return u, nil
}

func (s SyncStore) UpdateUsage(ctx context.Context, a string, fn func(*syncplane.Usage) error) error {
	var u syncplane.Usage
	return s.FS.Transact(ctx, usagePath(a), &u, func() error { return fn(&u) })
}

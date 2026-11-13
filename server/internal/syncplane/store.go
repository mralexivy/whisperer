package syncplane

import (
	"context"
	"errors"
	"sync"
	"time"
)

var (
	ErrNotFound = errors.New("syncplane: not found")
	ErrExists   = errors.New("syncplane: already exists")
)

// Pending is an upload that has been granted but not committed.
type Pending struct {
	Name string    `json:"name"`
	Size int64     `json:"size"`
	Exp  time.Time `json:"exp"`
}

// Usage is the per-account ledger. It is only ever changed through Store.UpdateUsage, which is a transaction.
type Usage struct {
	Committed     int64     `json:"committed"`
	Reserved      int64     `json:"reserved"`
	Pending       []Pending `json:"pending"`
	Month         string    `json:"month"` // "2026-11": the download/grant counters belong to this month
	DownloadBytes int64     `json:"downloadBytes"`
	UploadGrants  int       `json:"uploadGrants"`
}

type Head struct {
	Seq int64  `json:"seq"`
	CRC uint32 `json:"crc"`
}

type Snapshot struct {
	ID      string           `json:"id"`
	Covers  map[string]int64 `json:"covers"`
	Version int64            `json:"version"`
}

// Heads is the one small document a poll reads: what each device has committed, and the latest snapshot.
type Heads struct {
	Epoch    int             `json:"epoch"`
	Version  int64           `json:"version"`
	Heads    map[string]Head `json:"heads"`
	Snapshot *Snapshot       `json:"snapshot,omitempty"`
}

// Store is the control-plane database (Firestore in production). Update* run fn inside a transaction: on a
// conflict the implementation retries fn, so fn must be free of side effects.
type Store interface {
	GetHeads(ctx context.Context, account string) (Heads, error)
	UpdateHeads(ctx context.Context, account string, fn func(*Heads) error) error
	GetUsage(ctx context.Context, account string) (Usage, error)
	UpdateUsage(ctx context.Context, account string, fn func(*Usage) error) error
}

// MemoryStore is an in-process Store with the same transactional behaviour.
type MemoryStore struct {
	mu    sync.Mutex
	heads map[string]Heads
	usage map[string]Usage
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{heads: map[string]Heads{}, usage: map[string]Usage{}}
}

func cloneHeads(h Heads) Heads {
	out := h
	out.Heads = make(map[string]Head, len(h.Heads))
	for k, v := range h.Heads {
		out.Heads[k] = v
	}
	if h.Snapshot != nil {
		s := *h.Snapshot
		s.Covers = make(map[string]int64, len(h.Snapshot.Covers))
		for k, v := range h.Snapshot.Covers {
			s.Covers[k] = v
		}
		out.Snapshot = &s
	}
	return out
}

func (m *MemoryStore) GetHeads(_ context.Context, a string) (Heads, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.heads[a]
	if !ok {
		return Heads{Epoch: 1, Heads: map[string]Head{}}, nil
	}
	return cloneHeads(h), nil
}

func (m *MemoryStore) UpdateHeads(_ context.Context, a string, fn func(*Heads) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.heads[a]
	if !ok {
		h = Heads{Epoch: 1, Heads: map[string]Head{}}
	}
	h = cloneHeads(h)
	if err := fn(&h); err != nil {
		return err
	}
	m.heads[a] = h
	return nil
}

func (m *MemoryStore) GetUsage(_ context.Context, a string) (Usage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u := m.usage[a]
	u.Pending = append([]Pending(nil), u.Pending...)
	return u, nil
}

func (m *MemoryStore) UpdateUsage(_ context.Context, a string, fn func(*Usage) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u := m.usage[a]
	u.Pending = append([]Pending(nil), u.Pending...)
	if err := fn(&u); err != nil {
		return err
	}
	m.usage[a] = u
	return nil
}

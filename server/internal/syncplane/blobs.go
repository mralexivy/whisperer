package syncplane

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"
)

// Blobs is Cloud Storage as the control plane needs it. Signing is local (IAM signBlob in production).
type Blobs interface {
	// Stat returns the stored size and crc32c, or ErrNotFound.
	Stat(ctx context.Context, name string) (size int64, crc uint32, err error)
	Delete(ctx context.Context, name string) error // a missing object is not an error
	// List returns up to n names under prefix after `after`, and whether more remain.
	List(ctx context.Context, prefix, after string, n int) (names []string, more bool, err error)
	// SignPut: a URL that creates `name` only if it does not exist (ifGenerationMatch=0) and no larger than maxSize.
	SignPut(name string, maxSize int64, ttl time.Duration) (string, error)
	SignGet(name string, ttl time.Duration) (string, error)
}

// MemoryBlobs is an in-process bucket for tests. Put simulates a Mac uploading through a signed URL.
type MemoryBlobs struct {
	mu   sync.Mutex
	objs map[string]blob
}

type blob struct {
	size int64
	crc  uint32
}

func NewMemoryBlobs() *MemoryBlobs { return &MemoryBlobs{objs: map[string]blob{}} }

// Put creates an object once, like ifGenerationMatch=0; false means it already existed.
func (m *MemoryBlobs) Put(name string, size int64, crc uint32) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.objs[name]; ok {
		return false
	}
	m.objs[name] = blob{size, crc}
	return true
}

func (m *MemoryBlobs) Count(prefix string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for k := range m.objs {
		if strings.HasPrefix(k, prefix) {
			n++
		}
	}
	return n
}

func (m *MemoryBlobs) Stat(_ context.Context, name string) (int64, uint32, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.objs[name]
	if !ok {
		return 0, 0, ErrNotFound
	}
	return b.size, b.crc, nil
}

func (m *MemoryBlobs) Delete(_ context.Context, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.objs, name)
	return nil
}

func (m *MemoryBlobs) List(_ context.Context, prefix, after string, n int) ([]string, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var all []string
	for k := range m.objs {
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

func (m *MemoryBlobs) SignPut(name string, maxSize int64, ttl time.Duration) (string, error) {
	return "https://storage.invalid/put/" + name, nil
}

func (m *MemoryBlobs) SignGet(name string, ttl time.Duration) (string, error) {
	return "https://storage.invalid/get/" + name, nil
}

// Package account is who a Whisperer Cloud customer is: an opaque account id minted by the server, the
// Apple subscription(s) bound to it, the devices (Macs) allowed to reach its data, and the library key
// verifier. Nothing here is derived from Apple data: the raw transaction id never becomes an id, it only
// appears inside an HMAC (subKey) used as a mapping document name.
package account

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// PendingTTL is how long an enrolment that has not proven the library key stays alive.
const PendingTTL = 7 * 24 * time.Hour

var (
	ErrNotFound    = errors.New("account: not found")
	ErrBound       = errors.New("account: subscription or purchase token already bound")
	ErrDeviceBound = errors.New("account: device key already belongs to an account")
	// ErrLibraryExists is returned by UpdateAccount callbacks that find a library already created.
	ErrLibraryExists = errors.New("account: library already exists")
)

type DeviceState string

const (
	DevicePending    DeviceState = "pending"    // proved an entitlement, not the key: no data access
	DeviceAuthorized DeviceState = "authorized" // proved the library key (or created the library)
	DeviceRevoked    DeviceState = "revoked"    // permanently refused; the key can never enrol again
)

// DeviceCap is how many authorized Macs a plan allows (also a cost bound).
func DeviceCap(plan string) int {
	switch plan {
	case "starter":
		return 2
	case "standard":
		return 4
	case "large", "max":
		return 8
	}
	return 2
}

// MaxPending bounds enrolment spam: pending devices alive at once per account.
const MaxPending = 8

type Recovery struct {
	Wrapped   string    `json:"wrapped"`
	Kdf       string    `json:"kdf"`
	CreatedAt time.Time `json:"createdAt"`
}

// Library is the server's whole knowledge of the encryption key: a verifier, never the key.
type Library struct {
	Exists     bool      `json:"exists"`
	KeyVersion int       `json:"keyVersion,omitempty"`
	Verifier   string    `json:"verifier,omitempty"` // hex SHA-256(authKey)
	Recovery   *Recovery `json:"recovery,omitempty"`
}

// PendingEpoch is an old library epoch whose objects must be deleted (reset / rotation).
type PendingEpoch struct {
	Epoch    int       `json:"epoch"`
	QueuedAt time.Time `json:"queuedAt"`
}

type Account struct {
	ID              string    `json:"id"`
	CreatedAt       time.Time `json:"createdAt"`
	AppAccountToken string    `json:"appAccountToken,omitempty"`
	Epoch           int       `json:"epoch"`
	Library         Library   `json:"library"`
	// EpochsToDelete are old epochs awaiting deletion by the retention machinery; EpochQueue is "pending"
	// while the list is non-empty — the one indexed field the sweep queries.
	EpochsToDelete []PendingEpoch `json:"epochsToDelete,omitempty"`
	EpochQueue     string         `json:"epochQueue,omitempty"`
}

// Normalize keeps derived fields consistent; stores call it on every write.
func (a *Account) Normalize() {
	if a.Epoch == 0 {
		a.Epoch = 1
	}
	a.EpochQueue = ""
	if len(a.EpochsToDelete) > 0 {
		a.EpochQueue = "pending"
	}
}

type Device struct {
	ID              string      `json:"id"`
	AccountID       string      `json:"accountId"`
	PubKey          string      `json:"pubKey"` // base64 X9.63, as sent
	State           DeviceState `json:"state"`
	LabelEnc        string      `json:"labelEnc,omitempty"`
	AppVersion      string      `json:"appVersion,omitempty"`
	EnrolledAt      time.Time   `json:"enrolledAt"`
	LastSeenAt      time.Time   `json:"lastSeenAt,omitempty"`
	RevokedAt       time.Time   `json:"revokedAt,omitempty"`
	EnrollChallenge string      `json:"enrollChallenge,omitempty"` // hex, single use, pending devices only
	// PurgeAt is the Firestore TTL field: set only while pending, so authorized devices are never purged.
	PurgeAt time.Time `json:"purgeAt,omitempty"`
}

// Expired reports a pending enrolment past its 7 days (Firestore's TTL deletes it eventually; this is exact).
func (d Device) Expired(now time.Time) bool {
	return d.State == DevicePending && !d.PurgeAt.IsZero() && !now.Before(d.PurgeAt)
}

// Creation is everything a first purchase writes, atomically.
type Creation struct {
	Account Account
	SubKey  string
	Device  Device
}

// Store keeps accounts, mappings and devices. Firestore in production, Memory in tests.
type Store interface {
	// Create writes the account, the subscription mapping, the purchase-token mapping (when the account has
	// one) and the first device in one atomic step. ErrBound when the subscription or token is already
	// mapped; ErrDeviceBound when the device key already belongs to an account. Nothing is written then.
	Create(ctx context.Context, c Creation) error
	ResolveSub(ctx context.Context, subKey string) (accountID string, found bool, err error)
	ResolveToken(ctx context.Context, appAccountToken string) (accountID string, found bool, err error)
	// BindSub maps another subscription (resubscribe, upgrade chain) to an existing account; idempotent for
	// the same account, ErrBound for another.
	BindSub(ctx context.Context, accountID, subKey string) error

	GetAccount(ctx context.Context, id string) (Account, bool, error)
	// UpdateAccount is a transaction: fn may run more than once and must be free of side effects.
	UpdateAccount(ctx context.Context, id string, fn func(*Account) error) error
	// PendingEpochs lists up to limit accounts with old epochs awaiting deletion.
	PendingEpochs(ctx context.Context, limit int) ([]Account, error)

	GetDevice(ctx context.Context, deviceID string) (Device, bool, error)
	ListDevices(ctx context.Context, accountID string) ([]Device, error)
	// PutDevice creates the device or replaces it when it already belongs to d.AccountID; ErrDeviceBound otherwise.
	PutDevice(ctx context.Context, d Device) error
	UpdateDevice(ctx context.Context, deviceID string, fn func(*Device) error) error
}

// Memory is an in-process Store with the same atomicity.
type Memory struct {
	mu      sync.Mutex
	acct    map[string]Account
	subs    map[string]string
	tokens  map[string]string
	devices map[string]Device
}

func NewMemory() *Memory {
	return &Memory{acct: map[string]Account{}, subs: map[string]string{}, tokens: map[string]string{}, devices: map[string]Device{}}
}

func cloneAccount(a Account) Account {
	a.EpochsToDelete = append([]PendingEpoch(nil), a.EpochsToDelete...)
	if a.Library.Recovery != nil {
		r := *a.Library.Recovery
		a.Library.Recovery = &r
	}
	return a
}

func (m *Memory) Create(_ context.Context, c Creation) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.subs[c.SubKey]; ok {
		return ErrBound
	}
	if t := c.Account.AppAccountToken; t != "" {
		if _, ok := m.tokens[t]; ok {
			return ErrBound
		}
	}
	if _, ok := m.devices[c.Device.ID]; ok {
		return ErrDeviceBound
	}
	a := cloneAccount(c.Account)
	a.Normalize()
	m.acct[a.ID] = a
	m.subs[c.SubKey] = a.ID
	if a.AppAccountToken != "" {
		m.tokens[a.AppAccountToken] = a.ID
	}
	c.Device.AccountID = a.ID
	m.devices[c.Device.ID] = c.Device
	return nil
}

func (m *Memory) ResolveSub(_ context.Context, k string) (string, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.subs[k]
	return id, ok, nil
}

func (m *Memory) ResolveToken(_ context.Context, t string) (string, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.tokens[t]
	return id, ok, nil
}

func (m *Memory) BindSub(_ context.Context, accountID, subKey string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if id, ok := m.subs[subKey]; ok {
		if id == accountID {
			return nil
		}
		return ErrBound
	}
	if _, ok := m.acct[accountID]; !ok {
		return ErrNotFound
	}
	m.subs[subKey] = accountID
	return nil
}

func (m *Memory) GetAccount(_ context.Context, id string) (Account, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.acct[id]
	return cloneAccount(a), ok, nil
}

func (m *Memory) UpdateAccount(_ context.Context, id string, fn func(*Account) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	a, ok := m.acct[id]
	if !ok {
		return ErrNotFound
	}
	a = cloneAccount(a)
	if err := fn(&a); err != nil {
		return err
	}
	a.ID = id
	a.Normalize()
	m.acct[id] = a
	return nil
}

func (m *Memory) PendingEpochs(_ context.Context, limit int) ([]Account, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Account
	for _, a := range m.acct {
		if a.EpochQueue == "pending" {
			out = append(out, cloneAccount(a))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Memory) GetDevice(_ context.Context, id string) (Device, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	return d, ok, nil
}

func (m *Memory) ListDevices(_ context.Context, accountID string) ([]Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []Device
	for _, d := range m.devices {
		if d.AccountID == accountID {
			out = append(out, d)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].EnrolledAt.Equal(out[j].EnrolledAt) {
			return out[i].EnrolledAt.Before(out[j].EnrolledAt)
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func (m *Memory) PutDevice(_ context.Context, d Device) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if old, ok := m.devices[d.ID]; ok && old.AccountID != d.AccountID {
		return ErrDeviceBound
	}
	m.devices[d.ID] = d
	return nil
}

func (m *Memory) UpdateDevice(_ context.Context, id string, fn func(*Device) error) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return ErrNotFound
	}
	if err := fn(&d); err != nil {
		return err
	}
	d.ID = id
	m.devices[id] = d
	return nil
}

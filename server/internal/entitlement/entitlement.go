// Package entitlement is the one piece of server state that decides what a person may do: does their
// subscription entitle them to write, to read, or only to take their data home — and when is it deleted.
//
// It is pure (no clock, no network): every function takes `now`, so the whole life cycle is table-tested.
package entitlement

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/quota"
)

// State is what a user may do right now.
type State string

const (
	Active  State = "active"  // paid up: read and write
	Grace   State = "grace"   // billing retry inside Apple's grace period: read and write
	Lapsed  State = "lapsed"  // not paying: read and export only
	Deleted State = "deleted" // past retention: the data is gone
)

// Retention is the shortest time a lapsed user keeps read access before their data is deleted; bigger
// plans hold more data worth keeping and cost little more to hold, so they get longer (RetentionFor).
const Retention = 60 * 24 * time.Hour

// retentionDays is the read-only window by plan. Waiting costs only storage (~$0.013/GB-month) while
// deleting early can lose a customer's data for good, so the window is sized to what a user stands to lose,
// capped so a full plan never costs more than about a month of net revenue to hold (see cloud-sync-implementation.md §7).
var retentionDays = map[string]int{"starter": 180, "standard": 120, "large": 90, "max": 60}

// RetentionFor is how long the product's subscriber keeps read access after their paid period ends.
func RetentionFor(productID string) time.Duration {
	if p, ok := quota.ForProduct(quota.ProductPrefix, productID); ok {
		if d, ok := retentionDays[p.Name]; ok {
			return time.Duration(d) * 24 * time.Hour
		}
	}
	return Retention
}

// Entitlement is one subscriber, identified by the Apple subscription (never by an account).
type Entitlement struct {
	UID                   string    `json:"uid" firestore:"uid"`
	OriginalTransactionID string    `json:"originalTransactionId" firestore:"originalTransactionId"`
	ProductID             string    `json:"productId" firestore:"productId"`
	Environment           string    `json:"environment" firestore:"environment"`
	ExpiresAt             time.Time `json:"expiresAt" firestore:"expiresAt"`
	GraceUntil            time.Time `json:"graceUntil,omitempty" firestore:"graceUntil"`
	RevokedAt             time.Time `json:"revokedAt,omitempty" firestore:"revokedAt"`
	AutoRenew             bool      `json:"autoRenew" firestore:"autoRenew"`
	// SeenNotifications makes webhooks idempotent: Apple retries, and may deliver out of order.
	SeenNotifications []string  `json:"seenNotifications,omitempty" firestore:"seenNotifications"`
	UpdatedAt         time.Time `json:"updatedAt" firestore:"updatedAt"`
	// DeleteAfter is the indexed moment the retention sweep looks for. Zero while the user is paid up.
	DeleteAfter time.Time `json:"deleteAfter,omitempty" firestore:"deleteAfter"`
	// DataDeletedAt is set once the sweep has removed the user's data.
	DataDeletedAt time.Time `json:"dataDeletedAt,omitempty" firestore:"dataDeletedAt"`
}

// retention is this subscriber's read-only window, by the plan they last held.
func (e Entitlement) retention() time.Duration { return RetentionFor(e.ProductID) }

// paidUntil is the end of the last period the user is entitled to write in.
func (e Entitlement) paidUntil() time.Time {
	if e.GraceUntil.After(e.ExpiresAt) {
		return e.GraceUntil
	}
	return e.ExpiresAt
}

// StateAt is the state at `now`. A refund or revoke lapses immediately, whatever the expiry says.
func (e Entitlement) StateAt(now time.Time) State {
	if !e.DataDeletedAt.IsZero() {
		return Deleted
	}
	if !e.RevokedAt.IsZero() {
		if now.Before(e.RevokedAt.Add(e.retention())) {
			return Lapsed
		}
		return Deleted
	}
	switch {
	case now.Before(e.ExpiresAt):
		return Active
	case now.Before(e.GraceUntil):
		return Grace
	case now.Before(e.paidUntil().Add(e.retention())):
		return Lapsed
	}
	return Deleted
}

func (e Entitlement) CanWrite(now time.Time) bool {
	s := e.StateAt(now)
	return s == Active || s == Grace
}

func (e Entitlement) CanRead(now time.Time) bool {
	s := e.StateAt(now)
	return s == Active || s == Grace || s == Lapsed
}

// Due reports whether the retention sweep should delete this user's data at `now`.
func (e Entitlement) Due(now time.Time) bool {
	return e.DataDeletedAt.IsZero() && e.StateAt(now) == Deleted
}

func ms(v int64) time.Time {
	if v <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(v).UTC()
}

// FromTransaction folds a verified transaction into `existing` (nil for a new subscriber).
//
// A transaction can be stale — the Mac may present one it cached a month ago — so the expiry never moves
// backwards, and a revocation, once seen, is permanent.
func FromTransaction(existing *Entitlement, uid string, tx apple.Transaction, now time.Time) Entitlement {
	var e Entitlement
	if existing != nil {
		e = *existing
	}
	e.UID, e.OriginalTransactionID = uid, tx.OriginalTransactionID
	e.ProductID, e.Environment = tx.ProductID, tx.Environment
	if exp := ms(tx.ExpiresDate); exp.After(e.ExpiresAt) {
		e.ExpiresAt = exp
	}
	if rev := ms(tx.RevocationDate); !rev.IsZero() && e.RevokedAt.IsZero() {
		e.RevokedAt = rev
	}
	e.UpdatedAt = now
	return e.withDeleteAfter()
}

func (e Entitlement) withDeleteAfter() Entitlement {
	switch {
	case !e.RevokedAt.IsZero():
		e.DeleteAfter = e.RevokedAt.Add(e.retention())
	case e.paidUntil().IsZero():
		e.DeleteAfter = time.Time{}
	default:
		e.DeleteAfter = e.paidUntil().Add(e.retention())
	}
	return e
}

// ApplyNotification folds an App Store Server Notification into the entitlement. It reports whether
// anything changed; a repeated notification (same UUID) changes nothing.
func ApplyNotification(e Entitlement, n apple.Notification, tx *apple.Transaction, renewal *apple.RenewalInfo, now time.Time) (Entitlement, bool) {
	for _, seen := range e.SeenNotifications {
		if seen == n.NotificationUUID {
			return e, false
		}
	}
	e.SeenNotifications = append(e.SeenNotifications, n.NotificationUUID)
	if len(e.SeenNotifications) > 16 {
		e.SeenNotifications = e.SeenNotifications[len(e.SeenNotifications)-16:]
	}
	if tx != nil {
		e = FromTransaction(&e, e.UID, *tx, now)
	}
	if renewal != nil {
		e.AutoRenew = renewal.AutoRenewStatus == 1
		if g := ms(renewal.GracePeriodExpiresDate); g.After(e.GraceUntil) {
			e.GraceUntil = g
		}
	}
	switch n.NotificationType {
	case "REFUND", "REVOKE":
		if e.RevokedAt.IsZero() {
			e.RevokedAt = ms(n.SignedDate)
			if e.RevokedAt.IsZero() {
				e.RevokedAt = now
			}
		}
	case "DID_CHANGE_RENEWAL_STATUS":
		if renewal == nil && n.Subtype != "" {
			e.AutoRenew = n.Subtype == "AUTO_RENEW_ENABLED"
		}
	}
	e.UpdatedAt = now
	return e.withDeleteAfter(), true
}

// Store keeps entitlements. Firestore in production; Memory in tests and local runs.
type Store interface {
	Get(ctx context.Context, uid string) (Entitlement, bool, error)
	Put(ctx context.Context, e Entitlement) error
	// ByOriginalTransactionID finds the subscriber an Apple notification is about.
	ByOriginalTransactionID(ctx context.Context, id string) (Entitlement, bool, error)
	// Due returns up to `limit` entitlements whose data should be deleted at `now`.
	Due(ctx context.Context, now time.Time, limit int) ([]Entitlement, error)
}

// Memory is an in-process Store.
type Memory struct {
	mu   sync.Mutex
	byID map[string]Entitlement
}

func NewMemory() *Memory { return &Memory{byID: map[string]Entitlement{}} }

func (m *Memory) Get(_ context.Context, uid string) (Entitlement, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.byID[uid]
	return e, ok, nil
}

func (m *Memory) Put(_ context.Context, e Entitlement) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.byID[e.UID] = e
	return nil
}

func (m *Memory) ByOriginalTransactionID(_ context.Context, id string) (Entitlement, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, e := range m.byID {
		if e.OriginalTransactionID == id {
			return e, true, nil
		}
	}
	return Entitlement{}, false, nil
}

func (m *Memory) Due(_ context.Context, now time.Time, limit int) ([]Entitlement, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var due []Entitlement
	for _, e := range m.byID {
		if e.Due(now) {
			due = append(due, e)
		}
	}
	sort.Slice(due, func(i, j int) bool { return due[i].DeleteAfter.Before(due[j].DeleteAfter) })
	if len(due) > limit {
		due = due[:limit]
	}
	return due, nil
}

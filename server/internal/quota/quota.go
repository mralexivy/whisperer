// Package quota holds the plans and the limits that keep one user from costing more than they pay.
//
// Four tiers, each five times the last, one Apple subscription group (so Apple handles upgrades and
// downgrades and nobody pays twice). The download allowance — not storage — is what costs money, so it is
// the tight number: at list prices even a user who fills the plan *and* uses the whole allowance every month
// leaves a margin of 40-55% after Apple's 15% (docs/exec-plans/cloud-sync.md, "Plans and margins").
package quota

import (
	"errors"
	"strings"
)

type Limits struct {
	StoredBytes          int64
	MonthlyDownloadBytes int64
	MonthlyUploadGrants  int
}

// Plan is one sold tier.
type Plan struct {
	Name string
	Limits
}

const (
	GB = int64(1) << 30
	// ProductPrefix starts every Whisperer Cloud product id: com.ivy.whisperer.cloud.<tier>.<monthly|yearly>.
	ProductPrefix = "com.ivy.whisperer.cloud."
)

// Plans in ascending order. Max is defined so the server accepts it the day it goes on sale; it is not in
// the launch catalogue.
var Plans = []Plan{
	{"starter", Limits{5 * GB, 2 * GB, 1000}},
	{"standard", Limits{25 * GB, 6 * GB, 1500}},
	{"large", Limits{100 * GB, 15 * GB, 2500}},
	{"max", Limits{500 * GB, 35 * GB, 4000}},
}

// ForProduct maps a product id to its plan: "com.ivy.whisperer.cloud.standard.monthly" -> standard.
func ForProduct(prefix, productID string) (Plan, bool) {
	rest, ok := strings.CutPrefix(productID, prefix)
	if !ok {
		return Plan{}, false
	}
	tier, period, ok := strings.Cut(rest, ".")
	if !ok || (period != "monthly" && period != "yearly") {
		return Plan{}, false
	}
	for _, p := range Plans {
		if p.Name == tier {
			return p, true
		}
	}
	return Plan{}, false
}

type Usage struct {
	StoredBytes   int64
	DownloadBytes int64 // this calendar month
	UploadGrants  int   // this calendar month
}

var (
	ErrStorageFull   = errors.New("quota: storage is full")
	ErrDownloadLimit = errors.New("quota: monthly download allowance used")
	ErrGrantLimit    = errors.New("quota: too many uploads this month")
	// ErrOverQuota is a downgrade that leaves more stored than the new plan holds: uploads stop, nothing is deleted.
	ErrOverQuota = errors.New("quota: stored data exceeds this plan")
)

// CheckUpload decides whether `bytes` more may be stored in `grants` more upload grants. A user over their
// plan (after a downgrade) can keep reading and deleting but not add.
func (l Limits) CheckUpload(u Usage, bytes int64, grants int) error {
	if u.StoredBytes > l.StoredBytes {
		return ErrOverQuota
	}
	if u.StoredBytes+bytes > l.StoredBytes {
		return ErrStorageFull
	}
	if u.UploadGrants+grants > l.MonthlyUploadGrants {
		return ErrGrantLimit
	}
	return nil
}

func (l Limits) CheckDownload(u Usage, bytes int64) error {
	if u.DownloadBytes+bytes > l.MonthlyDownloadBytes {
		return ErrDownloadLimit
	}
	return nil
}

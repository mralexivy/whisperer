// Package quota holds the limits that keep one user from costing more than they pay. The numbers are the
// plan's (docs/exec-plans/cloud-sync.md): bytes stored, bytes downloaded per month, upload grants per month.
package quota

import "errors"

type Limits struct {
	StoredBytes          int64
	MonthlyDownloadBytes int64
	MonthlyUploadGrants  int
}

// Plan is the one plan sold: 10 GB stored, 5 GB of downloads a month, ~1,500 upload grants a month.
var Plan = Limits{StoredBytes: 10 << 30, MonthlyDownloadBytes: 5 << 30, MonthlyUploadGrants: 1500}

type Usage struct {
	StoredBytes   int64
	DownloadBytes int64 // this calendar month
	UploadGrants  int   // this calendar month
}

var (
	ErrStorageFull   = errors.New("quota: storage is full")
	ErrDownloadLimit = errors.New("quota: monthly download allowance used")
	ErrGrantLimit    = errors.New("quota: too many uploads this month")
)

// CheckUpload decides whether `bytes` more may be stored in `grants` more upload grants.
func (l Limits) CheckUpload(u Usage, bytes int64, grants int) error {
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

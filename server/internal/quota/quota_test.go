package quota_test

import (
	"errors"
	"testing"

	"github.com/mralexivy/whisperer/server/internal/quota"
)

func TestUploadLimits(t *testing.T) {
	l := quota.Plan
	if err := l.CheckUpload(quota.Usage{StoredBytes: 9 << 30}, 512<<20, 1); err != nil {
		t.Fatal(err)
	}
	if err := l.CheckUpload(quota.Usage{StoredBytes: 10<<30 - 100}, 200, 1); !errors.Is(err, quota.ErrStorageFull) {
		t.Fatalf("want storage full, got %v", err)
	}
	if err := l.CheckUpload(quota.Usage{UploadGrants: 1499}, 10, 2); !errors.Is(err, quota.ErrGrantLimit) {
		t.Fatalf("want grant limit, got %v", err)
	}
}

func TestDownloadLimit(t *testing.T) {
	l := quota.Plan
	if err := l.CheckDownload(quota.Usage{DownloadBytes: 4 << 30}, 512<<20); err != nil {
		t.Fatal(err)
	}
	if err := l.CheckDownload(quota.Usage{DownloadBytes: 5 << 30}, 1); !errors.Is(err, quota.ErrDownloadLimit) {
		t.Fatalf("want download limit, got %v", err)
	}
}

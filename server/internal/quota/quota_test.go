package quota_test

import (
	"errors"
	"testing"

	"github.com/mralexivy/whisperer/server/internal/quota"
)

func plan(t *testing.T, name string) quota.Plan {
	for _, p := range quota.Plans {
		if p.Name == name {
			return p
		}
	}
	t.Fatalf("no plan %q", name)
	return quota.Plan{}
}

func TestProductIdsMapToPlans(t *testing.T) {
	cases := map[string]string{
		"com.ivy.whisperer.cloud.starter.monthly": "starter",
		"com.ivy.whisperer.cloud.standard.yearly": "standard",
		"com.ivy.whisperer.cloud.large.monthly":   "large",
		"com.ivy.whisperer.cloud.max.yearly":      "max",
	}
	for id, want := range cases {
		if p, ok := quota.ForProduct(quota.ProductPrefix, id); !ok || p.Name != want {
			t.Errorf("%s -> %v %v, want %s", id, p.Name, ok, want)
		}
	}
	for _, bad := range []string{"", "com.ivy.whisperer.propack", "com.ivy.whisperer.cloud.huge.monthly",
		"com.ivy.whisperer.cloud.starter", "com.ivy.whisperer.cloud.starter.weekly", "other.cloud.starter.monthly"} {
		if _, ok := quota.ForProduct(quota.ProductPrefix, bad); ok {
			t.Errorf("%q must not be a plan", bad)
		}
	}
}

func TestEachTierIsFiveTimesTheLastAndDownloadsStayAFractionOfStorage(t *testing.T) {
	for i := 1; i < len(quota.Plans); i++ {
		prev, cur := quota.Plans[i-1], quota.Plans[i]
		if cur.StoredBytes < prev.StoredBytes*4 || cur.StoredBytes > prev.StoredBytes*5 {
			t.Errorf("%s is not ~5x %s", cur.Name, prev.Name)
		}
	}
	for _, p := range quota.Plans {
		if p.MonthlyDownloadBytes*2 > p.StoredBytes {
			t.Errorf("%s allows downloading more than half its storage a month — that is the cost line", p.Name)
		}
	}
}

// The margin rule, in code: at list prices a user at 100% of storage and 100% of the download allowance
// every month must still leave >= 30% after Apple's 15% (and the plan's own price points).
func TestWorstCaseMarginStaysAboveThirtyPercent(t *testing.T) {
	prices := map[string]float64{"starter": 0.99, "standard": 2.99, "large": 7.99, "max": 24.99}
	yearly := map[string]float64{"starter": 9.99 / 12, "standard": 29.99 / 12, "large": 79.99 / 12, "max": 249.99 / 12}
	for _, p := range quota.Plans {
		gb := float64(p.StoredBytes) / float64(quota.GB)
		dl := float64(p.MonthlyDownloadBytes) / float64(quota.GB)
		cost := gb*(0.3*0.020+0.7*0.010) + dl*0.12 + 0.01
		for label, price := range map[string]float64{"monthly": prices[p.Name], "yearly": yearly[p.Name]} {
			net := price * 0.85
			if margin := (net - cost) / net; margin < 0.30 {
				t.Errorf("%s %s: worst-case margin %.0f%% < 30%% (cost $%.2f, net $%.2f)", p.Name, label, margin*100, cost, net)
			}
		}
	}
}

func TestUploadLimits(t *testing.T) {
	l := plan(t, "standard").Limits
	if err := l.CheckUpload(quota.Usage{StoredBytes: 20 * quota.GB}, quota.GB, 1); err != nil {
		t.Fatal(err)
	}
	if err := l.CheckUpload(quota.Usage{StoredBytes: 25*quota.GB - 100}, 200, 1); !errors.Is(err, quota.ErrStorageFull) {
		t.Fatalf("want storage full, got %v", err)
	}
	if err := l.CheckUpload(quota.Usage{UploadGrants: 1499}, 10, 2); !errors.Is(err, quota.ErrGrantLimit) {
		t.Fatalf("want grant limit, got %v", err)
	}
}

func TestADowngradeNeverDeletesButStopsUploads(t *testing.T) {
	starter := plan(t, "starter").Limits
	over := quota.Usage{StoredBytes: 20 * quota.GB} // arrived from Standard
	if err := starter.CheckUpload(over, 1, 1); !errors.Is(err, quota.ErrOverQuota) {
		t.Fatalf("want over quota, got %v", err)
	}
	if err := starter.CheckDownload(over, quota.GB); err != nil {
		t.Fatalf("an over-quota user can still download their data: %v", err)
	}
}

func TestDownloadLimit(t *testing.T) {
	l := plan(t, "starter").Limits
	if err := l.CheckDownload(quota.Usage{DownloadBytes: quota.GB}, quota.GB/2); err != nil {
		t.Fatal(err)
	}
	if err := l.CheckDownload(quota.Usage{DownloadBytes: 2 * quota.GB}, 1); !errors.Is(err, quota.ErrDownloadLimit) {
		t.Fatalf("want download limit, got %v", err)
	}
}

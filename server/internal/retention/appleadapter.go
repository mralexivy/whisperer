package retention

import (
	"context"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
)

// AppleServerAPI adapts the App Store Server API to the sweep's Apple interface. When several entries come
// back, the most alive one wins: deleting someone's data must never be decided by their oldest transaction.
type AppleServerAPI struct{ API *apple.ServerAPI }

func rank(s Status) int {
	switch s {
	case StatusActive:
		return 4
	case StatusGrace:
		return 3
	case StatusRetry:
		return 2
	case StatusExpired:
		return 1
	}
	return 0 // revoked
}

func (a AppleServerAPI) Status(ctx context.Context, originalTransactionID string) (Answer, error) {
	statuses, err := a.API.Statuses(ctx, originalTransactionID)
	if err != nil {
		return Answer{}, err // not found, unreachable, unverifiable: all mean "do not delete"
	}
	var best Answer
	have := false
	for _, s := range statuses {
		ans := Answer{ExpiresAt: msTime(s.Transaction.ExpiresDate), GraceUntil: msTime(s.Renewal.GracePeriodExpiresDate)}
		switch s.Status {
		case apple.StatusActive:
			ans.Status = StatusActive
		case apple.StatusGrace:
			ans.Status = StatusGrace
		case apple.StatusRetry:
			ans.Status = StatusRetry
		case apple.StatusExpired:
			ans.Status = StatusExpired
		case apple.StatusRevoked:
			ans.Status = StatusRevoked
		default:
			// A status we do not understand is not evidence of anything: refuse to answer.
			return Answer{}, errUnknownStatus
		}
		if !have || rank(ans.Status) > rank(best.Status) {
			best, have = ans, true
		}
	}
	return best, nil
}

func msTime(ms int64) time.Time {
	if ms <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms).UTC()
}

var errUnknownStatus = errorString("retention: Apple returned a subscription status this server does not know")

type errorString string

func (e errorString) Error() string { return string(e) }

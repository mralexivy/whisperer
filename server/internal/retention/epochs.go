package retention

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// sweepEpochs deletes the objects of old library epochs. A reset (or key rotation) bumps the account's epoch and
// queues the old one; the person asked for it, so no Apple check is needed — but three guards remain:
//
//   - the epoch must be strictly older than the account's current epoch (the live library is never touched);
//   - an entry is only removed after the prefix has been seen empty AND StragglerGap has passed since it was
//     queued, so an upload URL granted just before the reset cannot recreate objects after the sweep;
//   - nothing at all is deleted until EpochHold (7 days) has passed since the reset, so a mistaken or malicious
//     reset can still be undone from the old ciphertext;
//   - dry-run mode reports and deletes nothing.
//
// Anything unexpected (list or delete failure) leaves the entry queued for the next run.
func (s *Sweeper) sweepEpochs(ctx context.Context, now time.Time, rep *Report) {
	if s.Accounts == nil {
		return
	}
	accts, err := s.Accounts.PendingEpochs(ctx, s.MaxPerRun)
	if err != nil {
		s.log().Error("retention: listing queued epochs", "err", err)
		return
	}
	for _, a := range accts {
		for _, pe := range a.EpochsToDelete {
			key := fmt.Sprintf("%s/%d", a.ID, pe.Epoch)
			if pe.Epoch >= a.Epoch {
				s.log().Error("retention: refusing to delete the current or a future epoch", "account", a.ID, "epoch", pe.Epoch, "current", a.Epoch)
				continue
			}
			if now.Sub(pe.QueuedAt) < s.EpochHold {
				continue // held: nothing is deleted until the hold has passed
			}
			if s.DryRun {
				rep.EpochsDryRun = append(rep.EpochsDryRun, key)
				continue
			}
			if !s.emptyEpoch(ctx, syncplane.Prefix(s.Root, a.ID, pe.Epoch), key) {
				continue
			}
			if now.Sub(pe.QueuedAt) < s.StragglerGap {
				continue // empty now, but in-flight upload URLs may still land: look again later
			}
			err := s.Accounts.UpdateAccount(ctx, a.ID, func(acc *account.Account) error {
				kept := acc.EpochsToDelete[:0]
				for _, q := range acc.EpochsToDelete {
					if q.Epoch != pe.Epoch {
						kept = append(kept, q)
					}
				}
				acc.EpochsToDelete = kept
				return nil
			})
			if err != nil {
				s.log().Warn("retention: clearing a deleted epoch", "account", a.ID, "epoch", pe.Epoch, "err", err)
				continue
			}
			rep.EpochsDeleted = append(rep.EpochsDeleted, key)
			s.log().Info("retention: old epoch deleted", "account", a.ID, "epoch", pe.Epoch)
		}
	}
}

// emptyEpoch deletes up to MaxPages pages under prefix and reports whether the prefix is now empty.
func (s *Sweeper) emptyEpoch(ctx context.Context, prefix, key string) bool {
	for page := 0; page < s.MaxPages; page++ {
		names, _, err := s.Blobs.List(ctx, prefix, "", s.PageSize)
		if err != nil {
			s.log().Warn("retention: list old epoch", "epoch", key, "err", err)
			return false
		}
		if len(names) == 0 {
			return true
		}
		for _, n := range names {
			if err := s.Blobs.Delete(ctx, n); err != nil && !errors.Is(err, syncplane.ErrNotFound) {
				s.log().Warn("retention: delete old epoch object", "epoch", key, "err", err)
				return false
			}
		}
	}
	return false // out of time: continue next run
}

package server

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/devauth"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

func (s *Server) libraryRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/library", s.limited(s.authed(s.handleCreateLibrary)))
	mux.HandleFunc("PUT /v1/library/recovery", s.limited(s.authed(s.handlePutRecovery)))
	mux.HandleFunc("POST /v1/library/recovery-blob", s.limited(s.handleRecoveryBlob))
	mux.HandleFunc("POST /v1/library/reset", s.limited(s.handleReset))
}

// ResetPhrase is the confirmation a reset request must carry verbatim.
const ResetPhrase = "RESET MY LIBRARY"

type recoveryIn struct {
	Wrapped string `json:"wrapped"`
	Kdf     string `json:"kdf"`
}

func (r recoveryIn) valid() bool {
	return r.Wrapped != "" && len(r.Wrapped) <= 4096 && r.Kdf != "" && len(r.Kdf) <= 256
}

// POST /v1/library — create-if-absent. The caller generated a key *after* a GET said none exists; if two Macs
// race, the loser gets 409 and must adopt the winner's key and discard its own.
func (s *Server) handleCreateLibrary(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var req struct {
		KeyVerifier string      `json:"keyVerifier"`
		KeyVersion  int         `json:"keyVersion"`
		Recovery    *recoveryIn `json:"recovery,omitempty"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !devauth.ValidVerifier(req.KeyVerifier) || req.KeyVersion < 0 || req.KeyVersion > 255 || (req.Recovery != nil && !req.Recovery.valid()) {
		fail(w, 400, "bad_request", "keyVerifier must be 64 hex characters and recovery needs wrapped and kdf")
		return
	}
	if req.KeyVersion == 0 {
		req.KeyVersion = 1
	}
	ctx, now := r.Context(), s.cfg.Now()
	if _, ok := s.requireDevice(w, ctx, c); !ok {
		return
	}
	_, e, ok := s.loadAccount(w, ctx, c.Acct)
	if !ok {
		return
	}
	if !e.CanWrite(now) {
		fail(w, 403, "read_only", "this subscription is not active")
		return
	}
	var existing account.Library
	err := s.accounts.UpdateAccount(ctx, c.Acct, func(a *account.Account) error {
		if a.Library.Exists {
			existing = a.Library
			return account.ErrLibraryExists
		}
		a.Library = account.Library{Exists: true, KeyVersion: req.KeyVersion, Verifier: req.KeyVerifier}
		if req.Recovery != nil {
			a.Library.Recovery = &account.Recovery{Wrapped: req.Recovery.Wrapped, Kdf: req.Recovery.Kdf, CreatedAt: now}
		}
		return nil
	})
	switch {
	case errors.Is(err, account.ErrLibraryExists):
		writeJSON(w, 409, map[string]any{"error": "library_exists", "message": "a library already exists; adopt its key and discard yours",
			"library": libraryInfo{Exists: true, KeyVersion: existing.KeyVersion, RecoveryAvailable: existing.Recovery != nil}})
	case err != nil:
		s.fault(w, "create library", err)
	default:
		writeJSON(w, 201, map[string]any{"keyVersion": req.KeyVersion})
	}
}

// PUT /v1/library/recovery — replace the recovery blob. Needs a session *and* a fresh key proof: a stolen token
// alone must not be able to swap in a blob that the thief can unwrap.
func (s *Server) handlePutRecovery(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var req struct {
		recoveryIn
		Nonce    string `json:"nonce"`
		KeyProof string `json:"keyProof"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !req.valid() {
		fail(w, 400, "bad_request", "wrapped and kdf are required")
		return
	}
	ctx, now := r.Context(), s.cfg.Now()
	if _, ok := s.requireDevice(w, ctx, c); !ok {
		return
	}
	if s.proofBlocked(c.Dev, c.Acct, now) {
		w.Header().Set("Retry-After", "3600")
		fail(w, 429, "rate_limited", "too many wrong key proofs; try again later")
		return
	}
	acct, _, ok := s.loadAccount(w, ctx, c.Acct)
	if !ok {
		return
	}
	if !acct.Library.Exists {
		fail(w, 404, "no_library", "there is no library yet")
		return
	}
	if _, err := s.chall.NonceBytes(c.Dev, req.Nonce, now); err != nil {
		fail(w, 401, "bad_nonce", "the challenge expired; request a new one")
		return
	}
	if !devauth.CheckKeyProof(acct.Library.Verifier, req.Nonce, c.Dev, devauth.PurposeRecovery, req.KeyProof) {
		s.proofFailed(c.Dev, c.Acct, now)
		fail(w, 403, "bad_key_proof", "the library key could not be proved")
		return
	}
	err := s.accounts.UpdateAccount(ctx, c.Acct, func(a *account.Account) error {
		if !a.Library.Exists || a.Library.Verifier != acct.Library.Verifier {
			return account.ErrNotFound // reset underneath us
		}
		a.Library.Recovery = &account.Recovery{Wrapped: req.Wrapped, Kdf: req.Kdf, CreatedAt: now}
		return nil
	})
	if errors.Is(err, account.ErrNotFound) {
		fail(w, 409, "library_changed", "the library was reset; start again")
		return
	} else if err != nil {
		s.fault(w, "put recovery", err)
		return
	}
	w.WriteHeader(204)
}

// deviceEntitled authenticates a request made by a pending or authorized device (not yet or no longer holding a
// session token): device signature over a fresh nonce for `purpose`, plus a transaction that maps to the same account.
func (s *Server) deviceEntitled(w http.ResponseWriter, ctx context.Context, deviceID, nonce, sig, purpose, jws string) (account.Device, account.Account, entitlement.Entitlement, bool) {
	var none account.Account
	dev, ok := s.knownDevice(w, ctx, deviceID, nonce, sig, purpose)
	if !ok {
		return dev, none, entitlement.Entitlement{}, false
	}
	tx, ok := s.verifiedTransaction(w, jws)
	if !ok {
		return dev, none, entitlement.Entitlement{}, false
	}
	owner, _, err := s.accountOfTransaction(ctx, tx)
	if err != nil && !errors.Is(err, errNoAccount) && !errors.Is(err, errAccountMismatch) {
		s.fault(w, "resolve account", err)
		return dev, none, entitlement.Entitlement{}, false
	}
	if err != nil || owner != dev.AccountID {
		fail(w, 403, "wrong_account", "this purchase does not belong to the device's account")
		return dev, none, entitlement.Entitlement{}, false
	}
	acct, e, ok := s.loadAccount(w, ctx, dev.AccountID)
	return dev, acct, e, ok
}

// POST /v1/library/recovery-blob — usable before enrolment, and useless without the recovery key.
func (s *Server) handleRecoveryBlob(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID       string `json:"deviceId"`
		Nonce          string `json:"nonce"`
		Sig            string `json:"sig"`
		TransactionJWS string `json:"transactionJWS"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	_, acct, e, ok := s.deviceEntitled(w, r.Context(), req.DeviceID, req.Nonce, req.Sig, devauth.PurposeRecoveryBlob, req.TransactionJWS)
	if !ok {
		return
	}
	if e.StateAt(s.cfg.Now()) == entitlement.Deleted {
		fail(w, 402, "subscription_expired", "this subscription has ended and its data has been removed")
		return
	}
	if !acct.Library.Exists || acct.Library.Recovery == nil {
		fail(w, 404, "no_recovery", "this library has no recovery key")
		return
	}
	rec := acct.Library.Recovery
	writeJSON(w, 200, map[string]any{"wrapped": rec.Wrapped, "kdf": rec.Kdf, "keyVersion": acct.Library.KeyVersion})
}

// POST /v1/library/reset — the escape hatch when the key is gone. It bumps the epoch, forgets the verifier and
// recovery blob, and queues the old epoch's objects for deletion. Two ways in, both needing the typed phrase:
//
//	S  an authorized device's session token (body: {confirm});
//	D+A a pending/authorized device with a device signature (purpose "library.reset") and a valid transaction
//	    for the account (body: {confirm, deviceId, nonce, sig, transactionJWS}) — the lost-key case, where the Mac
//	    cannot have a session. The resetting device becomes authorized: the old data is gone, nothing is left to protect.
func (s *Server) handleReset(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Confirm        string `json:"confirm"`
		DeviceID       string `json:"deviceId"`
		Nonce          string `json:"nonce"`
		Sig            string `json:"sig"`
		TransactionJWS string `json:"transactionJWS"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if req.Confirm != ResetPhrase {
		fail(w, 400, "confirmation_required", "type the confirmation phrase to reset the library")
		return
	}
	ctx, now := r.Context(), s.cfg.Now()
	var (
		acct      account.Account
		e         entitlement.Entitlement
		dev       account.Device
		fromEpoch int // 0: unconditional (device path)
	)
	if hdr := r.Header.Get("Authorization"); hdr != "" {
		c, ok := s.claimsFrom(w, hdr)
		if !ok {
			return
		}
		if dev, ok = s.requireDevice(w, ctx, c); !ok {
			return
		}
		if acct, e, ok = s.loadAccount(w, ctx, c.Acct); !ok {
			return
		}
		fromEpoch = c.Epoch
	} else {
		var ok bool
		if dev, acct, e, ok = s.deviceEntitled(w, ctx, req.DeviceID, req.Nonce, req.Sig, devauth.PurposeReset, req.TransactionJWS); !ok {
			return
		}
	}
	if st := e.StateAt(now); !readable(st) {
		fail(w, 403, "no_access", "this subscription's data is no longer available")
		return
	}
	if dev.State == account.DevicePending {
		pl, _ := s.planFor(e.ProductID)
		if n, err := s.authorizedCount(ctx, acct.ID); err != nil {
			s.fault(w, "list devices", err)
			return
		} else if n >= account.DeviceCap(pl.Name) {
			fail(w, 403, "device_limit", "this plan's device limit is reached; remove a device first")
			return
		}
	}
	var epoch int
	err := s.accounts.UpdateAccount(ctx, acct.ID, func(a *account.Account) error {
		epoch = a.Epoch
		if fromEpoch != 0 && a.Epoch != fromEpoch {
			return nil // already reset since this token was issued: converge, do not bump twice
		}
		a.EpochsToDelete = append(a.EpochsToDelete, account.PendingEpoch{Epoch: a.Epoch, QueuedAt: now})
		a.Epoch++
		a.Library = account.Library{}
		epoch = a.Epoch
		return nil
	})
	if err != nil {
		s.fault(w, "reset library", err)
		return
	}
	if err := s.resetSyncState(ctx, acct.ID, epoch); err != nil {
		s.fault(w, "reset sync state", err)
		return
	}
	if dev.State == account.DevicePending {
		if err := s.accounts.UpdateDevice(ctx, dev.ID, func(d *account.Device) error {
			d.State, d.EnrollChallenge, d.PurgeAt, d.LastSeenAt = account.DeviceAuthorized, "", time.Time{}, now
			return nil
		}); err != nil {
			s.fault(w, "authorize device", err)
			return
		}
	}
	fresh, _, _ := s.accounts.GetAccount(ctx, acct.ID)
	resp := s.issue(fresh, e, dev.ID, now)
	writeJSON(w, 200, map[string]any{"epoch": epoch, "token": resp.Token, "expiresAt": resp.ExpiresAt, "library": resp.Library})
}

// resetSyncState gives the new epoch an empty head set and an empty quota ledger. Old-epoch bytes stop counting
// against the plan at once (they are queued for deletion); the monthly download/grant counters are kept.
func (s *Server) resetSyncState(ctx context.Context, accountID string, epoch int) error {
	if s.sync == nil {
		return nil
	}
	changed := false
	err := s.sync.Store.UpdateHeads(ctx, accountID, func(h *syncplane.Heads) error {
		changed = h.Epoch != epoch
		if !changed {
			return nil
		}
		*h = syncplane.Heads{Epoch: epoch, Version: h.Version + 1, Heads: map[string]syncplane.Head{}}
		return nil
	})
	if err != nil || !changed {
		return err
	}
	return s.sync.Store.UpdateUsage(ctx, accountID, func(u *syncplane.Usage) error {
		u.Committed, u.Reserved, u.Pending = 0, 0, nil
		return nil
	})
}

func (s *Server) claimsFrom(w http.ResponseWriter, header string) (auth.Claims, bool) {
	token, ok := trimBearer(header)
	if !ok {
		fail(w, 401, "unauthorized", "sign in again")
		return auth.Claims{}, false
	}
	c, err := s.verifier.Verify(token, s.cfg.Now())
	if err != nil {
		fail(w, 401, "unauthorized", "the session has expired")
		return c, false
	}
	return c, true
}

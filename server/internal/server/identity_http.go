package server

import (
	"context"
	"errors"
	"math/rand/v2"
	"net/http"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/devauth"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/quota"
)

func (s *Server) identityRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/auth/challenge", s.limited(s.handleChallenge))
	mux.HandleFunc("POST /v1/accounts", s.limited(s.handleCreateAccount))
	mux.HandleFunc("POST /v1/devices", s.limited(s.handleEnrollDevice))
	mux.HandleFunc("POST /v1/devices/confirm", s.limited(s.handleConfirmDevice))
	mux.HandleFunc("POST /v1/session", s.limited(s.handleSession))
	mux.HandleFunc("GET /v1/account", s.limited(s.authed(s.handleAccount)))
	mux.HandleFunc("DELETE /v1/devices/{id}", s.limited(s.authed(s.handleRevokeDevice)))
}

type libraryInfo struct {
	Exists            bool `json:"exists"`
	KeyVersion        int  `json:"keyVersion"`
	RecoveryAvailable bool `json:"recoveryAvailable"`
}

func libraryOf(a account.Account) libraryInfo {
	return libraryInfo{Exists: a.Library.Exists, KeyVersion: a.Library.KeyVersion, RecoveryAvailable: a.Library.Recovery != nil}
}

// MARK: challenge

func (s *Server) handleChallenge(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string `json:"deviceId"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if !devauth.ValidDeviceID(req.DeviceID) {
		fail(w, 400, "bad_request", "deviceId must be 32 lowercase hex characters")
		return
	}
	now := s.cfg.Now()
	writeJSON(w, 200, map[string]any{"nonce": s.chall.Nonce(req.DeviceID, now), "serverTime": now.UTC()})
}

func (s *Server) verifyDevice(w http.ResponseWriter, pubB64, nonce, sig, purpose string) (id string, ok bool) {
	pub, err := devauth.ParsePublicKey(pubB64)
	if err != nil {
		fail(w, 400, "bad_device_key", "devicePublicKey must be a base64 P-256 x9.63 public key")
		return "", false
	}
	id = devauth.DeviceID(pub)
	if err := s.chall.Verify(pub, id, nonce, purpose, sig, s.cfg.Now()); err != nil {
		deviceSigFailure(w, err)
		return "", false
	}
	return id, true
}

func deviceSigFailure(w http.ResponseWriter, err error) {
	if errors.Is(err, devauth.ErrBadNonce) {
		fail(w, 401, "bad_nonce", "the challenge expired; request a new one")
		return
	}
	fail(w, 401, "bad_signature", "the device signature does not verify")
}

// knownDevice loads a device by id and verifies its signature with the key on file. It writes the answer on failure.
func (s *Server) knownDevice(w http.ResponseWriter, ctx context.Context, deviceID, nonce, sig, purpose string) (account.Device, bool) {
	if !devauth.ValidDeviceID(deviceID) {
		fail(w, 400, "bad_request", "deviceId must be 32 lowercase hex characters")
		return account.Device{}, false
	}
	d, found, err := s.accounts.GetDevice(ctx, deviceID)
	if err != nil {
		s.fault(w, "get device", err)
		return d, false
	}
	if !found {
		fail(w, 404, "unknown_device", "this device is not enrolled")
		return d, false
	}
	pub, err := devauth.ParsePublicKey(d.PubKey)
	if err != nil {
		s.fault(w, "stored device key", err)
		return d, false
	}
	if err := s.chall.Verify(pub, d.ID, nonce, purpose, sig, s.cfg.Now()); err != nil {
		deviceSigFailure(w, err)
		return d, false
	}
	switch {
	case d.State == account.DeviceRevoked:
		fail(w, 403, "device_revoked", "this device was removed from the account")
		return d, false
	case d.Expired(s.cfg.Now()):
		fail(w, 403, "enrollment_expired", "this enrolment expired; enrol the device again")
		return d, false
	}
	return d, true
}

// MARK: account creation

type deviceAuthFields struct {
	DevicePublicKey string `json:"devicePublicKey"`
	Nonce           string `json:"nonce"`
	Sig             string `json:"sig"`
	LabelEnc        string `json:"labelEnc,omitempty"`
	AppVersion      string `json:"appVersion,omitempty"`
}

func (f deviceAuthFields) valid() bool { return len(f.LabelEnc) <= 512 && len(f.AppVersion) <= 32 }

type tokenResponse struct {
	AccountID  string            `json:"accountId"`
	DeviceID   string            `json:"deviceId"`
	Epoch      int               `json:"epoch"`
	Token      string            `json:"token"`
	ExpiresAt  time.Time         `json:"expiresAt"`
	State      entitlement.State `json:"state"`
	ReadOnly   bool              `json:"readOnly"`
	Plan       planInfo          `json:"plan"`
	PaidUntil  time.Time         `json:"paidUntil"`
	Library    libraryInfo       `json:"library"`
	ServerTime time.Time         `json:"serverTime"`
}

// issue mints the session token for an authorized device.
func (s *Server) issue(a account.Account, e entitlement.Entitlement, deviceID string, now time.Time) tokenResponse {
	state := e.StateAt(now)
	readOnly := !e.CanWrite(now)
	tok, claims := s.signer.Issue(a.ID, deviceID, a.Epoch, string(state), readOnly, now)
	pl, _ := s.planFor(e.ProductID)
	return tokenResponse{AccountID: a.ID, DeviceID: deviceID, Epoch: a.Epoch, Token: tok, ExpiresAt: time.Unix(claims.Exp, 0).UTC(),
		State: state, ReadOnly: readOnly, Plan: planOf(pl), PaidUntil: e.ExpiresAt, Library: libraryOf(a), ServerTime: now.UTC()}
}

func (s *Server) handleCreateAccount(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TransactionJWS string `json:"transactionJWS"`
		deviceAuthFields
	}
	if !readJSON(w, r, &req) || !req.valid() {
		return
	}
	deviceID, ok := s.verifyDevice(w, req.DevicePublicKey, req.Nonce, req.Sig, devauth.PurposeAccountCreate)
	if !ok {
		return
	}
	tx, ok := s.verifiedTransaction(w, req.TransactionJWS)
	if !ok {
		return
	}
	ctx, now := r.Context(), s.cfg.Now()
	subKey := s.SubKey(tx.OriginalTransactionID)
	if _, bound, err := s.accounts.ResolveSub(ctx, subKey); err != nil {
		s.fault(w, "resolve subscription", err)
		return
	} else if bound {
		fail(w, 409, "already_bound", "this subscription already has an account; enrol this device with POST /v1/devices")
		return
	}
	if tx.AppAccountToken != "" {
		if _, bound, err := s.accounts.ResolveToken(ctx, tx.AppAccountToken); err != nil {
			s.fault(w, "resolve token", err)
			return
		} else if bound {
			fail(w, 409, "already_bound", "this subscription already has an account; enrol this device with POST /v1/devices")
			return
		}
	}
	e := entitlement.FromTransaction(nil, "", tx, now)
	if e.StateAt(now) == entitlement.Deleted {
		fail(w, 402, "subscription_expired", "this subscription has ended and its data has been removed")
		return
	}
	acct := account.Account{ID: devauth.NewRandomHex(16), CreatedAt: now, AppAccountToken: tx.AppAccountToken, Epoch: 1}
	e.UID = acct.ID
	// The entitlement is written first: it is keyed by the fresh random id, so a failure after it leaves only an
	// unreachable record, never an account without one.
	if err := s.store.Put(ctx, e); err != nil {
		s.fault(w, "store put", err)
		return
	}
	dev := account.Device{ID: deviceID, AccountID: acct.ID, PubKey: req.DevicePublicKey, State: account.DeviceAuthorized,
		LabelEnc: req.LabelEnc, AppVersion: req.AppVersion, EnrolledAt: now, LastSeenAt: now}
	switch err := s.accounts.Create(ctx, account.Creation{Account: acct, SubKey: subKey, Device: dev}); {
	case errors.Is(err, account.ErrBound):
		fail(w, 409, "already_bound", "this subscription already has an account; enrol this device with POST /v1/devices")
		return
	case errors.Is(err, account.ErrDeviceBound):
		fail(w, 409, "device_bound", "this device key already belongs to an account; generate a new device key")
		return
	case err != nil:
		s.fault(w, "create account", err)
		return
	}
	writeJSON(w, 201, s.issue(acct, e, deviceID, now))
}

// MARK: device enrolment

// accountOfTransaction finds the account a verified transaction belongs to: its subscription mapping, else
// its purchase-token mapping. subBound reports whether the subscription itself is mapped.
func (s *Server) accountOfTransaction(ctx context.Context, tx apple.Transaction) (id string, subBound bool, err error) {
	subID, subOK, err := s.accounts.ResolveSub(ctx, s.SubKey(tx.OriginalTransactionID))
	if err != nil {
		return "", false, err
	}
	tokID, tokOK := "", false
	if tx.AppAccountToken != "" {
		if tokID, tokOK, err = s.accounts.ResolveToken(ctx, tx.AppAccountToken); err != nil {
			return "", false, err
		}
	}
	switch {
	case subOK && tokOK && subID != tokID:
		return "", false, errAccountMismatch
	case subOK:
		return subID, true, nil
	case tokOK:
		return tokID, false, nil
	}
	return "", false, errNoAccount
}

var errAccountMismatch = errors.New("subscription and purchase token map to different accounts")

func (s *Server) accountFail(w http.ResponseWriter, what string, err error) {
	switch {
	case errors.Is(err, errNoAccount):
		fail(w, 404, "no_account", "no account exists for this purchase; create one with POST /v1/accounts")
	case errors.Is(err, errAccountMismatch):
		fail(w, 409, "account_mismatch", "this purchase maps to more than one account")
	default:
		s.fault(w, what, err)
	}
}

func (s *Server) handleEnrollDevice(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TransactionJWS string `json:"transactionJWS"`
		deviceAuthFields
	}
	if !readJSON(w, r, &req) || !req.valid() {
		return
	}
	deviceID, ok := s.verifyDevice(w, req.DevicePublicKey, req.Nonce, req.Sig, devauth.PurposeDeviceEnroll)
	if !ok {
		return
	}
	tx, ok := s.verifiedTransaction(w, req.TransactionJWS)
	if !ok {
		return
	}
	ctx, now := r.Context(), s.cfg.Now()
	acctID, _, err := s.accountOfTransaction(ctx, tx)
	if err != nil {
		s.accountFail(w, "resolve account", err)
		return
	}
	acct, e, ok := s.loadAccount(w, ctx, acctID)
	if !ok {
		return
	}
	if e.StateAt(now) == entitlement.Deleted {
		fail(w, 402, "subscription_expired", "this subscription has ended and its data has been removed")
		return
	}
	existing, found, err := s.accounts.GetDevice(ctx, deviceID)
	if err != nil {
		s.fault(w, "get device", err)
		return
	}
	switch {
	case found && existing.AccountID != acct.ID:
		fail(w, 409, "device_bound", "this device key already belongs to an account; generate a new device key")
		return
	case found && existing.State == account.DeviceRevoked:
		fail(w, 403, "device_revoked", "this device was removed from the account; generate a new device key")
		return
	case found && existing.State == account.DeviceAuthorized:
		fail(w, 409, "device_enrolled", "this device is already enrolled; use POST /v1/session")
		return
	}
	devices, err := s.accounts.ListDevices(ctx, acct.ID)
	if err != nil {
		s.fault(w, "list devices", err)
		return
	}
	pl, _ := s.planFor(e.ProductID)
	authorized, pending := 0, 0
	for _, d := range devices {
		switch {
		case d.State == account.DeviceAuthorized:
			authorized++
		case d.State == account.DevicePending && !d.Expired(now) && d.ID != deviceID:
			pending++
		}
	}
	if authorized >= account.DeviceCap(pl.Name) {
		fail(w, 403, "device_limit", "this plan's device limit is reached; remove a device first")
		return
	}
	if pending >= account.MaxPending {
		fail(w, 429, "too_many_pending", "too many devices are waiting to be confirmed")
		return
	}
	challenge := devauth.NewRandomHex(16)
	dev := account.Device{ID: deviceID, AccountID: acct.ID, PubKey: req.DevicePublicKey, State: account.DevicePending,
		LabelEnc: req.LabelEnc, AppVersion: req.AppVersion, EnrolledAt: now, EnrollChallenge: challenge, PurgeAt: now.Add(account.PendingTTL)}
	switch err := s.accounts.PutDevice(ctx, dev); {
	case errors.Is(err, account.ErrDeviceBound):
		fail(w, 409, "device_bound", "this device key already belongs to an account; generate a new device key")
		return
	case err != nil:
		s.fault(w, "put device", err)
		return
	}
	// Only what the plan allows a device without the key to learn: whether a library exists, and a challenge.
	writeJSON(w, 200, map[string]any{"deviceId": deviceID, "library": libraryOf(acct), "enrollChallenge": challenge, "expiresAt": dev.PurgeAt.UTC()})
}

func (s *Server) loadAccount(w http.ResponseWriter, ctx context.Context, id string) (account.Account, entitlement.Entitlement, bool) {
	acct, found, err := s.accounts.GetAccount(ctx, id)
	if err != nil {
		s.fault(w, "get account", err)
		return acct, entitlement.Entitlement{}, false
	}
	e, efound, eerr := s.store.Get(ctx, id)
	switch {
	case eerr != nil:
		s.fault(w, "store get", eerr)
		return acct, e, false
	case !found || !efound:
		fail(w, 404, "no_account", "no account found")
		return acct, e, false
	}
	return acct, e, true
}

const (
	deviceProofLimit  = 5  // failed key proofs per device per hour
	accountProofLimit = 10 // failed key proofs per account per hour
)

func (s *Server) proofBlocked(deviceID, accountID string, now time.Time) bool {
	return s.proofFails.exceeded("dev:"+deviceID, deviceProofLimit, now) || s.proofFails.exceeded("acct:"+accountID, accountProofLimit, now)
}

func (s *Server) proofFailed(deviceID, accountID string, now time.Time) {
	s.proofFails.add("dev:"+deviceID, now)
	s.proofFails.add("acct:"+accountID, now)
}

func (s *Server) handleConfirmDevice(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID string `json:"deviceId"`
		Nonce    string `json:"nonce"`
		Sig      string `json:"sig"`
		KeyProof string `json:"keyProof"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	ctx, now := r.Context(), s.cfg.Now()
	if devauth.ValidDeviceID(req.DeviceID) && s.proofFails.exceeded("dev:"+req.DeviceID, deviceProofLimit, now) {
		w.Header().Set("Retry-After", "3600")
		fail(w, 429, "rate_limited", "too many wrong key proofs; try again later")
		return
	}
	dev, ok := s.knownDevice(w, ctx, req.DeviceID, req.Nonce, req.Sig, devauth.PurposeDeviceConfirm)
	if !ok {
		return
	}
	acct, e, ok := s.loadAccount(w, ctx, dev.AccountID)
	if !ok {
		return
	}
	if s.proofBlocked(dev.ID, acct.ID, now) {
		w.Header().Set("Retry-After", "3600")
		fail(w, 429, "rate_limited", "too many wrong key proofs; try again later")
		return
	}
	if e.StateAt(now) == entitlement.Deleted {
		fail(w, 402, "subscription_expired", "this subscription has ended and its data has been removed")
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
		// With no library there is no key to prove and nothing to protect: uploads are refused until one exists.
		if acct.Library.Exists && !devauth.CheckKeyProof(acct.Library.Verifier, dev.EnrollChallenge, dev.ID, "", req.KeyProof) {
			s.proofFailed(dev.ID, acct.ID, now)
			fail(w, 403, "bad_key_proof", "the library key could not be proved")
			return
		}
		err := s.accounts.UpdateDevice(ctx, dev.ID, func(d *account.Device) error {
			if d.State != account.DevicePending || d.EnrollChallenge != dev.EnrollChallenge {
				return errConfirmRaced
			}
			d.State, d.EnrollChallenge, d.PurgeAt, d.LastSeenAt = account.DeviceAuthorized, "", time.Time{}, now
			return nil
		})
		if errors.Is(err, errConfirmRaced) {
			fail(w, 409, "enrollment_changed", "this enrolment was changed; enrol the device again")
			return
		} else if err != nil {
			s.fault(w, "confirm device", err)
			return
		}
	}
	writeJSON(w, 200, s.issue(acct, e, dev.ID, now))
}

var errConfirmRaced = errors.New("enrolment changed while confirming")

func (s *Server) authorizedCount(ctx context.Context, accountID string) (int, error) {
	devices, err := s.accounts.ListDevices(ctx, accountID)
	n := 0
	for _, d := range devices {
		if d.State == account.DeviceAuthorized {
			n++
		}
	}
	return n, err
}

// MARK: session

func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceID       string `json:"deviceId"`
		Nonce          string `json:"nonce"`
		Sig            string `json:"sig"`
		TransactionJWS string `json:"transactionJWS,omitempty"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	ctx, now := r.Context(), s.cfg.Now()
	dev, ok := s.knownDevice(w, ctx, req.DeviceID, req.Nonce, req.Sig, devauth.PurposeSession)
	if !ok {
		return
	}
	if dev.State != account.DeviceAuthorized {
		fail(w, 403, "device_pending", "this device has not proved the library key yet")
		return
	}
	acct, e, ok := s.loadAccount(w, ctx, dev.AccountID)
	if !ok {
		return
	}
	if req.TransactionJWS != "" {
		tx, ok := s.verifiedTransaction(w, req.TransactionJWS)
		if !ok {
			return
		}
		if e, ok = s.refreshEntitlement(w, ctx, acct, e, tx, now); !ok {
			return
		}
	}
	if e.StateAt(now) == entitlement.Deleted {
		fail(w, 402, "subscription_expired", "this subscription has ended and its data has been removed")
		return
	}
	if now.Sub(dev.LastSeenAt) > 24*time.Hour {
		_ = s.accounts.UpdateDevice(ctx, dev.ID, func(d *account.Device) error { d.LastSeenAt = now; return nil })
	}
	if s.sweeper != nil && rand.IntN(20) == 0 {
		s.sweepNow(ctx)
	}
	writeJSON(w, 200, s.issue(acct, e, dev.ID, now))
}

// refreshEntitlement folds a transaction presented by an authorized device into the account's entitlement. A
// subscription not yet bound to the account (resubscribe, upgrade chain) is bound here — only here and only
// from an enrolled device — and only when its purchase token already maps to this account.
func (s *Server) refreshEntitlement(w http.ResponseWriter, ctx context.Context, acct account.Account, e entitlement.Entitlement, tx apple.Transaction, now time.Time) (entitlement.Entitlement, bool) {
	owner, bound, err := s.accountOfTransaction(ctx, tx)
	switch {
	case errors.Is(err, errNoAccount) || (err == nil && owner != acct.ID) || errors.Is(err, errAccountMismatch):
		fail(w, 409, "wrong_account", "this purchase belongs to another account")
		return e, false
	case err != nil:
		s.fault(w, "resolve account", err)
		return e, false
	}
	if !bound {
		if err := s.accounts.BindSub(ctx, acct.ID, s.SubKey(tx.OriginalTransactionID)); err != nil {
			if errors.Is(err, account.ErrBound) {
				fail(w, 409, "wrong_account", "this purchase belongs to another account")
				return e, false
			}
			s.fault(w, "bind subscription", err)
			return e, false
		}
	}
	prior := &e
	if e.OriginalTransactionID != tx.OriginalTransactionID {
		prior = nil // a new subscription chain starts its own history (a refund of the old one must not follow it)
	}
	updated := entitlement.FromTransaction(prior, acct.ID, tx, now)
	if err := s.store.Put(ctx, updated); err != nil {
		s.fault(w, "store put", err)
		return e, false
	}
	return updated, true
}

// MARK: account

type deviceView struct {
	ID         string              `json:"id"`
	State      account.DeviceState `json:"state"`
	Current    bool                `json:"current"`
	LabelEnc   string              `json:"labelEnc,omitempty"`
	EnrolledAt time.Time           `json:"enrolledAt"`
	LastSeenAt *time.Time          `json:"lastSeenAt,omitempty"`
	ExpiresAt  *time.Time          `json:"expiresAt,omitempty"`
}

type accountResponse struct {
	AccountID   string            `json:"accountId"`
	Epoch       int               `json:"epoch"`
	State       entitlement.State `json:"state"`
	PaidUntil   time.Time         `json:"paidUntil"`
	AutoRenew   bool              `json:"autoRenew"`
	DeleteAfter *time.Time        `json:"deleteAfter,omitempty"`
	Plan        planInfo          `json:"plan"`
	DeviceLimit int               `json:"deviceLimit"`
	Usage       quota.Usage       `json:"usage"`
	Library     libraryInfo       `json:"library"`
	Devices     []deviceView      `json:"devices"`
}

func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	ctx, now := r.Context(), s.cfg.Now()
	acct, e, ok := s.loadAccount(w, ctx, c.Acct)
	if !ok {
		return
	}
	pl, _ := s.planFor(e.ProductID)
	resp := accountResponse{AccountID: acct.ID, Epoch: acct.Epoch, State: e.StateAt(now), PaidUntil: e.ExpiresAt, AutoRenew: e.AutoRenew,
		Plan: planOf(pl), DeviceLimit: account.DeviceCap(pl.Name), Library: libraryOf(acct), Devices: []deviceView{}}
	if resp.State == entitlement.Lapsed {
		resp.DeleteAfter = &e.DeleteAfter
	}
	if s.sync != nil {
		if u, err := s.sync.Store.GetUsage(ctx, acct.ID); err == nil {
			resp.Usage = quota.Usage{StoredBytes: u.Committed, DownloadBytes: u.DownloadBytes, UploadGrants: u.UploadGrants}
		}
	}
	devices, err := s.accounts.ListDevices(ctx, acct.ID)
	if err != nil {
		s.fault(w, "list devices", err)
		return
	}
	for _, d := range devices {
		if d.State == account.DeviceRevoked || d.Expired(now) {
			continue
		}
		v := deviceView{ID: d.ID, State: d.State, Current: d.ID == c.Dev, LabelEnc: d.LabelEnc, EnrolledAt: d.EnrolledAt}
		if !d.LastSeenAt.IsZero() {
			t := d.LastSeenAt
			v.LastSeenAt = &t
		}
		if d.State == account.DevicePending && !d.PurgeAt.IsZero() {
			t := d.PurgeAt
			v.ExpiresAt = &t
		}
		resp.Devices = append(resp.Devices, v)
	}
	writeJSON(w, 200, resp)
}

func (s *Server) handleRevokeDevice(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	id := r.PathValue("id")
	if !devauth.ValidDeviceID(id) {
		fail(w, 400, "bad_request", "deviceId must be 32 lowercase hex characters")
		return
	}
	ctx, now := r.Context(), s.cfg.Now()
	if _, ok := s.requireDevice(w, ctx, c); !ok {
		return
	}
	err := s.accounts.UpdateDevice(ctx, id, func(d *account.Device) error {
		if d.AccountID != c.Acct {
			return account.ErrNotFound // another account's device is indistinguishable from no device
		}
		if d.State != account.DeviceRevoked {
			d.State, d.RevokedAt, d.EnrollChallenge, d.PurgeAt = account.DeviceRevoked, now, "", time.Time{}
		}
		return nil
	})
	switch {
	case errors.Is(err, account.ErrNotFound):
		fail(w, 404, "not_found", "no such device")
	case err != nil:
		s.fault(w, "revoke device", err)
	default:
		w.WriteHeader(204)
	}
}

// requireDevice is the check every state-changing route makes: the token's device must still be authorized.
// A revoked device keeps a valid token for up to an hour, but loses grant, commit, download, delete and every
// account route at once.
func (s *Server) requireDevice(w http.ResponseWriter, ctx context.Context, c auth.Claims) (account.Device, bool) {
	d, err := s.deviceOf(ctx, c)
	switch {
	case errors.Is(err, errDeviceRevoked):
		fail(w, 403, "device_revoked", "this device was removed from the account")
	case errors.Is(err, errDeviceNotAuthorized):
		fail(w, 403, "device_not_authorized", "this device is not authorized for this account")
	case err != nil:
		s.fault(w, "get device", err)
	default:
		return d, true
	}
	return d, false
}

var (
	errDeviceRevoked       = errors.New("device revoked")
	errDeviceNotAuthorized = errors.New("device not authorized")
	errNoAccount           = errors.New("no account")
)

func (s *Server) deviceOf(ctx context.Context, c auth.Claims) (account.Device, error) {
	d, found, err := s.accounts.GetDevice(ctx, c.Dev)
	switch {
	case err != nil:
		return d, err
	case !found || d.AccountID != c.Acct:
		return d, errDeviceNotAuthorized
	case d.State == account.DeviceRevoked:
		return d, errDeviceRevoked
	case d.State != account.DeviceAuthorized:
		return d, errDeviceNotAuthorized
	}
	return d, nil
}

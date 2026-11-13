// Package server is the HTTP control plane: it turns an Apple-verified purchase into a short-lived session,
// reports the account's state, and keeps the entitlement current from Apple's notifications. It never touches
// user data — that goes device ↔ Cloud Storage through URLs this service signs (next milestone).
package server

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math/rand/v2"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/quota"
	"github.com/mralexivy/whisperer/server/internal/retention"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

type Config struct {
	BundleID      string
	ProductPrefix string // product ids are <prefix><tier>.<monthly|yearly>; default quota.ProductPrefix
	AllowSandbox  bool   // accept Sandbox / Xcode transactions (TestFlight, development); off in production
	UIDSecret     []byte
	Now           func() time.Time
}

type Server struct {
	cfg      Config
	apple    *apple.Verifier
	store    entitlement.Store
	signer   *auth.Signer
	verifier *auth.Verifier
	sync     *syncplane.Service
	sweeper  *retention.Sweeper
	// authorizeSweep decides whether a request may trigger the retention sweep (Cloud Scheduler's OIDC token in production).
	authorizeSweep func(*http.Request) bool
	limiter        *limiter
	log            *slog.Logger
}

func New(cfg Config, a *apple.Verifier, store entitlement.Store, signer *auth.Signer, log *slog.Logger) *Server {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.ProductPrefix == "" {
		cfg.ProductPrefix = quota.ProductPrefix
	}
	if log == nil {
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Server{cfg: cfg, apple: a, store: store, signer: signer, verifier: auth.NewVerifier(signer.Public()),
		limiter: newLimiter(30, time.Minute), log: log}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]string{"ok": "true"}) })
	mux.HandleFunc("POST /v1/session", s.limited(s.handleSession))
	mux.HandleFunc("GET /v1/account", s.limited(s.authed(s.handleAccount)))
	mux.HandleFunc("POST /v1/apple/notifications", s.handleNotification)
	s.syncRoutes(mux)
	mux.HandleFunc("POST /internal/sweep", s.handleSweep)
	return mux
}

// UID is stable for one Apple subscription, the same on every Mac signed into that Apple ID, and cannot be
// turned back into the transaction id (or the Apple ID) without the server's secret.
func (s *Server) UID(originalTransactionID string) string {
	m := hmac.New(sha256.New, s.cfg.UIDSecret)
	m.Write([]byte(originalTransactionID))
	return hex.EncodeToString(m.Sum(nil)[:16])
}

// MARK: session

type sessionRequest struct {
	TransactionJWS string `json:"transactionJWS"`
	DeviceID       string `json:"deviceID"`
}

type planInfo struct {
	Name                 string `json:"name"`
	StoredBytes          int64  `json:"storedBytes"`
	MonthlyDownloadBytes int64  `json:"monthlyDownloadBytes"`
	MonthlyUploadGrants  int    `json:"monthlyUploadGrants"`
}

func planOf(p quota.Plan) planInfo {
	return planInfo{p.Name, p.StoredBytes, p.MonthlyDownloadBytes, p.MonthlyUploadGrants}
}

func (s *Server) planFor(productID string) (quota.Plan, bool) {
	return quota.ForProduct(s.cfg.ProductPrefix, productID)
}

type sessionResponse struct {
	Token      string            `json:"token"`
	ExpiresAt  time.Time         `json:"expiresAt"`
	State      entitlement.State `json:"state"`
	ReadOnly   bool              `json:"readOnly"`
	Plan       planInfo          `json:"plan"`
	Subscribed time.Time         `json:"paidUntil"`
}

func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	var req sessionRequest
	if !readJSON(w, r, &req) || req.TransactionJWS == "" || req.DeviceID == "" || len(req.DeviceID) > 64 {
		if !errors.Is(r.Context().Err(), context.Canceled) {
			fail(w, 400, "bad_request", "transactionJWS and deviceID are required")
		}
		return
	}
	tx, err := s.apple.Transaction(req.TransactionJWS)
	if err != nil {
		fail(w, 401, "invalid_transaction", "the purchase could not be verified")
		return
	}
	if code, msg := s.checkTransaction(tx); code != "" {
		fail(w, 403, code, msg)
		return
	}
	now := s.cfg.Now()
	uid := s.UID(tx.OriginalTransactionID)
	existing, found, err := s.store.Get(r.Context(), uid)
	if err != nil {
		s.fault(w, "store get", err)
		return
	}
	var prior *entitlement.Entitlement
	if found {
		prior = &existing
	}
	e := entitlement.FromTransaction(prior, uid, tx, now)
	state := e.StateAt(now)
	if state == entitlement.Deleted {
		fail(w, 402, "subscription_expired", "this subscription has ended and its data has been removed")
		return
	}
	if err := s.store.Put(r.Context(), e); err != nil {
		s.fault(w, "store put", err)
		return
	}
	readOnly := !e.CanWrite(now)
	token, claims := s.signer.Issue(uid, req.DeviceID, readOnly, now)
	if rand.IntN(20) == 0 {
		s.opportunisticSweep()
	}
	pl, _ := s.planFor(e.ProductID)
	writeJSON(w, 200, sessionResponse{Token: token, ExpiresAt: time.Unix(claims.Exp, 0).UTC(), State: state,
		ReadOnly: readOnly, Plan: planOf(pl), Subscribed: e.ExpiresAt})
}

// checkTransaction rejects a validly signed transaction that is not ours to serve.
func (s *Server) checkTransaction(tx apple.Transaction) (code, message string) {
	switch {
	case tx.BundleID != s.cfg.BundleID:
		return "wrong_app", "this purchase belongs to another app"
	case !s.hasPlan(tx.ProductID):
		return "wrong_product", "this purchase is not a Whisperer Cloud subscription"
	case tx.Type != "" && tx.Type != "Auto-Renewable Subscription":
		return "wrong_product", "this purchase is not a subscription"
	case tx.Environment != "Production" && !s.cfg.AllowSandbox:
		return "wrong_environment", "test purchases are not accepted here"
	}
	return "", ""
}

func (s *Server) hasPlan(productID string) bool { _, ok := s.planFor(productID); return ok }

// MARK: account

type ctxKey struct{}

func (s *Server) authed(next func(http.ResponseWriter, *http.Request, auth.Claims)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok {
			fail(w, 401, "unauthorized", "sign in again")
			return
		}
		claims, err := s.verifier.Verify(token, s.cfg.Now())
		if err != nil {
			fail(w, 401, "unauthorized", "the session has expired")
			return
		}
		next(w, r, claims)
	}
}

type accountResponse struct {
	State       entitlement.State `json:"state"`
	PaidUntil   time.Time         `json:"paidUntil"`
	AutoRenew   bool              `json:"autoRenew"`
	DeleteAfter *time.Time        `json:"deleteAfter,omitempty"`
	Plan        planInfo          `json:"plan"`
	Usage       quota.Usage       `json:"usage"`
}

func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	e, found, err := s.store.Get(r.Context(), c.UID)
	if err != nil {
		s.fault(w, "store get", err)
		return
	}
	if !found {
		fail(w, 404, "no_account", "no subscription found")
		return
	}
	now := s.cfg.Now()
	pl, _ := s.planFor(e.ProductID)
	resp := accountResponse{State: e.StateAt(now), PaidUntil: e.ExpiresAt, AutoRenew: e.AutoRenew, Plan: planOf(pl)}
	if resp.State == entitlement.Lapsed {
		resp.DeleteAfter = &e.DeleteAfter
	}
	writeJSON(w, 200, resp)
}

// MARK: apple notifications

func (s *Server) handleNotification(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SignedPayload string `json:"signedPayload"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	n, err := s.apple.Notification(req.SignedPayload)
	if err != nil {
		fail(w, 400, "invalid_notification", "not signed by Apple")
		return
	}
	if n.Data.BundleID != s.cfg.BundleID || (n.Data.Environment != "Production" && !s.cfg.AllowSandbox) {
		writeJSON(w, 200, map[string]string{"ignored": "not for this service"}) // 2xx: Apple must not retry it
		return
	}
	var tx *apple.Transaction
	if n.Data.SignedTransactionInfo != "" {
		t, err := s.apple.Transaction(n.Data.SignedTransactionInfo)
		if err != nil {
			fail(w, 400, "invalid_notification", "inner transaction not signed by Apple")
			return
		}
		tx = &t
	}
	var renewal *apple.RenewalInfo
	if n.Data.SignedRenewalInfo != "" {
		if ri, err := s.apple.RenewalInfo(n.Data.SignedRenewalInfo); err == nil {
			renewal = &ri
		}
	}
	if tx == nil {
		writeJSON(w, 200, map[string]string{"ignored": "no transaction"}) // e.g. TEST pings
		return
	}
	if code, _ := s.checkTransaction(*tx); code == "wrong_app" || code == "wrong_product" {
		writeJSON(w, 200, map[string]string{"ignored": code})
		return
	}
	now := s.cfg.Now()
	uid := s.UID(tx.OriginalTransactionID)
	existing, found, err := s.store.Get(r.Context(), uid)
	if err != nil {
		s.fault(w, "store get", err)
		return
	}
	base := entitlement.Entitlement{UID: uid, OriginalTransactionID: tx.OriginalTransactionID}
	if found {
		base = existing
	}
	updated, changed := entitlement.ApplyNotification(base, n, tx, renewal, now)
	if changed {
		if err := s.store.Put(r.Context(), updated); err != nil {
			s.fault(w, "store put", err)
			return
		}
	}
	writeJSON(w, 200, map[string]any{"applied": changed})
}

func (s *Server) fault(w http.ResponseWriter, what string, err error) {
	s.log.Error(what, "err", err)
	fail(w, 500, "internal", "something went wrong; try again")
}

func readJSON(w http.ResponseWriter, r *http.Request, into any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	if err := json.NewDecoder(r.Body).Decode(into); err != nil {
		fail(w, 400, "bad_request", "the request body is not valid JSON")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]string{"error": code, "message": message})
}

// limiter is a small per-client token bucket. The service runs at most two instances, so an in-process
// limit is an honest ceiling, not a global one — enough to blunt a runaway client without any shared state.
type limiter struct {
	mu      sync.Mutex
	max     int
	window  time.Duration
	buckets map[string][]time.Time
}

func newLimiter(max int, window time.Duration) *limiter {
	return &limiter{max: max, window: window, buckets: map[string][]time.Time{}}
}

func (l *limiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := now.Add(-l.window)
	kept := l.buckets[key][:0]
	for _, t := range l.buckets[key] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= l.max {
		l.buckets[key] = kept
		return false
	}
	l.buckets[key] = append(kept, now)
	if len(l.buckets) > 10_000 { // bounded memory
		for k := range l.buckets {
			delete(l.buckets, k)
			break
		}
	}
	return true
}

func (s *Server) limited(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.limiter.allow(clientIP(r), s.cfg.Now()) {
			w.Header().Set("Retry-After", "60")
			fail(w, 429, "rate_limited", "too many requests; try again in a minute")
			return
		}
		next(w, r)
	}
}

func clientIP(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		return strings.TrimSpace(strings.Split(fwd, ",")[0])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

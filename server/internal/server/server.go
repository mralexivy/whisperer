// Package server is the HTTP control plane: it turns an Apple-verified purchase plus a device key into an
// account and a short-lived session, reports the account's state, and keeps the entitlement current from
// Apple's notifications. It never touches user data — that goes device ↔ Cloud Storage through URLs this
// service signs. Identity model: docs/exec-plans/cloud-sync-implementation.md section 2.
package server

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/devauth"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/quota"
	"github.com/mralexivy/whisperer/server/internal/retention"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

type Config struct {
	BundleID      string
	ProductPrefix string // product ids are <prefix><tier>.<monthly|yearly>; default quota.ProductPrefix
	AllowSandbox  bool   // accept Sandbox / Xcode transactions (TestFlight, development); off in production
	// UIDSecret keys the subscription mapping (subKey) and, domain-separated, the stateless nonces.
	UIDSecret []byte
	// RateLimit is requests per minute per client address; default 30.
	RateLimit int
	Now       func() time.Time
}

type Server struct {
	cfg      Config
	apple    *apple.Verifier
	store    entitlement.Store
	accounts account.Store
	signer   *auth.Signer
	verifier *auth.Verifier
	chall    *devauth.Challenger
	sync     *syncplane.Service
	sweeper  *retention.Sweeper
	limiter  *limiter
	// proofFails counts failed key proofs (5 per device and 10 per account per hour).
	proofFails *failCounter
	log        *slog.Logger
}

func New(cfg Config, a *apple.Verifier, store entitlement.Store, accounts account.Store, signer *auth.Signer, log *slog.Logger) *Server {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.ProductPrefix == "" {
		cfg.ProductPrefix = quota.ProductPrefix
	}
	if cfg.RateLimit == 0 {
		cfg.RateLimit = 30
	}
	if log == nil {
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Server{cfg: cfg, apple: a, store: store, accounts: accounts, signer: signer, verifier: auth.NewVerifier(signer.Public()),
		chall: devauth.NewChallenger(cfg.UIDSecret), limiter: newLimiter(cfg.RateLimit, time.Minute),
		proofFails: newFailCounter(time.Hour), log: log}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	health := func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]string{"ok": "true"}) }
	mux.HandleFunc("GET /healthz", health)
	// Cloud Run's front end reserves /healthz and answers it itself with a 404, so the service is probed here.
	mux.HandleFunc("GET /v1/health", health)
	s.identityRoutes(mux)
	s.libraryRoutes(mux)
	mux.HandleFunc("POST /v1/apple/notifications", s.handleNotification)
	s.syncRoutes(mux)
	return mux
}

// SubKey names one Apple subscription in the mapping collection: stable on every Mac signed into that Apple
// ID, and unusable to recover the transaction id without the server's secret. It is never an account id.
func (s *Server) SubKey(originalTransactionID string) string {
	m := hmac.New(sha256.New, s.cfg.UIDSecret)
	m.Write([]byte(originalTransactionID))
	return hex.EncodeToString(m.Sum(nil))
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

// verifiedTransaction checks Apple's signature, then that the purchase is ours. A valid transaction proves an
// entitlement — it never, by itself, grants access to data.
func (s *Server) verifiedTransaction(w http.ResponseWriter, jws string) (apple.Transaction, bool) {
	if jws == "" {
		fail(w, 400, "bad_request", "transactionJWS is required")
		return apple.Transaction{}, false
	}
	tx, err := s.apple.Transaction(jws)
	if err != nil {
		fail(w, 401, "invalid_transaction", "the purchase could not be verified")
		return tx, false
	}
	if code, msg := s.checkTransaction(tx); code != "" {
		fail(w, 403, code, msg)
		return tx, false
	}
	return tx, true
}

// MARK: session token

type ctxKey struct{}

func (s *Server) authed(next func(http.ResponseWriter, *http.Request, auth.Claims)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := s.claimsFrom(w, r.Header.Get("Authorization"))
		if !ok {
			return
		}
		next(w, r, claims)
	}
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
	// A notification updates an account that already exists; it never creates one (an account needs a device
	// key) and never binds a new subscription to an account (that needs an enrolled device — see handleSession).
	acctID, found, err := s.accounts.ResolveSub(r.Context(), s.SubKey(tx.OriginalTransactionID))
	if err != nil {
		s.fault(w, "resolve subscription", err)
		return
	}
	if !found {
		writeJSON(w, 200, map[string]string{"ignored": "unbound_subscription"})
		return
	}
	existing, found, err := s.store.Get(r.Context(), acctID)
	if err != nil {
		s.fault(w, "store get", err)
		return
	}
	if !found || existing.OriginalTransactionID != tx.OriginalTransactionID {
		// An older subscription of the same account (superseded by a newer one): nothing to update.
		writeJSON(w, 200, map[string]string{"ignored": "superseded_subscription"})
		return
	}
	updated, changed := entitlement.ApplyNotification(existing, n, tx, renewal, s.cfg.Now())
	if changed {
		if err := s.store.Put(r.Context(), updated); err != nil {
			s.fault(w, "store put", err)
			return
		}
	}
	s.sweepNow(r.Context())
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

// failCounter counts failures (not requests) inside a window: a correct request is never penalised, a run of
// wrong key proofs is stopped.
type failCounter struct {
	mu     sync.Mutex
	window time.Duration
	events map[string][]time.Time
}

func newFailCounter(window time.Duration) *failCounter {
	return &failCounter{window: window, events: map[string][]time.Time{}}
}

func (f *failCounter) recent(key string, now time.Time) int {
	cutoff := now.Add(-f.window)
	kept := f.events[key][:0]
	for _, t := range f.events[key] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	f.events[key] = kept
	return len(kept)
}

// exceeded reports whether `key` already has `max` failures in the window.
func (f *failCounter) exceeded(key string, max int, now time.Time) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.recent(key, now) >= max
}

func (f *failCounter) add(key string, now time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.recent(key, now)
	f.events[key] = append(f.events[key], now)
	if len(f.events) > 10_000 {
		for k := range f.events {
			delete(f.events, k)
			break
		}
	}
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

func trimBearer(header string) (string, bool) { return strings.CutPrefix(header, "Bearer ") }

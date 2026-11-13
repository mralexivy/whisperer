// Command api is the Whisperer Cloud control plane (see docs/exec-plans/cloud-sync.md).
//
// Configuration is environment variables; secrets arrive as env vars mounted from Secret Manager:
//
//	PORT                     listen port (Cloud Run sets it)
//	BUNDLE_ID                the app's bundle id (default com.ivy.whisperer)
//	PRODUCT_PREFIX           product ids are <prefix><tier>.<monthly|yearly> (default com.ivy.whisperer.cloud.)
//	ALLOW_SANDBOX            "1" accepts Sandbox/Xcode purchases (TestFlight, development)
//	UID_SECRET               HMAC secret that turns an Apple subscription into an opaque user id
//	SESSION_SIGNING_KEY      base64 32-byte Ed25519 seed for the 1-hour session tokens
//	ENV                      "production" refuses to start without the secrets and the GCP settings below
//	GCP_PROJECT              Google Cloud project; with it the service uses Firestore + Cloud Storage (else in-memory, dev only)
//	DATA_BUCKET              Cloud Storage bucket for encrypted user data (required with GCP_PROJECT)
//	FIRESTORE_ROOT           document root, "envs/prod" (default) or "envs/sandbox"
//	BUCKET_ROOT              object prefix, "whisperer" (default) or "whisperer-sandbox"
//	APPLE_IAP_KEY            the In-App Purchase key (.p8 PEM) — from Secret Manager
//	APPLE_KEY_ID, APPLE_ISSUER_ID   that key's ids; with the key they enable the retention sweep
//	SWEEP_DRY_RUN            the sweep only reports what it would delete, until set to "0" (default: dry run)
//
// With no secrets and ENV unset the service runs for local development with ephemeral keys and an
// in-memory store — nothing is persisted.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/quota"
	"github.com/mralexivy/whisperer/server/internal/server"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	production := os.Getenv("ENV") == "production"

	uidSecret := []byte(os.Getenv("UID_SECRET"))
	var signer *auth.Signer
	if seed := os.Getenv("SESSION_SIGNING_KEY"); seed != "" {
		raw, err := base64.StdEncoding.DecodeString(seed)
		if err != nil || len(raw) != ed25519.SeedSize {
			return errors.New("SESSION_SIGNING_KEY must be a base64 32-byte Ed25519 seed")
		}
		signer = auth.NewSigner(ed25519.NewKeyFromSeed(raw), "k1")
	}
	if production && (len(uidSecret) < 32 || signer == nil) {
		return errors.New("production needs UID_SECRET (≥ 32 bytes) and SESSION_SIGNING_KEY")
	}
	if signer == nil {
		_, priv, _ := ed25519.GenerateKey(rand.Reader)
		signer = auth.NewSigner(priv, "dev")
		log.Warn("no SESSION_SIGNING_KEY: using an ephemeral key (development only)")
	}
	if len(uidSecret) == 0 {
		uidSecret = []byte("development-only-secret")
		log.Warn("no UID_SECRET: using a development secret")
	}

	verifier, err := apple.NewVerifier()
	if err != nil {
		return err
	}
	log.Info("trusting Apple Root CA - G3", "sha256", apple.RootFingerprint())

	backends, err := newBackends(context.Background(), log, production)
	if err != nil {
		return err
	}
	store := backends.entitlements

	srv := server.New(server.Config{
		BundleID: env("BUNDLE_ID", "com.ivy.whisperer"), ProductPrefix: env("PRODUCT_PREFIX", quota.ProductPrefix),
		AllowSandbox: os.Getenv("ALLOW_SANDBOX") == "1", UIDSecret: uidSecret,
	}, verifier, store, signer, log)
	srv.WithSync(&syncplane.Service{Store: backends.sync, Blobs: backends.blobs, Root: backends.bucketRoot})
	if sweeper := backends.sweeper(verifier, log); sweeper != nil {
		srv.WithSweeper(sweeper)
	}

	httpSrv := &http.Server{
		Addr: ":" + env("PORT", "8080"), Handler: srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdown)
	}()
	log.Info("listening", "addr", httpSrv.Addr, "production", production)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

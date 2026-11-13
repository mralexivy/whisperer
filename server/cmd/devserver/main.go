// Command devserver is the REAL Whisperer Cloud control plane (server.New with in-memory stores) wired to a
// fake Cloud Storage and a private test "Apple", for end-to-end tests of the Mac client. It is a development
// tool: it listens on 127.0.0.1 only, refuses to start when it looks like a deployment, and is not built by
// the Dockerfile. Run:
//
//	go run ./cmd/devserver -addr 127.0.0.1:8787
//
// Endpoints on top of the real /v1 API:
//
//	POST /dev/mint-transaction  {productId, originalTransactionId?, appAccountToken?, expiresInSeconds?, environment?, revoked?}
//	                            -> {jws, originalTransactionId, expiresDate}   (signed by the test Apple root)
//	POST /dev/advance-clock     {seconds}   moves the server's clock (entitlements, nonces, signed URLs) forward
//	POST /dev/fault             {dropChunks:{after,count,persist}, dropGets:{after,count}, errorNext:{code,count}}
//	GET  /dev/stats             what the storage data plane has seen (session starts, chunk PUTs, status queries…)
//	GET  /dev/objects?prefix=       stored object names and sizes (what the cloud provider can see)
//	GET  /dev/object?name=          an object's raw bytes;  PUT /dev/object?name=  replaces them (tamper / restore)
//	POST /dev/grep {marker}         which stored objects contain that plaintext (must always be none)
//	POST /dev/set-plan {tier,storedBytes,monthlyDownloadBytes,monthlyUploadGrants}   rewrite a tier's limits
//	/storage/...                the fake Cloud Storage the signed URLs point to
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/devstore"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/server"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8787", "listen address (loopback only)")
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(*addr, log); err != nil {
		fmt.Fprintln(os.Stderr, "devserver:", err)
		os.Exit(1)
	}
}

// refuse returns why this process must not run as a dev server, or "". It is deliberately paranoid: this binary
// trusts a throw-away Apple root and keeps everything in memory.
func refuse(env func(string) string, addr string) string {
	switch {
	case env("ENV") == "production":
		return "ENV=production: the dev server trusts a fake Apple root and must never run in production"
	case env("K_SERVICE") != "" || env("K_REVISION") != "":
		return "this looks like Cloud Run (K_SERVICE is set): the dev server must never be deployed"
	case env("GCP_PROJECT") != "" || env("DATA_BUCKET") != "":
		return "GCP_PROJECT/DATA_BUCKET are set: the dev server only uses in-memory stores and a fake bucket"
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return "bad -addr: " + err.Error()
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return "the dev server listens on loopback only (127.0.0.1 or ::1)"
	}
	return ""
}

func run(addr string, log *slog.Logger) error {
	if why := refuse(os.Getenv, addr); why != "" {
		return errors.New("refusing to start: " + why)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	h, bucket := build("http://"+ln.Addr().String(), log)
	httpSrv := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdown)
	}()
	_ = bucket
	fmt.Printf("devserver listening on http://%s (TEST Apple root, in-memory stores, fake storage) — development only\n", ln.Addr())
	if err := httpSrv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// build wires the real server to the fake storage and returns the combined handler. base is the externally
// visible origin that signed URLs must point to.
func build(base string, log *slog.Logger) (http.Handler, *devstore.Bucket) {
	clk := &clock{}
	bucket := devstore.New(base, clk.Now)
	dev := newDevAPI(clk, bucket)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	srv := server.New(server.Config{
		BundleID: "com.ivy.whisperer", AllowSandbox: true, UIDSecret: []byte("devserver-secret-not-for-production"),
		RateLimit: 1_000_000, Now: clk.Now,
	}, dev.apple.Verifier, entitlement.NewMemory(), account.NewMemory(), auth.NewSigner(priv, "dev"), log)
	dev.apple.Verifier.Now = clk.Now
	srv.WithSync(&syncplane.Service{Store: syncplane.NewMemoryStore(), Blobs: bucket, Root: "whisperer-dev", Now: clk.Now})

	mux := http.NewServeMux()
	mux.Handle("/dev/", dev.handler())
	mux.Handle("/storage/", bucket.Handler())
	mux.Handle("/", srv.Handler())
	return mux, bucket
}

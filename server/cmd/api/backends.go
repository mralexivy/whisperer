package main

import (
	"context"
	"errors"
	"log/slog"
	"os"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/gcp"
	"github.com/mralexivy/whisperer/server/internal/retention"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// backends are the stores the service runs on: Firestore + Cloud Storage in the cloud, in-memory fakes for
// local development.
type backends struct {
	entitlements entitlement.Store
	sync         syncplane.Store
	blobs        syncplane.Blobs
	bucketRoot   string
}

func newBackends(ctx context.Context, log *slog.Logger, production bool) (*backends, error) {
	project := os.Getenv("GCP_PROJECT")
	if project == "" {
		if production {
			return nil, errors.New("production needs GCP_PROJECT and DATA_BUCKET")
		}
		log.Warn("no GCP_PROJECT: using in-memory stores (development only; state is lost on restart)")
		return &backends{entitlements: entitlement.NewMemory(), sync: syncplane.NewMemoryStore(), blobs: syncplane.NewMemoryBlobs(), bucketRoot: env("BUCKET_ROOT", "whisperer")}, nil
	}
	bucket := os.Getenv("DATA_BUCKET")
	if bucket == "" {
		return nil, errors.New("DATA_BUCKET is required with GCP_PROJECT")
	}
	tokens := &gcp.MetadataTokens{}
	fs := &gcp.Firestore{Project: project, Root: env("FIRESTORE_ROOT", "envs/prod"), Tokens: tokens}
	if _, err := tokens.Token(ctx); err != nil {
		return nil, errors.New("cannot get Google credentials from the metadata server: " + err.Error())
	}
	log.Info("using Firestore and Cloud Storage", "project", project, "bucket", bucket, "firestoreRoot", fs.Root)
	return &backends{
		entitlements: gcp.EntitlementStore{FS: fs},
		sync:         gcp.SyncStore{FS: fs},
		blobs:        &gcp.Storage{Bucket: bucket, Tokens: tokens},
		bucketRoot:   env("BUCKET_ROOT", "whisperer"),
	}, nil
}

// sweeper builds the retention sweep when the Apple key is configured. Without the key nothing can ask Apple
// before deleting, so there is no sweep and nothing is ever deleted — the safe default.
func (b *backends) sweeper(verifier *apple.Verifier, log *slog.Logger) *retention.Sweeper {
	pem := os.Getenv("APPLE_IAP_KEY")
	if pem == "" {
		log.Warn("no APPLE_IAP_KEY: the retention sweep is off and no data will be deleted")
		return nil
	}
	key, err := apple.ParseP8([]byte(pem))
	if err != nil {
		log.Error("APPLE_IAP_KEY is unusable: the retention sweep is off", "err", err)
		return nil
	}
	api := &apple.ServerAPI{KeyID: os.Getenv("APPLE_KEY_ID"), IssuerID: os.Getenv("APPLE_ISSUER_ID"), BundleID: env("BUNDLE_ID", "com.ivy.whisperer"), Key: key, Verifier: verifier}
	dry := os.Getenv("SWEEP_DRY_RUN") != "0"
	if dry {
		log.Warn("retention sweep is in DRY-RUN mode: it reports what it would delete and deletes nothing (set SWEEP_DRY_RUN=0 to enable)")
	}
	return &retention.Sweeper{
		Entitlements: b.entitlements, Apple: retention.AppleServerAPI{API: api}, Blobs: b.blobs, Root: b.bucketRoot, Log: log, DryRun: dry,
		Epoch: func(ctx context.Context, uid string) (int, error) {
			h, err := b.sync.GetHeads(ctx, uid)
			return h.Epoch, err
		},
	}
}

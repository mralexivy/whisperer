# Whisperer Cloud server

The control plane for Whisperer Cloud (paid, end-to-end encrypted history sync). Design, costs and the
rules this service keeps: [`docs/exec-plans/cloud-sync.md`](../docs/exec-plans/cloud-sync.md) — read
**Lean rules** first. In short: one small Go binary on Cloud Run, standard library only, scale-to-zero;
it verifies Apple purchases, keeps entitlements, meters quotas and (next milestone) signs Cloud Storage
URLs. It never sees user data.

```
go test ./...                     # all unit + HTTP tests, no network, no Google
go test -race ./...
PORT=8080 go run ./cmd/api        # local dev: in-memory store, ephemeral keys, Sandbox purchases with ALLOW_SANDBOX=1
```

| Route | |
|---|---|
| `POST /v1/session` | StoreKit transaction JWS + device id → 1-hour session token (read-only if lapsed) |
| `GET /v1/account` | state, paid-until, plan limits |
| `POST /v1/apple/notifications` | App Store Server Notifications V2 (Apple-signed) |
| `GET /healthz` | |

Packages: `apple` (JWS + Apple Root CA G3, embedded), `entitlement` (the state machine: active → grace →
lapsed → deleted), `auth` (EdDSA session tokens), `quota` (plan limits), `server` (HTTP), `testkit`
(a private "Apple" for tests). Nothing in `internal/testkit` ships in the binary.

## Running on Google Cloud (Cloud Run + Firestore + Cloud Storage + Secret Manager)

Nothing else is used. The service reads its configuration from environment variables (secrets are mounted from
Secret Manager); see the header of `cmd/api/main.go` for the full list.

| Variable | Purpose |
|---|---|
| `GCP_PROJECT`, `DATA_BUCKET` | switch from in-memory fakes to Firestore + Cloud Storage |
| `FIRESTORE_ROOT`, `BUCKET_ROOT` | `envs/prod` + `whisperer`, or `envs/sandbox` + `whisperer-sandbox` for a sandbox deployment |
| `UID_SECRET`, `SESSION_SIGNING_KEY` | secrets |
| `APPLE_IAP_KEY`, `APPLE_KEY_ID`, `APPLE_ISSUER_ID` | App Store Server API; without them the retention sweep is off and **nothing is ever deleted** |
| `SWEEP_DRY_RUN` | the sweep only reports until set to `0` |

The runtime service account needs: `roles/datastore.user`, `roles/storage.objectAdmin` on the bucket,
`roles/iam.serviceAccountTokenCreator` on itself (to sign URLs through IAM Credentials — there is no key file),
and `roles/secretmanager.secretAccessor` on its secrets. No Cloud Scheduler: the retention sweep runs inside
Apple notifications and sessions.

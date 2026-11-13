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

# Whisperer Cloud — paid, end-to-end encrypted history sync

Status: **plan, nothing built** (2026-11-12). Scope: a subscription (StoreKit) that keeps a user's
history — dictations, meetings, recordings, dictionary, records — in sync across their Macs, on
Google Cloud, with a small Go service in this repo. Builds on `HistoryArchive` (the export/import
format and merge rules already shipped).

## Provisioned (2026-11-13, project `whisperer-491716`, region `us-central1`)

Created by hand with `gcloud`, nothing deployed and nothing billing beyond pennies yet:
- APIs: Cloud Run, Cloud Build, Artifact Registry, Secret Manager, IAM (+ Credentials), Firestore, Scheduler, STS, Resource Manager, Billing Budgets.
- Bucket `gs://whisperer-491716-user-data` — private (public access prevention enforced, uniform access), soft delete off (a deletion is a deletion), lifecycle: `*.pack` audio Standard → Nearline after 30 days.
- Service account `whisperer-api@whisperer-491716.iam.gserviceaccount.com` (Cloud Run runtime): `storage.objectAdmin` on that bucket only, `datastore.user`, and `serviceAccountTokenCreator` on itself (for signed URLs). No key file exists or should.
- Artifact Registry Docker repo `whisperer`; Firestore `(default)`, native mode.
- Budget "Whisperer Cloud" on billing account `014CFB-C8ABCF-52C29A` (currency **ILS**): 700 ILS with alerts at 5 % / 25 % / 100 % ≈ $10 / $50 / $200.
- Still to do: Workload Identity Federation for GitHub deploys, the Go service, Cloud Run, Secret Manager entries (Apple keys), the App Store Connect subscription group and products. App Store Connect has no in-app purchases yet (the Pro Pack in the app does not exist there either); **do not release — target is the next version.**

## 0. Recommendation in one page

| Decision | Choice | Why |
|---|---|---|
| Data plane | **Client ↔ GCS directly.** The server never touches a byte of user data | Bandwidth and CPU are the cost of a sync service; a control plane that only mints credentials costs ~nothing |
| Control plane | **One Go binary on Cloud Run**, scale-to-zero, ~15 MB image | Same IAM as GCS (downscoped tokens, no key files), Go static binary cold-starts in ~0.1–0.3 s, pay only while a request runs. Cloud Functions (2nd gen) *is* Cloud Run; Lambda is the same price class — compute is noise either way (§3) |
| Small server state | **Firestore (Native)**: entitlements + usage counters | Free tier (1 GiB, 50k reads / 20k writes a day) covers the first ~10k payers; no database to run |
| Identity | **No accounts.** The user is the Apple subscription (`originalTransactionId`), proven by StoreKit's signed transaction | Keeps "there is no Whisperer account" (App Review 4.8 does not apply), works on every Mac signed into the same Apple ID, nothing to log in to |
| Privacy | **End-to-end encrypted** with a key in iCloud Keychain | Voice recordings and meeting transcripts are the most sensitive data we hold. We cannot read it, so a breach, a subpoena or a rogue engineer exposes nothing. It is also the headline feature |
| Pricing | **$1.99/mo or $14.99/yr**, one tier, 10 GB + 5 GB/mo restore traffic | ≥ 90 % gross margin for a typical user after Apple's 15 %; 57 % / 31 % in the worst case of a maxed-out user (§5) |
| The real cost risk | **Egress** (downloads), not storage or compute | $0.12/GB: restoring 10 GB to a new Mac costs more than the user pays in a month. Controlled by lazy audio download and a monthly restore allowance (§5.3) |
| Monorepo | `server/` (Go module) next to the app; deploy with Cloud Build / GitHub Actions + Workload Identity Federation | One repo, one review, API and client change together |

Fixed cost at zero users: **about $1.50 a month** (a domain, Secret Manager, an image). At 10,000
typical payers: revenue $19.9k, Apple $3.0k, cloud **$0.8k**, profit ~$16k/month (§5).

## 1. What exists today

- App: StoreKit 2, one non-consumable `com.ivy.whisperer.propack` (Pro, one-time $14.99).
  `StoreManager`, `ReceiptValidator` (client-side only). App Store build is sandboxed
  (`user-selected.read-write`, network client). There is no server.
- Data: Core Data `history.sqlite` (dictations, meetings, dictionary), Opus recordings in
  `Recordings/` and `Recordings/Meetings/`, Ask-AI threads in `Meetings/<id>-chat.json`.
  `HistoryArchive` already serialises every row generically, merges by id, and moves audio.
- GCP project **`whisperer-491716`** (project number 933733507703): billing enabled, Cloud Storage
  API on, **zero buckets**; Cloud Run, Cloud Functions, Firestore, Cloud Build, Artifact Registry,
  Secret Manager, IAM Credentials, Scheduler are **not enabled**. Nothing in it to preserve or break.
  (Checked read-only with `gcloud`; nothing was changed.)
- Measured library sizes on this Mac: 62 dictations + 8 meetings = 2.5 MB. Opus is ~2 KB/s
  (≈ 7 MB per hour of meeting). A heavy user is single-digit GB per year, not hundreds.

## 2. Architecture

```
                        ┌──────────────────────── Apple ────────────────────────┐
                        │  StoreKit (device)        App Store Server Notifications V2 │
                        └───────┬───────────────────────────────┬────────────────┘
        signed transaction (JWS)│                               │ signed webhooks (JWS)
                                ▼                               ▼
 ┌────────┐  POST /v1/session  ┌─────────────────────────────────────────┐   ┌───────────┐
 │ Mac(s) │───────────────────▶│  whisperer-api  (Go, Cloud Run, min 0)  │──▶│ Firestore │
 │        │◀─── short JWT ─────│  verify JWS · entitlement · quotas ·    │   │ entitle-  │
 │ Sync   │  POST /v1/sync/…   │  mint credentials                       │   │ ments,    │
 │ Engine │◀─ signed PUT URLs, └──────────────────┬──────────────────────┘   │ counters  │
 │        │   downscoped read token               │ IAM Credentials / STS     └───────────┘
 │        │                                        ▼
 │        │══ encrypted objects (PUT / GET) ══▶ ┌────────────────────┐
 └────────┘      direct, resumable, HTTPS       │ GCS bucket         │  Nearline after 30 d
                                                │ u/<uid>/…          │  (lifecycle rule)
                                                └────────────────────┘
```

### 2.1 API (control plane, all JSON, all small)

| Endpoint | Does | Notes |
|---|---|---|
| `POST /v1/session` | Device sends a fresh StoreKit transaction JWS (+ device public key). Server verifies the chain to Apple's root, checks product + not revoked/expired, upserts the entitlement, returns a 1 h JWT bound to `uid` and the device | `uid = HMAC(serverSecret, originalTransactionId)` — stable across the user's Macs, not reversible to the Apple ID |
| `POST /v1/sync/upload` | Body: object names + sizes. Returns V4 signed PUT URLs with `x-goog-content-length-range` (size enforced by GCS) | Server adds the sizes to the user's usage counter; refuses over quota (402-style error the UI can explain) |
| `POST /v1/sync/download-token` | Returns a 1 h **downscoped OAuth token** (Credential Access Boundary) readable on `u/<uid>/` only | Rate-limited (a few a day); counts toward the restore allowance |
| `GET /v1/account` | Plan, bytes used, restore allowance left, devices, grace/expiry state | Drives the Settings page |
| `DELETE /v1/account/data` | Deletes the user's prefix and counters now | "Delete my cloud data" (and GDPR erasure) |
| `POST /v1/apple/notifications` | App Store Server Notifications V2: `SUBSCRIBED`, `DID_RENEW`, `EXPIRED`, `GRACE_PERIOD_EXPIRED`, `REFUND`, `REVOKE`, `DID_CHANGE_RENEWAL_STATUS` | JWS-verified; idempotent on `notificationUUID`; this is the source of truth for state between app launches |
| `GET /healthz` | For Cloud Run | |

Uploads use signed URLs (the server must meter what is stored); downloads use downscoped tokens
(no per-object signing, resumable, one mint per hour of use). The server holds **no key file**:
it runs as a service account with `roles/iam.serviceAccountTokenCreator` on itself and
`roles/storage.objectAdmin` on the bucket only.

### 2.2 Entitlement state machine

`active → grace (billing retry, Apple's grace period) → lapsed (read-only 60 d) → deleted`
- active / grace: read + write.
- lapsed: read and export only — a user who stops paying can always take their data home.
- Day 60 after lapse: a daily Cloud Run Job (Scheduler, free tier) deletes the prefix.
  Re-subscribing before then restores write access with nothing lost.
- Refund / revoke: immediately lapsed.

### 2.3 Where the Go code goes

```
server/
  cmd/api/main.go            // wiring, graceful shutdown, PORT
  internal/apple/            // JWS (x5c → Apple root) verification, ASSN V2 decoding
  internal/auth/             // session JWT (Ed25519), device binding
  internal/entitlement/      // Firestore store + state machine (interface; in-memory fake for tests)
  internal/gcs/              // signed URLs, downscoped tokens, prefix delete (interface; fake-gcs-server in tests)
  internal/quota/            // counters, allowance, rate limits
  api/openapi.yaml           // the contract; the Swift client is checked against it
  Dockerfile                 // distroless static, ~15 MB
  deploy/                    // gcloud / Terraform: bucket, lifecycle, service account, budgets
```
Apple publishes server libraries for Swift/Java/Node/Python; for Go either a maintained community
package or ~150 lines of our own (decode JWS, verify `x5c` against the Apple root, check
bundle id / environment / signed date). The decision is part of milestone 1.

## 3. Why Go on Cloud Run (and the comparison asked for)

| | Cloud Run (Go container) | Cloud Run functions (2nd gen) | AWS Lambda (Go) |
|---|---|---|---|
| Billing | CPU/memory while a request runs + $0.40/M requests, free 2M req / 180k vCPU-s / 360k GiB-s a month | Same (it is Cloud Run underneath) | $0.20/M + GB-s, free 1M |
| 10 M requests/mo, 30 ms | ≈ $10 with 0.25 vCPU; ≈ $29 at 1 vCPU (my model) | same | ≈ $6 |
| Cold start (Go, static) | ~0.1–0.3 s | similar | ~0.1 s |
| Same-cloud IAM with GCS | yes — no keys, downscoped tokens | yes | no (cross-cloud) |
| Local dev / test | `docker run` / `go run` | functions framework | SAM / emulators |
| Concurrency | 80 requests share one instance — cheaper under load | per-instance | one request per instance |

Compute is not where money goes: at 10 k payers the control plane is ~7 M requests a month,
**under $10**. Pick on operations: Cloud Run, because it is the same cloud as the data and one
container is all there is to deploy. Cloud Run functions would work identically with less to
configure but no better price; Lambda is cheaper per request but puts the control plane in a
different cloud than the bucket for a saving of a few dollars.

Cheaper storage exists (Cloudflare R2 has no egress charge). Since egress is the one line that
can hurt (§5.3), the storage layer is behind a small `blob` interface so a second backend stays
possible. The plan does **not** assume it: GCS was the stated preference.

Settings that keep it cheap: min instances **0**, max instances **5** (a cost ceiling and an abuse
cap), 256 MiB, 0.25–1 vCPU, request-based billing, one region next to the bucket, Cloud Logging at
the default free allotment (log lines, not payloads), a **budget alert** at $10 / $50 / $200.

## 4. Sync design (client)

### 4.1 What is synchronised and how it is stored

- Unit: the same generic row (`HistoryArchive.encodeRow`) plus an `id`, a `deviceID`,
  `lastModifiedAt` and a `deleted` tombstone. Merge rule is the import rule already tested: by id,
  newest `lastModifiedAt` wins; tombstones kept 90 days.
- Objects in the bucket (all encrypted, names carry no content):
  - `u/<uid>/log/<device>/<seq>.seg` — an **append-only segment per device**: a batch of rows.
    Each device writes only its own log, so there is no multi-writer conflict and no
    read-modify-write on a shared file.
  - `u/<uid>/audio/<hash>.pack` — recordings, packed (≤ 4 MB for dictations; a meeting is one
    object). One object per recording would make *operations* cost more than the storage.
  - `u/<uid>/head/<device>.json` — that device's latest `seq` (one tiny read per device to discover news).
- Batching is a cost rule, not an optimisation: Class A operations are $0.005 per 1,000, so
  100 uploads a day for a month is $0.015 — as much as the storage. Batches go out every 5 minutes
  or 50 rows, whichever first, so a user stays under ~1,500 write operations a month.
- Initial upload and "new Mac" restore reuse the **archive parts** machinery: a resumable,
  size-capped sequence of parts. Restore is text first (rows, a few MB, instant), audio **on
  demand** when a recording is played or the user chooses "Download all recordings".

### 4.2 Engine

`SyncEngine` actor in the app: Core Data persistent history tracking feeds a local outbox; a
`NSBackgroundActivityScheduler` runs it while the app is open (it is a menu-bar app: almost
always); `URLSession` background configuration for large uploads. A sync pass is: refresh the
session if the JWT is near expiry → upload outbox in batches → read other devices' heads → fetch
new segments → merge (on a background context, batches of 200 like import) → advance cursors.
Everything is resumable, idempotent and safe to kill at any point (objects are immutable; cursors
move only after a merge commits). Status surface: idle / syncing (n of m) / paused / over
quota / offline / needs attention — one line in Settings plus a menu-bar glyph.

Poll interval: on launch, on wake, and every 5 min while active; backoff when idle. No push in
v1 (APNs would need a server tier we do not want to run); a few minutes of latency between Macs is
fine for history.

### 4.3 End-to-end encryption

- A random 256-bit **library key** is created on the first Mac and stored in the **iCloud
  Keychain** (`kSecAttrSynchronizable`) so every Mac on the Apple ID has it with no password to
  type. A printed/saved **recovery key** (24 words) is offered at setup for the case the Apple ID
  itself is lost; skipping it is allowed and explained.
- Per object: AES-256-GCM (CryptoKit) with a key from HKDF(library key, object id); audio is
  encrypted in 1 MB chunks with the chunk counter in the nonce so a 90-minute meeting streams
  without loading it. Object names are random ids; sizes and times are all the server learns.
- Consequences to accept: no server-side search, no web viewer, no "AI over your cloud meetings"
  from our side; lose the key and the data is gone. In exchange there is nothing for us to leak.

## 5. Pricing and unit economics

### 5.1 Inputs (list prices — **verify before launch**)
GCS regional Standard ≈ $0.020/GB-month (a third-party table shows $0.022 for Iowa), Nearline
$0.010, Class A $0.005/1k, Class B $0.0004/1k, internet egress ≈ $0.12/GB (first TB, premium
tier), Cloud Run $0.000024/vCPU-s, $0.0000025/GiB-s, $0.40/M requests. Apple: 30 % commission,
**15 % with the Small Business Program** (under $1 M/year, enrolment required) and 15 % on a
subscription after its first year. Sources: [Cloud Storage pricing](https://cloud.google.com/storage/pricing),
[Cloud Run pricing](https://cloud.google.com/run/pricing),
[RevenueCat on the Small Business Program](https://www.revenuecat.com/blog/engineering/small-business-program).
The official GCS table did not render in my search; the numbers above come from Google's pricing
pages as summarised by third parties, so treat them as ±20 % until checked in the calculator.

### 5.2 Cost to serve one user per month (30 % of audio hot in Standard, the rest Nearline)

| Profile | Stored | Storage | Ops | Egress | Run | **COGS** |
|---|---|---|---|---|---|---|
| Light — dictation only | 0.3 GB | $0.006 | $0.006 | $0.006 | $0.003 | **$0.02** |
| Typical — weekly meetings | 2 GB | $0.028 | $0.010 | $0.036 | $0.004 | **$0.08** |
| Heavy — daily meetings, 3 Macs | 10 GB | $0.130 | $0.021 | $0.180 | $0.009 | **$0.34** |
| Heavy, month of a new-Mac restore | 10 GB | $0.130 | $0.021 | $1.380 | $0.009 | **$1.54** |

### 5.3 The one line that can hurt: egress
A full restore of a heavy library costs $1.20 in traffic — more than the month's net revenue.
Four guards, all cheap to build:
1. **Text first, audio on demand.** A new Mac gets all rows in seconds (~MBs); recordings
   download when played, or on an explicit "Download all recordings".
2. **Restore allowance** in the plan: 5 GB of downloads a month, shown in Settings, resets
   monthly; beyond it the app downloads text only and says why. (Counted by the server when it
   mints download tokens — tokens are the only way to read.)
3. **Opus stays Opus** (already ~16 kbps): nothing is re-encoded larger.
4. A rate limit on token minting and on new-device registration (Firestore counters).

### 5.4 Price points (net = 85 % of price)

| Price | Light | Typical | Heavy | Heavy + restore |
|---|---|---|---|---|
| $0.99/mo | 98 % | 91 % | 60 % | −83 % |
| **$1.99/mo** | **99 %** | **95 %** | **80 %** | 9 % |
| $2.99/mo | 99 % | 97 % | 87 % | 39 % |
| **$14.99/yr** (= $1.25/mo, net $1.06) | **98 %** | **93 %** | **68 %** | −45 % |

Recommendation: **one plan, $1.99/mo or $14.99/yr** (annual = the Pro price point and
~37 % off), **10 GB storage + 5 GB/month restore traffic included**. With those caps the
worst possible user (10 GB stored, 5 GB downloaded every month) costs $0.73: a 57 % margin monthly,
31 % annual. A typical user is 93–95 %. Reference points: iCloud sells 50 GB for $0.99 and 200 GB
for $2.99 — but it is general storage; ours is a feature of a dictation app, and 10 GB is years of
history. Keep it cheap enough to be an impulse purchase; the margin comes from volume, not price.

- A **1-month free trial** (introductory offer) costs a few cents per trialist and is the best
  conversion tool; Apple ID limits abuse.
- Do not touch the one-time Pro Pack. Cloud is a separate subscription *group* that requires
  nothing but Pro to be useful; App Review 3.1.2 wants a subscription to deliver ongoing value —
  storage and bandwidth we pay for every month are exactly that.
- Add **Plus** ($4.99/mo, 100 GB, 25 GB restore) only when real usage shows people hitting 10 GB.
  Do not ship it speculatively.
- Family Sharing: allow it for the subscription (each member gets their own `uid` from their own
  transaction) — costs us nothing extra per extra user because each pays nothing; cap at the plan
  limits per member. Decide before launch (§8).

### 5.5 Platform cost
Zero users: ≈ $1.50/month. Break-even on a $50/month ops budget: **31 payers**.

| Payers | Revenue | After Apple 15 % | Cloud | Profit |
|---|---|---|---|---|
| 1,000 | $1,990 | $1,692 | $78 | **$1,613/mo** |
| 10,000 | $19,900 | $16,915 | $782 | **$16,133/mo** |
| 100,000 | $199,000 | $169,150 | $7,819 | **$161,331/mo** |

## 6. Abuse, safety, operations

- **Quota by uploading only through the server:** signed PUT URLs carry a content-length range and
  every grant increments the user's counter; the user cannot store more than the plan allows.
  An hourly Cloud Run Job reconciles counters against real bucket prefix sizes (Storage Insights
  inventory, daily) and flags drift.
- **Fraud / refunds:** `REFUND` and `REVOKE` notifications flip to lapsed immediately.
- **Replay and theft:** session JWTs are 1 h and device-bound; StoreKit JWS has a signed date and
  the server rejects stale ones. App Attest is an optional add-on if sign-up abuse appears.
- **Costs cannot run away:** Cloud Run max-instances 5, bucket without public access, budget alerts,
  a kill switch (Remote flag → app stops syncing) and per-user ceilings in Firestore.
- **Deletion:** `DELETE /v1/account/data`, the 60-day lapse job, and no content in logs.
- **Data residency:** start with one US bucket; the user's region is a field on the entitlement, so an
  EU bucket (and EU-only processing statement) can be added later without a protocol change. E2E
  encryption means what we hold is ciphertext.
- **Observability:** structured logs (no payloads), request count/latency/errors, bucket bytes by
  prefix class, cost per user per day in BigQuery (billing export is free to enable). Alert on cost
  per user outliers, not on averages.
- **Privacy / App Store:** the privacy label changes from "Data Not Collected" to purchase
  identifiers (and nothing else); update the policy and the review notes (explain E2E and that no
  account exists). Voice data never leaves the Mac unencrypted.

## 7. Build plan

| # | Milestone | Contents | Est. |
|---|---|---|---|
| 0 | **Decisions + store setup** | Answer §8; enrol in the Small Business Program; Paid Apps agreement; create the subscription group, two products, 1-month intro offer, ASSN V2 URL (App Store Connect); enable GCP APIs; bucket + lifecycle + service account + budgets (`deploy/`) | 1–2 d |
| 1 | **Server skeleton** | Go module, Cloud Build/Actions with Workload Identity Federation, `/healthz`, JWS verification + ASSN V2 with Apple's test certificates, entitlement state machine on a Firestore interface with an in-memory fake, `/v1/session`, `/v1/account` | 4–5 d |
| 2 | **Storage grants** | Signed upload URLs with size ranges, downscoped download tokens, quota/allowance counters, prefix delete, lapse job; tested against fake-gcs-server and once against the real bucket | 3–4 d |
| 3 | **Client: purchase + account** | `SubscriptionStoreView` paywall, entitlement refresh, Settings → Cloud page (plan, usage, restore allowance, devices, pause, delete cloud data), UI-tested | 4 d |
| 4 | **Client: sync, text** | Library key (Keychain + recovery key), change tracking, outbox, segments, merge with tombstones, status UI; two-Mac convergence tests (clock skew, duplicates, offline for a week, delete on one / edit on the other) | 8–10 d |
| 5 | **Client: audio** | Packs, chunked encryption, lazy download, "Download all recordings", resumable background uploads, restore allowance | 5–6 d |
| 6 | **Hardening and launch** | Load test the control plane (k6, 10k simulated devices), failure injection (GCS 5xx, Apple outage, token expiry mid-upload), cost dashboard, privacy/ToS/App Review notes, TestFlight beta with a cost cap | 4–5 d |
| 7 | **After launch** | Plus tier if needed, EU bucket, optional R2 backend, optional push (APNs) for instant sync | — |

About **5–6 weeks** for one engineer to a TestFlight beta. The server (milestones 1–2) is useful
alone and small enough to review in one sitting; the client is the bulk of the risk — sync
correctness, not cloud.

## 8. Decisions needed from you

1. **End-to-end encryption** (recommended) vs server-readable. E2E means no web viewer and no
   server-side AI over cloud data, and a lost key means lost data; it also means we can sell "we
   cannot read your meetings".
2. **Price and caps:** $1.99/mo · $14.99/yr · 10 GB · 5 GB/mo restore, with a 1-month trial?
3. **Distribution:** StoreKit subscriptions exist only in the App Store build. Direct-download
   builds (the non-`APP_STORE` Release) would need Paddle or Stripe plus a way to link a licence
   to a `uid`. Ship App Store only first (recommended)?
4. **Family Sharing** on the subscription: yes or no.
5. **Who owns the Apple/Google accounts** (App Store Connect admin, GCP billing owner), and may I
   enable the APIs and create the bucket and service account in `whisperer-491716` once the
   plan is agreed? Nothing has been enabled or created yet.

## 9. Assumptions to verify before building

- Current GCS and Cloud Run list prices in the pricing calculator (§5.1) and the egress tier the
  bucket's location gets.
- That Credential Access Boundary downscoped tokens support everything the client needs on the
  JSON API (resumable uploads are not needed for downloads; reads are all that is delegated).
- App Review's view of a subscription whose main value is cloud sync for an app with a one-time
  Pro unlock (3.1.1 / 3.1.2); the privacy-label change; Family Sharing behaviour of
  `originalTransactionId`.
- Apple's Go server-library situation (own the 150 lines vs a community package).
- Core Data persistent history tracking on the existing single store (dictations, meetings and
  dictionary share `history.sqlite`) — confirm it can be switched on without a migration.

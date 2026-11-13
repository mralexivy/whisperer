# Whisperer Cloud — implementation plan (for approval)

Status: **proposed, awaiting your confirmation** (2026-11-13). This is the concrete build plan for the design in
[cloud-sync.md](cloud-sync.md) (read its *Lean rules* and *Plans and margins* first). Nothing here is deployed.
Scope: **Mac App Store build only**, next app version, nothing released until you say so.

## 1. What we are building, in one paragraph

A Mac app that keeps a user's history (dictations, meetings, recordings, dictionary, records) identical on all their
Macs. Data is **encrypted on the Mac** and stored in **one private Google Cloud Storage bucket**; the Mac talks to the
bucket **directly** through short-lived signed URLs. A **single small Go service on Cloud Run** decides who may do
what (verifies the Apple subscription, applies plan limits, signs the URLs); **Firestore** holds a few KB per
subscriber. That is the entire cloud: **Cloud Run + Cloud Storage + Firestore + Secret Manager** (+ Artifact
Registry for one 6 MB image). No other service is enabled.

## 2. Cloud layout

### 2.1 Cloud Storage — one bucket, `gs://whisperer-491716-user-data` (exists)

Private, uniform access, public-access-prevention enforced, soft delete off, no versioning, `us-central1`.
Everything a user owns lives under one prefix. Names are random ids; contents are ciphertext.

```
u/<uid>/
  keycheck.enc                       one tiny object: a known value encrypted with the library key, so a new Mac can
                                     tell "wrong key" from "no data" before downloading anything
  head/<deviceId>.enc                that device's newest segment number (tens of bytes)
  log/<deviceId>/<seq>.seg           an append-only batch of row changes from one device (JSON lines → compressed →
                                     AES-GCM). Written once, never modified, never deleted until the user is
  audio/<packId>.pack                dictation recordings, packed to ≤ 4 MB (one object per pack, not per file —
                                     operations cost more than storage otherwise)
  audio/<meetingId>.enc              a meeting recording: one object, encrypted in 1 MB chunks
  chat/<meetingId>.enc               a meeting's Ask-AI thread
```

- `uid` = `HMAC(serverSecret, originalTransactionId)` truncated to 128 bits: the same on every Mac of one Apple ID,
  not reversible to the Apple ID.
- **Each device writes only its own `log/<deviceId>/…`.** No two writers ever touch the same object, so there is no
  locking and no read-modify-write. A Mac learns what is new by reading the other devices' `head` objects.
- Lifecycle (exists): `*.pack` Standard → Nearline after 30 days. (Meeting audio is rarely re-read: same rule
  added for `audio/*.enc` when we add the suffix.)
- Uploads are created with `ifGenerationMatch=0` (signed into the URL): an object can never be overwritten.

### 2.2 Firestore — database `(default)`, native, `us-central1` (exists)

Server-only (no client SDK, security rules deny everything; the Cloud Run service account is the only reader/writer).
Two document types, a few hundred bytes each:

- `entitlements/{uid}`: product id, plan, expiry, grace end, revoked-at, auto-renew, `deleteAfter`, last notification
  ids, `dataDeletedAt` — exactly the struct already implemented and tested in `server/internal/entitlement`.
- `usage/{uid}`: `storedBytes`, plus `month`, `downloadBytes`, `uploadGrants` for the current month (reset on first
  request of a new month). Updated in a transaction when URLs are granted.

Expected traffic: ≈ 2–4 reads and 1–3 writes per sync pass; a few hundred a month per user — **inside Firestore's free
tier for ~10k payers**. One single-field index (`deleteAfter`) for the retention sweep.

### 2.3 Cloud Run — one service, `whisperer-api`, `us-central1`

| Setting | Value | Why |
|---|---|---|
| Image | `us-central1-docker.pkg.dev/whisperer-491716/whisperer/api` | built by GitHub Actions, pushed with Workload Identity Federation (no keys, no Cloud Build) |
| Scaling | `min-instances 0`, `max-instances 2`, `concurrency 80` | $0 idle; a hard ceiling on spend and abuse |
| Resources | 256 MiB, 1 vCPU, CPU only during requests | request-based billing |
| Timeout | 10 s | no long requests exist |
| Ingress | all, **unauthenticated at the network level** | phones/Macs and Apple's servers must reach it; every route authenticates itself (Apple JWS / Apple-signed webhook / our 1-hour token) |
| Identity | `whisperer-api@…` (exists) | `storage.objectAdmin` on the one bucket, `datastore.user`, `signBlob` on itself |
| Secrets | `UID_SECRET`, `SESSION_SIGNING_KEY` from Secret Manager | the only two; **no Apple private key is needed** (we verify Apple's signatures, we never call Apple) |

Kill switch: `gcloud run services update whisperer-api --max-instances=0`.

## 3. The server's API (`/v1`, JSON, all tiny)

Implemented and tested already: `POST /v1/session`, `GET /v1/account`, `POST /v1/apple/notifications`, `GET /healthz`.
To build (next milestone):

| Route | Request → response |
|---|---|
| `POST /v1/sync/upload` | `[{name, size}]` → V4 signed **PUT** URLs (15 min, `x-goog-content-length-range: 0,size`, `ifGenerationMatch: 0`, fixed content type) for names under `u/<uid>/…` only. Refused if the token is read-only, or the plan's storage / monthly grant limit would be exceeded (`ErrStorageFull`, `ErrGrantLimit`, `ErrOverQuota`). Reserves the bytes in `usage/{uid}` |
| `POST /v1/sync/commit` | names → the server reads each object's real size (one metadata read) and corrects the reservation. An abandoned upload simply never commits and the reservation expires |
| `POST /v1/sync/download` | `[name]` → signed **GET** URLs (15 min) within `u/<uid>/`. Counts bytes against the monthly download allowance. The log/head objects are *not* counted (they are tiny) — audio is |
| `GET /v1/sync/list?prefix=` | one page of object names + sizes for a prefix (for the first sync on a new Mac) |
| `DELETE /v1/account/data` | deletes the user's whole prefix and zeroes usage ("Delete my cloud data", GDPR erasure) |

Errors are `{"error": code, "message": text}`; the Mac maps each code to one plain sentence. Signing uses IAM
Credentials `signBlob` as the Cloud Run service account — **no key file exists**.

## 4. The Mac side

### 4.1 Pieces (new code in `Whisperer/Cloud/`, App Store build only)

| Piece | Job |
|---|---|
| `CloudAccount` | StoreKit 2: products, purchase, `Transaction.currentEntitlements` → session token; refreshes before expiry; exposes plan/state |
| `CloudKeys` | creates the 256-bit **library key** on the first Mac, stores it in the **iCloud Keychain** (synchronizable); recovery key; key check |
| `CloudCrypto` | CryptoKit: HKDF per object, AES-256-GCM, 1 MB chunked streams for audio; test vectors |
| `ChangeTracker` | Core Data **persistent history tracking** → a local outbox of changed row ids (insert/update/delete); survives relaunch |
| `SegmentWriter` | every 5 min or 50 changes: rows → `HistoryArchive`'s generic encoding → compress → encrypt → `log/<device>/<seq>.seg`; then updates `head/<device>` |
| `SegmentReader` | reads other devices' heads, downloads new segments, decrypts, **merges with the rules already shipped** (by id, newest `lastModifiedAt` wins, tombstones) on a background context in batches of 200 |
| `AudioSync` | dictation audio into packs; meeting audio as single objects; downloaded **on demand** (when played) or by "Download all recordings"; shows allowance left |
| `SyncEngine` (actor) | one state machine: idle → syncing → paused / offline / over quota / needs attention; schedules passes (launch, wake, every 5 min while active, backoff when idle); everything resumable and idempotent |
| Settings → **Cloud** page | plan + paywall (`SubscriptionStoreView`), usage bars (reuses the Storage card's bar), devices, pause, "Delete my cloud data", recovery key, status line |

### 4.2 Behaviour that matters

- **First enable:** pick a plan → the app uploads the existing history in the same size-capped parts as Move History
  (resumable) → text first, then audio.
- **New Mac:** sign in with the same Apple ID → keychain gives the key → `keycheck` verifies it → all rows arrive in
  seconds (a few MB) → audio downloads when played, or "Download all recordings" (counts against the allowance, shown first).
- **Edits and deletes** travel as rows with `lastModifiedAt`; a delete is a tombstone kept 90 days.
- **Offline for a week, two Macs editing the same dictation:** newest wins per row; no data is lost silently
  (both versions exist in the logs; a lost edit is the one with the older timestamp).
- **Lapsed subscription:** read-only; everything downloadable; "Export" always works. Re-subscribing resumes sync.
- **Downgrade over quota:** nothing deleted; uploads pause with a clear message until under the limit.
- **App Store compliance:** subscription terms and price shown by `SubscriptionStoreView`; restore purchases;
  privacy label updated (purchase identifiers only; content is end-to-end encrypted and unreadable by us).

### 4.3 End-to-end encryption

- Library key: 32 random bytes, iCloud Keychain, never sent to us. Per object: `HKDF-SHA256(libraryKey, objectName)` →
  AES-256-GCM, random 96-bit nonce stored with the object; audio in 1 MB chunks with the chunk index in the AAD so
  chunks cannot be reordered or dropped.
- **Recovery key**: shown once as 8 groups of 4 characters; the user may skip it (explained). Without Apple ID access
  *and* without the recovery key, the data is unrecoverable by design.
- What Google or an attacker sees: random object names, sizes, upload times. What we see: the subscription id and byte counts.

## 5. App Store Connect (via the shared API key — created as **drafts**, nothing on sale)

1. Subscription group **"Whisperer Cloud"** (levels: Large > Standard > Starter), Family Sharing **off**.
2. Six products: `com.ivy.whisperer.cloud.{starter,standard,large}.{monthly,yearly}`, prices
   $0.99/$9.99, $2.99/$29.99, $7.99/$79.99 (USD base; Apple equalises the rest), English localisations
   (display name + description), review screenshot + review notes ("sync requires an Apple-ID subscription; test with a sandbox account").
3. **Introductory offer:** one free month on Starter only.
4. App Store Server Notifications V2 URL (production and sandbox) = the Cloud Run URL `/v1/apple/notifications`.
5. Sandbox tester account(s) for purchases; a local `.storekit` configuration for unit tests.

## 6. Build order, with exit criteria

| # | Milestone | Done when | Est. |
|---|---|---|---|
| A | **Server: Firestore + storage grants** (`entitlement.Store` on Firestore, `usage` counters, signed PUT/GET, commit, list, delete-my-data, retention sweep calling the real deleter) | all routes tested against fakes **and** once against the real bucket (a `test/` prefix, cleaned); 6 MB image builds | 4 d |
| B | **Deploy**: Workload Identity Federation, GitHub Actions build → Artifact Registry → `gcloud run deploy`, secrets in Secret Manager, `/healthz` live, budget alarms verified | a push to `main` under `server/` deploys; rollback by revision tested | 1–2 d |
| C | **App Store Connect drafts** + Sandbox: products, group, offer, notification URL, a Sandbox purchase reaching `/v1/session` | a Sandbox subscription shows `state: active` from the live service | 1 d |
| D | **Mac: account, keys, crypto** (`CloudAccount`, `CloudKeys`, `CloudCrypto`, paywall, Cloud page skeleton) | buy in Sandbox → plan shown; crypto vectors pass; keychain key shared between two Macs | 4 d |
| E | **Mac: text sync** (`ChangeTracker`, segments, reader/merge, `SyncEngine`, status UI) | two-Mac convergence tests (offline a week, clock skew, delete-vs-edit, duplicate delivery, kill mid-sync) pass | 8–10 d |
| F | **Mac: audio** (packs, chunked encryption, on-demand download, allowance, resumable uploads) | a 90-minute meeting syncs and plays on the second Mac; allowance enforced | 5 d |
| G | **Hardening**: load test the service, failure injection (GCS 5xx, Apple outage, expired token mid-upload), cost report from a simulated month, privacy copy, review notes | a heavy simulated user's cost matches the model within 20 % | 4 d |
| H | **TestFlight** to a handful of people with a **server-side kill switch**, watch cost and errors for a week | no data loss, cost per user as modelled | 1 wk |
| I | Ship with the next version | — | — |

≈ **5–6 weeks** to TestFlight. A–C (server, deploy, App Store Connect) are ~1.5 weeks and need nothing from the Mac app.

## 7. Cost, per month

- Platform at zero users: **≈ $1.50**. First 10k payers: Cloud Run ≈ $0–10, Firestore $0, Secret Manager ≈ $0.2.
- Per user: typical **$0.04–0.42** depending on tier (95 % margin); the worst case is capped by plan (40–55 %).
- Tripwires: budget alerts (700 ILS ≈ $200 at 5/25/100 %), Cloud Run `max-instances 2`, per-user caps in code, the kill switch.

## 8. Risks and how each is handled

| Risk | Handling |
|---|---|
| Sync bug corrupts or loses history | Objects are immutable and append-only; the local database is never rewritten from the cloud without the merge rules; convergence tests are a merge gate; "Export" always works |
| Lost key | iCloud Keychain + optional recovery key; the UI says plainly what skipping the recovery key means |
| Runaway cost | everything goes through signed URLs the server meters; ceilings and alerts above |
| App Review objects to the subscription | it delivers a recurring cost (storage/bandwidth); review notes + sandbox account; restore button; clear terms |
| Apple clock/cert changes | chain verified at signing time; root pinned in the binary with a fingerprint test |
| Firestore / GCS regional outage | the Mac keeps working offline and retries with backoff; nothing blocks dictation or meetings |
| Egress price change | allowances are server-side; change them without an Apple price change |

## 9. What I need you to confirm

1. **Architecture:** Cloud Run + Cloud Storage + Firestore + Secret Manager, nothing else — yes?
2. **Encryption:** end-to-end with the iCloud-Keychain key and an *optional* recovery key — or make the recovery key mandatory?
3. **Plans and prices:** Starter 5 GB $0.99/$9.99, Standard 25 GB $2.99/$29.99, Large 100 GB $7.99/$79.99, free month on
   Starter only, Max not launched — yes?
4. **Audio:** downloads on demand by default (text first) — yes?
5. **Retention:** 60 days read-only after a subscription ends, then deleted — yes? (shorter saves almost nothing; longer is kinder)
6. **Region:** `us-central1` for everything, an EU bucket only if European customers ask — yes?
7. **Go-ahead for milestone A–C** (server storage grants, deploy to Cloud Run, App Store Connect *drafts* + Sandbox) — I can
   start immediately, each cloud command shown for your approval, and nothing is released.

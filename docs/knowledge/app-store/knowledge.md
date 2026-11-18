# App Store submissions — what Apple actually checks, and what we got wrong

## 2026-11-17: Whisperer China rejected before a human saw it (guideline 2.4.5)

- **What happened.** The China record (build 7) came back `REJECTED` at 02:16 with an *automated* message: "the app includes the
  `com.apple.security.network.server` entitlement but does not appear to have matching functionality". The review never started. The
  title, "2.4.5 Performance: Hardware Compatibility (macOS)", is misleading: it is the sandbox/entitlements guideline, not CPU
  architecture (the build was already arm64-only on macOS 26.2).
- **Why we missed it.** Our pre-submission checks (`app-store-check`, `audit-app.sh`, the `strings`/`nm` scan) looked for banned APIs and
  strings. None compared the entitlements the signed app carries with the features that justify them. We had never needed to explain
  `network.server`: it is used for two real things (the optional MCP server on 127.0.0.1, and the one-shot redirect listener of the ChatGPT
  sign-in) but nothing in the review notes said so, and Apple's static analysis could not see it.
- **Fix.** The explanation is now in App Review Information of both records and was sent as a reply in Resolution Center.
  `scripts/security/audit-entitlements.sh` now fails an archive when an entitlement has no matching code, no usage string or no
  allow-list entry.

## 2026-11-18: the privacy policy said the opposite of what the app does

While auditing entitlements we found the website privacy policy, the terms and the in-app policy all said meetings record the
"microphone only" and "never record system audio", while the app records the call app's audio through a Core Audio process tap by default
(`NSAudioCaptureUsageDescription`, `SystemAudioCapture`, `MeetingCallAudioController`), and the listing and review notes said so. A reviewer
reading both would have caught it. All documents now describe call audio and the "Screen & System Audio Recording" permission, and
`audit-entitlements.sh` fails when a document says "microphone only" while the tap is compiled in. When a feature is added or removed,
grep the public text for the opposite claim.

## 2026-11-18: tax and price update audit (Apple notice of 2026-11-17)

Apple's notice (the news index dates it Nov 17) announced: automatic prices for apps and non-subscription IAPs in Botswana, Colombia, Egypt,
Rwanda and Türkiye on 2026-12-03 (not for auto-renewable subscriptions, not for a storefront chosen as base); a new "Software as a Service
(SaaS)" tax attribute under App Store Software, Software Training Material, Dating and Boosting; and California sales/use tax on those
categories from 2027-01-01 (USA prices are shown exclusive of tax, proceeds unchanged). Apple does not define SaaS in the notice or in the
help pages we could read.

What is configured (checked in the API and in the web UI, read-only):

- **Both records** (`com.ivy.whisperer`, `com.ivy.whisperer.cn`): app tax category **App Store software**, no attributes. The Pro IAP on each
  (`com.ivy.whisperer.pro`, `com.ivy.whisperer.propack`, non-consumable, $14.99) is **Match to parent app**. No subscriptions exist; the
  "Whisperer Cloud" group is empty.
- Base storefront is USA, app $4.99, IAP $14.99, so both take the 12-03 change on the five storefronts: COL falls (24 900 → 19 900 COP app,
  69 900 → 59 900 IAP), EGP/TRY rise (249.99 → 299.99 app, 799.99 → 999.99 IAP), RWA $4.99 → $5.99 and $14.99 → $17.99, BWA unchanged. The
  new prices are already scheduled in `automaticPrices` with `startDate 2026-12-03`. The China record is sold in CN only, so none of it applies.
- Verdict: nothing to change. Whisperer is local software sold as a one-time unlock, so App Store software without SaaS is the honest
  classification (our judgement, not an Apple definition). **Revisit when Whisperer Cloud (server-side sync) ships**: that is the first
  thing that could be a hosted service.

How to check next time:

- The tax category is **not in the App Store Connect API** (no relationship on apps, IAPs or subscriptions, no `appTaxCategories`). Read it in
  the web UI: app → Pricing and Availability → Tax Category; IAP page → Tax Category. A logged-in Chrome is attached to the chrome-devtools
  MCP, so `new_page` on `appstoreconnect.apple.com/apps/<id>/distribution/pricing` works without a login.
- `asc.py` prints at most 6000 characters, which breaks `json.loads` on a long list. Import it and call `asc.call("GET", path)` instead.
- The upcoming price rows are `GET /v1/inAppPurchasePriceSchedules/{iap}/automaticPrices` and `/v1/appPriceSchedules/{app}/automaticPrices`
  (`include=territory,<pricePoint>`); a row with an `endDate` is the old price, the one with a `startDate` is the new one.
- The same Google/Apple account also holds ReelStrip, Biteslog and others in App Store Connect. Audit only the two Whisperer records.

## Process facts worth remembering

- A rejected or developer-cancelled version can take a new build with `PATCH /v1/appStoreVersions/{id}/relationships/build`; its state
  returns to `PREPARE_FOR_SUBMISSION`. A cancelled submission cannot be reused; create a new `reviewSubmission` and add the version.
- The first non-consumable IAP of an app must be submitted with a version. The API has no item type for it: add it in the web UI from
  the IAP page ("Add for Review" opens the draft submission) after the version is in the draft.
- Cancelling a review submission (`PATCH canceled=true`) answered 500 for hours during an Apple outage; reads were flaky too. Poll, do not
  retry in a tight loop, and never assume a failed call changed nothing: read the state back.
- Build numbers are per record. The regular and China records can both carry 9.
- Resolution Center messages (the reason for a rejection) are only in the web UI: App Review → the submission.

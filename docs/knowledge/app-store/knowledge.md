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

## Process facts worth remembering

- A rejected or developer-cancelled version can take a new build with `PATCH /v1/appStoreVersions/{id}/relationships/build`; its state
  returns to `PREPARE_FOR_SUBMISSION`. A cancelled submission cannot be reused; create a new `reviewSubmission` and add the version.
- The first non-consumable IAP of an app must be submitted with a version. The API has no item type for it: add it in the web UI from
  the IAP page ("Add for Review" opens the draft submission) after the version is in the draft.
- Cancelling a review submission (`PATCH canceled=true`) answered 500 for hours during an Apple outage; reads were flaky too. Poll, do not
  retry in a tight loop, and never assume a failed call changed nothing: read the state back.
- Build numbers are per record. The regular and China records can both carry 9.
- Resolution Center messages (the reason for a rejection) are only in the web UI: App Review → the submission.

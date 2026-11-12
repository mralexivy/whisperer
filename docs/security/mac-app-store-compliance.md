# Mac App Store compliance for app-protection work

Status: 2026-11-07, branch `feature/app-protection`. Every control here is chosen to *keep* the app
submittable. Primary Apple sources, with how each claim was treated.

## Verified against primary sources

| Topic | Source | Finding | Decision |
|---|---|---|---|
| App completeness; no hidden features | [App Review Guidelines 2.2, 2.3.1](https://developer.apple.com/app-store/review/guidelines/) | Apps must not contain hidden or undocumented features; nothing may behave differently under review | No anti-debugging that changes behavior under review; no hidden logic. The existing `#if APP_STORE` dual build removes code, it does not hide runtime behavior |
| Keystroke/Accessibility (2.4.5) | Guidelines 2.4.5 | Already drove the clipboard-only App Store build (see app-store-submission.md). Protection work must not reintroduce AX/CGEvent | No change here |
| Downloaded code/executables (2.5.2) | Guideline 2.5.2 | A sandboxed app may not download or run code that adds/changes features. Model **weights are data, not code** (reviewer notes already argue this) | No packer, no runtime code decryption, no downloaded executables. Model-pack downloads unchanged |
| Hardened Runtime | [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) | Required for notarization; MAS archives enable it | Already `YES`; unchanged |
| Debug info / dSYM | [Building to include debugging information](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information) | `dwarf-with-dsym` keeps symbolication without shipping symbols in the binary | Already set; preserved. We do **not** disable dSYM |
| Swift optimization | Xcode build settings | `SWIFT_OPTIMIZATION_LEVEL` unset ⇒ `-Onone` ships. `-O` is the standard Release value | Set `-O` for Release + AppStore |
| Privacy manifest | [Describing data use in privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) | Required-reason APIs (UserDefaults, file timestamp, system boot time) need declared reasons | Added `PrivacyInfo.xcprivacy` with CA92.1 / DDA9.1 / 35F9.1; no tracking, no collected data |
| StoreKit entitlement integrity | [AppTransaction](https://developer.apple.com/documentation/storekit/apptransaction), [Transaction](https://developer.apple.com/documentation/storekit/transaction) | Verified transactions are the sanctioned anti-tamper for purchases | Keep existing StoreKit 2 path; do **not** add custom DRM / license keys (would risk 3.x/2.x rejection) |

## Rejected controls (incompatible or security theater)

- **Binary packing / runtime executable decryption / custom VM**: conflicts with 2.5.2 and Hardened
  Runtime (no unsigned executable pages); high rejection risk. Rejected.
- **Aggressive anti-debugging / `ptrace(PT_DENY_ATTACH)` by default**: behavior that differs under
  inspection risks 2.3.1; low value against an attacker on their own machine. Rejected.
- **String encryption with an in-binary key**: does not protect secrets (key ships alongside). We
  removed the *need* instead (no secrets in source). Rejected.
- **Kernel extensions / private APIs / SIP workarounds**: banned. Rejected.
- **Telemetry for copy protection**: breaks the local-only privacy promise and needs disclosure.
  Rejected.

## Note

A clean local build and even a successful App Store Connect upload are evidence of pipeline
validity, not of approval. Only an actual App Review decision approves a specific build.

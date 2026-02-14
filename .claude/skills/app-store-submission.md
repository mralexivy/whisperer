---
name: app-store-submission
description: Use when preparing for Mac App Store submission, working with StoreKit, receipt validation, entitlements, or App Store compliance. Covers the complete submission workflow, IAP configuration, and testing checklists.
---

# App Store Submission Guide

## Current Status

Track A (App Store Foundation) is complete. The app is ready for submission.

### What's Implemented
- **Receipt Validation** (`Licensing/ReceiptValidator.swift`) — Validates App Store receipt on launch. Exits with code 173 on failure (triggers receipt refresh). Only runs in Release builds.
- **StoreKit 2 Integration** (`Store/StoreManager.swift`) — Pro Pack IAP infrastructure. Product ID: `com.ivy.whisperer.propack`.
- **Purchase UI** (`UI/PurchaseView.swift`) — Purchase flow with Restore Purchases.
- **Export Compliance** — `ITSAppUsesNonExemptEncryption = NO` in Info.plist (HTTPS only).
- **Privacy Policy** — Hosted at https://whispererapp.com/privacy/
- **Entitlements** — Cleaned: sandbox, network.client, audio-input, files.user-selected.read-write. Removed network.server.

## Entitlements (whisperer.entitlements)

Required:
```xml
com.apple.security.app-sandbox = true
com.apple.security.network.client = true        <!-- Model downloads -->
com.apple.security.device.audio-input = true    <!-- Microphone -->
com.apple.security.files.user-selected.read-write = true
```

NOT present (intentionally removed): `com.apple.security.network.server`

## Info.plist Keys

```xml
ITSAppUsesNonExemptEncryption = NO     <!-- HTTPS only, exempt -->
NSMicrophoneUsageDescription = "Whisperer needs microphone access to transcribe your voice to text."
NSAppleEventsUsageDescription = "Whisperer needs automation access to insert transcribed text into applications."
```

## App Store Connect Configuration

| Field | Value |
|-------|-------|
| Bundle ID | `com.ivy.whisperer` |
| Category | Utilities (Primary), Productivity (Secondary) |
| SKU | `whisperer-macos-1` |
| Pro Pack Product ID | `com.ivy.whisperer.propack` |
| Pro Pack Type | Non-Consumable |
| Data Collection | "Data Not Collected" |

## Build & Archive

```bash
# Clean build
xcodebuild clean build -project Whisperer/whisperer/whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS"
```

In Xcode: Product → Archive → Distribute App → App Store Connect → Upload

## Pre-Submission Checklist

### Code
- [ ] Privacy policy URL updated in WhispererApp.swift
- [ ] Bundle ID matches everywhere: `com.ivy.whisperer`
- [ ] Product ID matches: `com.ivy.whisperer.propack`
- [ ] Version/build numbers set
- [ ] Acknowledgments.txt added to Xcode target

### Testing
- [ ] App builds in Release configuration
- [ ] Receipt validation triggers exit(173) without receipt (expected)
- [ ] Pro Pack products load in Sandbox
- [ ] Purchase and Restore work in Sandbox
- [ ] All permissions prompt correctly
- [ ] Model downloads successfully
- [ ] Transcription works end-to-end
- [ ] Text injection works in various apps

### App Store Connect
- [ ] App created with correct bundle ID
- [ ] Pricing set
- [ ] Pro Pack IAP created and submitted for review
- [ ] Privacy policy URL added
- [ ] Export compliance answered
- [ ] Screenshots uploaded (1280x800 or 1440x900)
- [ ] Description and keywords entered
- [ ] Build uploaded and processed
- [ ] Reviewer notes provided

## Reviewer Notes Template

```
Testing Instructions:
1. Grant Microphone, Accessibility, and Input Monitoring permissions when prompted
2. Wait for model download (~500MB Large V3 Turbo) — one-time
3. Open TextEdit or any text field
4. Hold Fn key, speak, release to see transcription
5. The app works 100% offline after model download

Pro Pack IAP: com.ivy.whisperer.propack
Contact: [YOUR_EMAIL]
```

## Common Rejection Reasons

1. **Permissions not explained** — Ensure NSMicrophoneUsageDescription and NSAppleEventsUsageDescription are clear
2. **App crashes** — Test thoroughly, use TestFlight first
3. **Privacy policy issues** — Verify URL works and is accurate
4. **IAP issues** — Test in Sandbox before production
5. **Missing functionality** — All advertised features must work

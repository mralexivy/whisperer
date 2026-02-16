# App Store Submission Guide

## Current Status

Version 1.0 (2) submitted after addressing Guideline 2.4.5 rejection in v1.0 (1).

### Rejection History

**v1.0 (1) — Rejected (Guideline 2.4.5)**
- Apple flagged: "Your app uses Accessibility features for non-accessibility purposes" and "Your app accesses user keystrokes for purposes other than assistive accessibility features"
- Root cause: `CGEventTap`, `IOHIDManager`, global `keyDown`/`keyUp` monitors, and `CGEvent.post` for simulated paste
- Resolution: Removed all red-flag APIs, reframed as assistive dictation tool. See "Guideline 2.4.5 Compliance" section below.

### What's Implemented
- **Receipt Validation** (`Licensing/ReceiptValidator.swift`) — Validates App Store receipt on launch. Exits with code 173 on failure (triggers receipt refresh). Only runs in Release builds.
- **StoreKit 2 Integration** (`Store/StoreManager.swift`) — Pro Pack IAP infrastructure. Product ID: `com.ivy.whisperer.propack`.
- **Purchase UI** (`UI/PurchaseView.swift`) — Purchase flow with Restore Purchases.
- **Export Compliance** — `ITSAppUsesNonExemptEncryption = NO` in Info.plist (HTTPS only).
- **Privacy Policy** — Hosted at https://whispererapp.com/privacy/
- **Entitlements** — Cleaned: sandbox, network.client, audio-input, files.user-selected.read-write. Removed network.server.

## Guideline 2.4.5 Compliance

### What Was Removed
| API Removed | Replacement |
|-------------|-------------|
| `CGEvent.tapCreate` (keyboard event monitoring) | `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` for Fn key |
| `IOHIDManager` (hardware input monitoring) | Carbon `RegisterEventHotKey` for non-Fn shortcuts |
| Global `keyDown`/`keyUp` monitors | Removed entirely — not needed |
| Input Monitoring permission type | Removed from PermissionManager and UI |
| Fn calibration (cookie-based, IOKit HID) | Removed — Fn detected via flagsChanged keyCode 63 |

### What Was Kept (with justification)
| API Kept | Justification |
|----------|--------------|
| `AXUIElement` text injection | Core assistive function — inserts dictated text as assistive input |
| `CGEvent.post(tap: .cgAnnotatedSessionEventTap)` | Posts synthetic Cmd+V for clipboard fallback — posting ≠ monitoring |
| `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` | Monitors modifier state changes only, NOT keystrokes |
| Carbon `RegisterEventHotKey` | Standard macOS hotkey mechanism, used by many approved apps |

### Verification

Run `/app-store-check` for a full codebase scan, or `/submission-prep` for the complete pre-submission checklist.

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
NSMicrophoneUsageDescription = "Whisperer needs microphone access to transcribe your voice."
NSAppleEventsUsageDescription = "Whisperer needs automation access to insert transcribed text into applications."
```

## App Store Connect Configuration

| Field | Value |
|-------|-------|
| Bundle ID | `com.ivy.whisperer` |
| Category | Productivity (Primary) |
| SKU | `whisperer-macos-1` |
| Pro Pack Product ID | `com.ivy.whisperer.propack` |
| Pro Pack Type | Non-Consumable |
| Data Collection | "Data Not Collected" |

## Build & Archive

```bash
# Clean build
xcodebuild clean build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS"
```

In Xcode: Product -> Archive -> Distribute App -> App Store Connect -> Upload

## Pre-Submission Checklist

Run `/submission-prep` to execute the automated checklist. It covers:
- App Store compliance scan (banned APIs, framing, permissions)
- Conventions check
- Release build
- Info.plist and entitlements verification
- Reviewer notes generation

### Manual Testing (not automated)
- [ ] Receipt validation triggers exit(173) without receipt (expected)
- [ ] Pro Pack products load in Sandbox
- [ ] Purchase and Restore work in Sandbox
- [ ] Microphone and Accessibility permissions prompt correctly (NO Input Monitoring prompt)
- [ ] Model downloads successfully
- [ ] Transcription works end-to-end
- [ ] Text injection works in various apps (TextEdit, Safari, Notes)
- [ ] Clipboard fallback works when Accessibility is denied
- [ ] Hold-to-record with Fn key works
- [ ] Custom shortcuts work (Carbon hotkey path)
- [ ] Audio recovery works across multiple recording sessions

### App Store Connect (manual)
- [ ] Pricing set
- [ ] Pro Pack IAP created and submitted for review
- [ ] Privacy policy URL added
- [ ] Export compliance answered
- [ ] Screenshots uploaded (1280x800 or 1440x900)
- [ ] Description and keywords entered
- [ ] Build uploaded and processed
- [ ] Reviewer notes provided (generated by `/submission-prep`)

## Common Rejection Reasons & Lessons Learned

1. **Guideline 2.4.5 — Keystroke access** — CGEventTap, IOHIDManager, and global keyDown/keyUp monitors are red flags. Use flagsChanged for modifier keys and Carbon hotkeys for shortcuts instead.
2. **Guideline 2.4.5 — Accessibility misuse** — Frame AXUIElement usage as assistive text input, not automation. The usage description and reviewer notes must clearly state the assistive purpose.
3. **Permissions not explained** — Ensure NSMicrophoneUsageDescription is clear. Remove any permission types no longer used (we removed Input Monitoring entirely).
4. **App crashes** — Test audio engine recovery across multiple recording sessions. Validate audio format after `outputFormat(forBus:)` to catch device errors early.
5. **Privacy policy issues** — Verify URL works and is accurate
6. **IAP issues** — Test in Sandbox before production
7. **Missing functionality** — All advertised features must work

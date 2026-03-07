# App Store Submission Guide

## Current Status

Version 1.1 (4) — resubmission addressing Guideline 2.4.5 rejection of v1.1 (2). Accessibility is now fully optional with auto-paste opt-in (default OFF).

### Rejection History

**v1.0 (1) — Rejected (Guideline 2.4.5)**
- Apple flagged: "Your app uses Accessibility features for non-accessibility purposes" and "Your app accesses user keystrokes for purposes other than assistive accessibility features"
- Root cause: `CGEventTap`, `IOHIDManager`, global `keyDown`/`keyUp` monitors, and `CGEvent.post` for simulated paste
- Resolution: Removed all red-flag APIs, replaced with flagsChanged + Carbon hotkeys

**v1.1 (2) — Rejected (Guideline 2.4.5)**
- Apple flagged: "The app requests access to Accessibility features on macOS but does not use these features for accessibility purposes. Specifically, the app uses Accessibility features to dictate audio and transcribe to text."
- Root cause: Accessibility was still requested during onboarding, not truly optional
- Resolution: Made Accessibility fully optional with auto-paste opt-in (default OFF), lazy accessibility tracking, clipboard-only fallback as default mode

**v1.1 (3) — Rejected (Guideline 2.4.5)**
- Apple flagged: Same as v1.1 (2) — "The app requests access to Accessibility features on macOS but does not use these features for accessibility purposes."
- Root cause: Binary still contained "assistive" framing strings; Privacy Policy referenced removed Input Monitoring permission
- Resolution: Removed all "assistive" framing from binary strings, cleaned Privacy Policy, updated reviewer notes to explain CGEvent.post system requirement

### What's Implemented
- **Auto-Paste Opt-In** — Accessibility is optional (default OFF). App works fully with clipboard-only mode. User explicitly opts in via Settings toggle or onboarding.
- **Lazy Accessibility Tracking** — PermissionManager only checks AXIsProcessTrusted() when auto-paste is enabled
- **Receipt Validation** (`Licensing/ReceiptValidator.swift`) — Validates App Store receipt on launch. Exits with code 173 on failure (triggers receipt refresh). Only runs in Release builds.
- **StoreKit 2 Integration** (`Store/StoreManager.swift`) — Pro Pack IAP infrastructure. Product ID: `com.ivy.whisperer.propack`.
- **Purchase UI** (`UI/PurchaseView.swift`) — Purchase flow with Restore Purchases.
- **Export Compliance** — `ITSAppUsesNonExemptEncryption = NO` in Info.plist (HTTPS only).
- **Privacy Policy** — Hosted at https://whispererapp.com/privacy/
- **Entitlements** — Cleaned: sandbox, network.client, audio-input, files.user-selected.read-write. Removed network.server.

## Guideline 2.4.5 Compliance

### Auto-Paste Architecture (v1.1 build 3)

The app has two text delivery modes:

| Mode | Default? | Accessibility Required? | How It Works |
|------|----------|------------------------|--------------|
| Clipboard (default) | Yes | No | Text copied to clipboard, user presses Cmd+V |
| Auto-paste (opt-in) | No | Yes | Text copied + CGEvent.post simulates Cmd+V |

Accessibility is needed ONLY because `CGEvent.post()` requires `AXIsProcessTrusted()` to deliver synthetic keystrokes to other apps — a macOS system requirement. No AX elements are read, queried, or modified.

### Code-Level Opt-In Flow
1. `AppState.autoPasteEnabled` defaults to `false` (UserDefaults)
2. `PermissionManager.isAccessibilityTrackingEnabled` defaults to `false` — no polling
3. User enables auto-paste → `enableAccessibilityTracking()` called → `requestAccessibilityPermission()` triggered
4. `TextInjector.insertText()` guards: `autoPasteEnabled && hasAccessibilityPermission()` → else clipboard only

### Banned APIs (all removed)
| API Removed | Replacement |
|-------------|-------------|
| `CGEvent.tapCreate` (keyboard event monitoring) | `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` for Fn key |
| `IOHIDManager` (hardware input monitoring) | Carbon `RegisterEventHotKey` for non-Fn shortcuts |
| Global `keyDown`/`keyUp` monitors | Removed entirely — not needed |
| Input Monitoring permission type | Removed from PermissionManager and UI |
| `AXUIElementCopyAttributeValue` / `AXUIElementSetAttributeValue` | Removed — no AX element manipulation |

### Approved APIs
| API Kept | Justification |
|----------|--------------|
| `AXIsProcessTrusted()` | Permission check only — required by CGEvent.post |
| `CGEvent.post(tap: .cgAnnotatedSessionEventTap)` | Posts synthetic keyboard events for auto-paste — posting ≠ monitoring |
| `CGEvent.keyboardSetUnicodeString` | Sets unicode text payload on synthetic keyboard events — configures event data, not monitoring |
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
```

NOT present (intentionally removed): `NSAppleEventsUsageDescription`

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
- [ ] Microphone permission prompts correctly (NO Accessibility prompt unless auto-paste enabled)
- [ ] Accessibility prompt appears ONLY when user enables auto-paste
- [ ] Clipboard mode works without Accessibility (transcribe → text in clipboard → manual Cmd+V)
- [ ] Auto-paste works when enabled (transcribe → text appears at cursor)
- [ ] Model downloads successfully
- [ ] Transcription works end-to-end
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
- [ ] Response message pasted in reply to rejection

## Common Rejection Reasons & Lessons Learned

1. **Guideline 2.4.5 — Keystroke access** — CGEventTap, IOHIDManager, and global keyDown/keyUp monitors are red flags. Use flagsChanged for modifier keys and Carbon hotkeys for shortcuts instead.
2. **Guideline 2.4.5 — Accessibility misuse** — Making Accessibility optional is not enough if it's still prompted during onboarding. Must be truly opt-in with a working default mode that doesn't use it.
3. **Guideline 2.4.5 — Framing** — Explain WHY Accessibility is needed (CGEvent.post system requirement), not just WHAT it does. Apple needs to understand it's a platform limitation, not an architectural choice.
3. **Permissions not explained** — Ensure NSMicrophoneUsageDescription is clear. Remove any permission types no longer used (we removed Input Monitoring entirely).
4. **App crashes** — Test audio engine recovery across multiple recording sessions. Validate audio format after `outputFormat(forBus:)` to catch device errors early.
5. **Privacy policy issues** — Verify URL works and is accurate
6. **IAP issues** — Test in Sandbox before production
7. **Missing functionality** — All advertised features must work

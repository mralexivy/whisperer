# App Store Submission Guide

## Current Status

Version 1.1 (6) — resubmission with complete Accessibility removal from App Store build, fixed directive permission language, and hidden unfinished features. Dual-build architecture with `APP_STORE` compile flag. App Store build uses clipboard-only for text delivery.

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

**v1.1 (4) — Rejected (Guideline 5.1.1(iv) + Guideline 2.4.5)**
- **5.1.1(iv)**: "The app encourages or directs users to allow the app to access the microphone" — directive button text and skip button
- **2.4.5**: 4th rejection for Accessibility usage — "uses Accessibility features for non-accessibility purposes"
- Root causes: (1) Onboarding used directive "Grant Microphone Access" and offered "Set Up Later" skip; (2) Binary still contained `AXIsProcessTrusted`, `CGEvent.post`, and accessibility-related code paths regardless of opt-in
- Resolution: (1) Fixed button text to "Continue", removed skip button; (2) **Complete Accessibility removal** from App Store build via `APP_STORE` compile flag — zero AX APIs in the binary

**v1.1 (5) — Uploaded but superseded by v1.1 (6)**
- Build 5 still contained "Grant microphone access to start" text, "Set Up Later" button, and "Enable Auto-Paste to use" string in the binary
- Superseded by build 6 which fixes all remaining Guideline 5.1.1(iv) issues

### What's Implemented
- **Dual-Build Architecture** — `APP_STORE` flag in Release compilation conditions. App Store build has zero Accessibility code. Direct distribution build retains auto-paste.
- **Clipboard-Only Text Delivery** — App Store build copies transcribed text to clipboard. User pastes with Cmd+V. Clipboard toast with animated checkmark shows "Copied to Clipboard" with ⌘V hint.
- **Receipt Validation** (`Licensing/ReceiptValidator.swift`) — Validates App Store receipt on launch. Exits with code 173 on failure (triggers receipt refresh). Only runs in Release builds.
- **StoreKit 2 Integration** (`Store/StoreManager.swift`) — Pro Pack IAP infrastructure. Product ID: `com.ivy.whisperer.propack`.
- **Purchase UI** (`UI/PurchaseView.swift`) — Purchase flow with Restore Purchases.
- **Export Compliance** — `ITSAppUsesNonExemptEncryption = NO` in Info.plist (HTTPS only).
- **Privacy Policy** — Hosted at https://whispererapp.com/privacy/
- **Entitlements** — Cleaned: sandbox, network.client, audio-input, files.user-selected.read-write. Removed network.server.

## Guideline 2.4.5 Compliance

### Dual-Build Architecture (v1.1 build 6)

The `APP_STORE` compile flag (set in Release config) controls which text delivery mode is available:

| Build | Flag | Text Delivery | Accessibility APIs |
|-------|------|---------------|-------------------|
| App Store (Release) | `APP_STORE` | Clipboard-only | **None** — zero AX code in binary |
| Direct Distribution (Debug) | _(none)_ | Auto-paste via CGEvent.post + AX fallback | Full AX + CGEvent.post |

### APP_STORE Build — What's Removed
All Accessibility code is conditionally compiled out with `#if !APP_STORE`:

| Component | What's Removed |
|-----------|---------------|
| `TextInjector` | `hasAccessibilityPermission()`, `enterViaCGEventUnicode()`, `enterViaClipboardPaste()`, `simulatePaste()` |
| `TextSelectionService` | Entire file (wrapped in `#if !APP_STORE`) |
| `PermissionManager` | `PermissionType.accessibility`, all AX tracking/checking methods, `AXIsProcessTrusted` calls |
| `AppState` | `autoPasteEnabled` property, accessibility recheck observer, rewrite shortcut callbacks, rewrite state routing |
| `WhispererApp` | Auto-paste toggle, accessibility permission UI, accessibility badges, AI Post-Processing settings |
| `OnboardingView` | Accessibility page, "Set Up Later" → "Continue", "Grant Microphone Access" → informational text |
| `SetupChecklistView` | "Enable Auto-Paste" checklist item |
| `OverlayView` | Rewrite mode label, rewrite accent color |
| `HistoryWindowView` | Rewrite section, Command Mode sidebar, Feedback sidebar |

### APP_STORE Build — What's Added
- **Clipboard toast** — `ClipboardToastIndicator` with animated green checkmark, "Copied to Clipboard" text, and ⌘V keycap hint
- **Clipboard-only `insertText()`** — Always copies to clipboard + posts `TextCopiedToClipboard` notification

### What's Been Removed Entirely (not just hidden)
- **macOS Services** — `DictationServiceProvider` deleted, `NSServices` removed from Info.plist (was pointless — still required manual menu interaction)

### APIs in App Store Binary
| API | Present? | Purpose |
|-----|----------|---------|
| `AXIsProcessTrusted()` | **No** | Removed via compile flag |
| `CGEvent.post` | **No** | Removed via compile flag |
| `AXUIElement*` | **No** | Removed via compile flag |
| `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` | Yes | Modifier state changes for Fn key — not keystrokes |
| Carbon `RegisterEventHotKey` | Yes | Standard macOS hotkey mechanism |

### Binary Verification
```bash
# After Release build, verify no banned APIs or strings in binary:
/usr/bin/strings .../whisperer.app/Contents/MacOS/whisperer | grep -iE "AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive"
# Should return empty
```

## Guideline 5.1.1(iv) Compliance

### Fixed in v1.1 (6)
- ~~"Grant Microphone Access"~~ → **"Continue"**
- ~~"Set Up Later"~~ skip button → **"Continue"** (user always proceeds to system dialog)
- ~~"Grant Permissions"~~ → **"Open Permissions"**
- ~~"Grant microphone access to start"~~ → **"Microphone access is needed to transcribe"** (informational)
- ~~"Enable Auto-Paste to use"~~ → removed from App Store binary entirely

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

NOT present (intentionally removed): `NSAppleEventsUsageDescription`, `NSServices`

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
# Archive for App Store (MUST use these overrides)
xcodebuild clean archive -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS" -archivePath build/whisperer.xcarchive ARCHS=arm64 CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements ENABLE_APP_SANDBOX=YES

# Upload to App Store Connect
xcodebuild -exportArchive -archivePath build/whisperer.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
```

CRITICAL: Always use `ARCHS=arm64` (FluidAudio fails on x86_64), `CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements` (sandbox), `ENABLE_APP_SANDBOX=YES`.

In Xcode: Product -> Archive -> Distribute App -> App Store Connect -> Upload

## Pre-Submission Checklist

Run `/submission-prep` to execute the automated checklist. It covers:
- App Store compliance scan (banned APIs, framing, permissions, directive language)
- Binary string verification
- Conventions check
- Release build
- Info.plist and entitlements verification
- Reviewer notes generation

### Manual Testing (not automated)
- [ ] Receipt validation triggers exit(173) without receipt (expected)
- [ ] Pro Pack products load in Sandbox
- [ ] Purchase and Restore work in Sandbox
- [ ] Microphone permission prompts correctly (NO Accessibility prompt at all)
- [ ] NO "Grant" buttons, NO "Set Up Later" buttons anywhere
- [ ] Clipboard mode works (transcribe → text in clipboard → manual Cmd+V)
- [ ] Clipboard toast shows with animated checkmark and ⌘V hint
- [ ] Model downloads successfully
- [ ] Transcription works end-to-end
- [ ] Hold-to-record with Fn key works
- [ ] Custom shortcuts work (Carbon hotkey path)
- [ ] Audio recovery works across multiple recording sessions
- [ ] Command Mode NOT visible in workspace sidebar
- [ ] AI Post-Processing NOT visible in menu bar settings
- [ ] Rewrite Mode NOT visible anywhere
- [ ] Feedback NOT visible in workspace sidebar

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
2. **Guideline 2.4.5 — Accessibility misuse** — Making Accessibility optional is NOT enough. Apple rejected it 3 times as "optional". Must be COMPLETELY REMOVED from the App Store binary. Zero AX code.
3. **Guideline 2.4.5 — Binary contents matter** — Even if code is unreachable, strings like "assistive", "auto-paste", "AXIsProcessTrusted" in the binary can trigger rejection. Always verify with `strings` command.
4. **Guideline 5.1.1(iv) — Directive language** — NEVER use "Grant [Permission]" on buttons. Use "Continue" or "Next". NEVER have skip/delay buttons ("Set Up Later") before permission requests. Descriptive text must be informational, not directive.
5. **Permissions not explained** — Ensure NSMicrophoneUsageDescription is clear. Remove any permission types no longer used.
6. **App crashes** — Test audio engine recovery across multiple recording sessions.
7. **Privacy policy issues** — Verify URL works and is accurate.
8. **IAP issues** — Test in Sandbox before production.
9. **Missing functionality** — All advertised features must work. Hide unfinished features with `#if !APP_STORE`.
10. **Compile flag gotcha** — `ENABLE_APP_SANDBOX` is a build setting, NOT a Swift compile flag. Use `APP_STORE` for `#if` checks in Swift code.

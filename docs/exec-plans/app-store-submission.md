# App Store Submission Guide

## Current Status

**Version 2.0 (1)** — first submission since v1.1 (6) on March 11, 2026. Adds Meeting Notes, the
Island UI, Qwen3 ASR, the MCP server, four additional engines, audio archiving, file transcription,
speculative decoding, and "Open at Login".

The governing principle for this release: **every feature ships, made compliant.** No feature is
hidden to dodge review. The only things that stay compiled out are the Accessibility and
`CGEvent.post` paths, which Apple rejected four times.

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
- Apple flagged: Same as v1.1 (2)
- Root cause: Binary still contained "assistive" framing strings; Privacy Policy referenced removed Input Monitoring permission
- Resolution: Removed all "assistive" framing from binary strings, cleaned Privacy Policy

**v1.1 (4) — Rejected (Guideline 5.1.1(iv) + Guideline 2.4.5)**
- **5.1.1(iv)**: "The app encourages or directs users to allow the app to access the microphone" — directive button text and skip button
- **2.4.5**: 4th rejection for Accessibility usage
- Resolution: (1) Button text to "Continue", removed skip button; (2) **Complete Accessibility removal** from the App Store build via the `APP_STORE` compile flag

**v1.1 (5) — Uploaded but superseded by v1.1 (6)**
- Build 5 still contained "Grant microphone access to start", "Set Up Later", and "Enable Auto-Paste to use" in the binary

**v1.1 (6) — Approved baseline.** The version this release diffs against (commit `be697d0`).

## What Changed in 2.0

### Guideline 2.1 defect found and fixed

In v1.1 (6) the meeting detector ran end to end in the App Store build — monitors started,
candidates were scored, hits were logged — but the **entire notification surface was compiled out**.
`AppState.showMeetingDetectedToast` was a `{ false }` stub and the three call sites in
`MeetingDetector` were gated. The detector fired into the void. The Meeting Detection settings card
was also gated, so there was no way to even configure it.

Fixed by ungating the notification surface, the `MeetingNotificationCard`, its `OverlayView` host,
and the Meeting Detection settings card. The AI Post-Processing card, which shared the same gate,
stays hidden.

### Camera signal made opt-in

`cameraMonitor.start()` was **not** gated, so the build could trigger a camera TCC prompt for a
feature that never captures a frame and produced no visible result. Now gated behind
`AppState.cameraDetectionEnabled`, off by default, with a toggle in Meeting settings.

### Guideline 2.5.14 consent added

`MeetingConsentView` is shown before the first meeting recording. It states what is recorded
(microphone only), where it is stored, that nothing leaves the Mac, and that the user is
responsible for obtaining consent from other participants where the law requires it. Persisted as
`hasConsentedToMeetingRecording`. No recording path runs without it.

### MCP server hardened

- `mcpEnabled` now defaults to **false**. A fresh install serves nothing.
- Every request requires a **bearer token** (`AppState.mcpBearerToken`, a persisted UUID).
  `MCPSessionRegistry.route()` returns 401 without it.
- `MCPClientInstaller` writes the token into the generated client config.
- Loopback-only unless the user explicitly enables LAN.

## Guideline 2.4.5 Compliance

### Dual-Build Architecture

| Build | Flag | Text Delivery | Accessibility APIs |
|-------|------|---------------|-------------------|
| App Store (Release) | `APP_STORE` | Clipboard-only | **None** — zero AX code in binary |
| Direct Distribution (Debug) | _(none)_ | Auto-paste via CGEvent.post + AX fallback | Full AX + CGEvent.post |

### What stays removed in the APP_STORE build

| Component | What's Removed |
|-----------|---------------|
| `TextInjector` | `hasAccessibilityPermission()`, `enterViaCGEventUnicode()`, `enterViaClipboardPaste()`, `simulatePaste()` |
| `TextSelectionService` | Entire file |
| `PermissionManager` | `PermissionType.accessibility`, all AX tracking, `AXIsProcessTrusted` calls |
| `AppState` | `autoPasteEnabled`, accessibility recheck observer, rewrite shortcut callbacks |
| `WhispererApp` | Auto-paste toggle, accessibility UI, AI Post-Processing card |
| `MeetingDetector` | `detectBrowserMeeting` (AX window-title reading), AX diagnostics |
| `OnboardingView` | Accessibility page, directive button text |
| `OverlayView` | Rewrite mode label and accent color |
| `HistoryWindowView` | Rewrite section, Command Mode sidebar, Feedback sidebar |

### APIs in the App Store binary

| API | Present? | Purpose |
|-----|----------|---------|
| `AXIsProcessTrusted()` | **No** | Removed via compile flag |
| `CGEvent.post` | **No** | Removed via compile flag |
| `AXUIElement*` | **No** | Removed via compile flag |
| `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` | Yes | Modifier state for Fn key — not keystrokes |
| Carbon `RegisterEventHotKey` | Yes | Standard macOS hotkey mechanism |
| CoreAudio process-object properties | Yes | Read-only meeting detection, no TCC grant |

## Entitlements

Every entitlement maps to a call site and a user-facing feature.

| Entitlement | Why | User-facing feature |
|---|---|---|
| `com.apple.security.app-sandbox` | Required for the App Store | — |
| `com.apple.security.network.client` | Model weight downloads | Engine and model downloads |
| `com.apple.security.network.server` | `NWListener` in `WhispererMCPServer` | MCP Server settings card |
| `com.apple.security.files.user-selected.read-write` | `NSOpenPanel` file picker | File transcription |
| `com.apple.security.device.audio-input` | Microphone capture | Dictation and Meeting Notes |
| `com.apple.security.device.camera` | `CameraUsageMonitor` presence check | Opt-in meeting detection booster |
| `com.apple.security.files.user-selected.read-only` | Added by Xcode's `ENABLE_USER_SELECTED_FILES`, not by the entitlements file | File picker |

The signed binary carries one entitlement that is **not** in `whisperer.entitlements`:
`files.user-selected.read-only`. Xcode injects it from the `ENABLE_USER_SELECTED_FILES` build
setting. It is legitimate and covered by the same file-picker justification, but expect it when
diffing `codesign -d --entitlements` output against the file.

**Note:** earlier revisions of this guide said `network.server` was "intentionally removed". That is
stale. It is present, required by the MCP server, and justified above.

## Info.plist Keys

```xml
ITSAppUsesNonExemptEncryption = NO
CFBundleShortVersionString = 2.0
CFBundleVersion = 1
NSMicrophoneUsageDescription = "Whisperer needs microphone access to transcribe your voice."
NSCameraUsageDescription = "Whisperer checks whether your camera is in use so it can tell a video
  call apart from an app that is only using the microphone. Whisperer never records or views
  camera video."
```

NOT present (intentionally): `NSAppleEventsUsageDescription`, `NSServices`

## Engine Test Matrix

All seven `BackendType` cases ship and stay user-selectable. Test each **in the Release
configuration on arm64**, not Debug. A reviewer selecting an engine that fails is a 2.1 rejection.

| Engine | Availability gate | Verify |
|---|---|---|
| Qwen3 ASR (default) | arm64 + `Qwen3ASRBridge.isModelCached()` | Download → warm → dictate → meeting |
| Whisper (whisper.cpp) | Always `true` | Dictate, `.auto` language path, non-arm64 fallback |
| Parakeet | arm64 | Dictate |
| Nemotron | arm64 | Dictate |
| Nemotron Hebrew | arm64 | Hebrew dictate + RTL rendering |
| Apple Speech | `#available(macOS 26.0)` | Dictate on 26+; graceful no-op below |
| WhisperKit | `canImport(WhisperKit)` + arm64 | Dictate if present; graceful no-op if absent |

`BackendType.defaultBackend(for:)` returns whisper.cpp when Qwen3 weights are absent, so a cold
first launch is never a dead end.

## Model Licenses

All downloadable model weights permit commercial use. Full audit with sources and dates:
`docs/references/model-licenses.md`. The in-app Acknowledgements screen
(`Whisperer/UI/AcknowledgementsView.swift`, reachable from Settings → Links) lists each model,
author, and license. Parakeet is CC-BY-4.0 and **requires attribution**, which the
Acknowledgements screen provides.

## Build & Archive

```bash
xcodebuild clean archive -project Whisperer.xcodeproj -scheme whisperer \
  -configuration AppStore -destination "platform=macOS" \
  -archivePath build/whisperer.xcarchive \
  ARCHS=arm64 \
  CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements \
  ENABLE_APP_SANDBOX=YES

xcodebuild -exportArchive -archivePath build/whisperer.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
```

**CRITICAL — use `-configuration AppStore`, not `Release`.** There are three configurations and
only **AppStore** sets the `APP_STORE` flag
(`SWIFT_ACTIVE_COMPILATION_CONDITIONS = "APP_STORE $(inherited)"`). Revisions of this guide before
2.0 said `Release`, which is wrong: a Release archive still contains `autoPaste`,
`Enable Auto-Paste`, and `AXUIElement` in the binary. That is precisely what got v1.1 (3) and
v1.1 (5) rejected. Verified on 2026-10-13 by archiving both ways and running `strings`.

| Configuration | `APP_STORE` | Use for |
|---|---|---|
| Debug | no | Development |
| Release | no | Direct distribution outside the App Store |
| **AppStore** | **yes** | **App Store submission** |

Also always `ARCHS=arm64` (FluidAudio fails on x86_64),
`CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements`, `ENABLE_APP_SANDBOX=YES`.

## Binary Verification

```bash
# No banned APIs or strings
/usr/bin/strings build/export/whisperer.app/Contents/MacOS/whisperer | \
  grep -iE "AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|assistive"
# must be empty

# No stale legal text in bundled resources
grep -riE "accessibility|auto.?paste|input monitoring" build/export/whisperer.app/Contents/Resources/ 2>/dev/null
# must be empty

# Entitlements match
codesign -d --entitlements - build/export/whisperer.app 2>&1
```

## Pre-Submission Checklist

Run `/app-store-check` and `/conventions-check`. Then:

### Manual Testing (reset TCC first)

```bash
tccutil reset All com.ivy.whisperer
```

- [ ] First launch prompts for **microphone only**. No camera prompt. No Accessibility prompt.
- [ ] Enabling "Also use camera activity to detect meetings" prompts for camera with the new purpose string.
- [ ] Meeting detection fires a visible notification when Zoom/Teams/Meet starts.
- [ ] The first meeting recording shows the consent modal. Declining prevents recording.
- [ ] The recording indicator stays visible for the whole recording and cannot be concealed.
- [ ] MCP is **off** on first launch. `curl http://localhost:8080/mcp` without a token returns 401.
- [ ] `MCPClientInstaller`'s generated config works (token included).
- [ ] Each of the seven engines downloads, warms, and transcribes without crashing.
- [ ] Privacy Policy and Terms of Use links open live pages that match shipping behavior.
- [ ] Pro Pack purchase and restore work in Sandbox; receipt validation exits 173 without a receipt.
- [ ] "Open at Login" registers/unregisters; System Settings → Login Items reflects it.
- [ ] Acknowledgements screen opens and lists every shipped model.

### App Store Connect

- [ ] Pricing set
- [ ] Pro Pack IAP created and submitted
- [ ] Privacy policy URL (`https://whispererapp.com/privacy`) live and returning 200
- [ ] Terms of use URL (`https://whispererapp.com/terms`) live and returning 200
- [ ] Export compliance answered
- [ ] Screenshots uploaded — include the MCP settings card and Meeting Notes
- [ ] Reviewer notes provided

## Reviewer Notes — what to say

- **Camera:** Requested for an opt-in meeting-detection booster. Off by default. Whisperer checks
  only whether the camera is in use and never captures a frame.
- **MCP server:** A user-facing feature with its own settings card. It serves the user's own
  transcript history to AI tools they already use. Off by default, loopback-only by default,
  token-authenticated. LAN is a separate explicit opt-in. `network.server` is required for
  `NWListener`.
- **Model downloads:** Speech and language model **weights** (data), not executable code. The
  inference engines are compiled into the reviewed binary. Satisfies Guideline 2.5.2.
- **Meeting consent:** A consent screen is shown before the first recording, and a recording
  indicator stays visible throughout. Satisfies Guideline 2.5.14.
- **Zero Accessibility APIs:** verified with `strings`.
- **Framing:** a productivity tool for developers and knowledge workers.

**Never include:** compile flags (`APP_STORE`, `ENABLE_APP_SANDBOX`), the dual-build architecture,
or any other internal build detail. **Never** frame the app as assistive or disability-related.

## Lessons Learned

1. **Guideline 2.4.5 — keystroke access.** `CGEventTap`, `IOHIDManager`, and global keyDown/keyUp
   monitors are red flags. Use flagsChanged and Carbon hotkeys.
2. **Guideline 2.4.5 — Accessibility misuse.** Making it optional is not enough. Apple rejected
   "optional" three times. It must be absent from the binary.
3. **Guideline 2.4.5 — binary contents matter.** Unreachable code still leaves strings. Verify with
   `strings`.
4. **Guideline 5.1.1(iv) — directive language.** Never "Grant [Permission]" on a button. Never a
   skip button before a permission request.
5. **Guideline 2.1 — a gated feature is worse than no feature.** Compiling out a notification
   surface while leaving the engine running produces a feature that does nothing. If a feature
   cannot ship, remove its entry points too; if it can, ship it whole.
6. **Never request a permission a feature cannot visibly use.** A camera prompt for an invisible
   feature invites a rejection.
7. **Guideline 2.5.14 — recording needs consent and a visible indicator**, for the whole duration.
8. **Compile flag gotcha.** `ENABLE_APP_SANDBOX` is a build setting, not a Swift compile flag. Use
   `APP_STORE` for `#if`.

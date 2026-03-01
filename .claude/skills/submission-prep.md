# Submission Prep — Pre-App Store Submission Checklist

Run through all automated checks, build, archive, upload, and generate App Store metadata.

## Step 1: Run App Store Compliance Check

Scan the entire `Whisperer/` directory for Guideline 2.4.5 violations (banned APIs, framing issues, permission red flags). Follow the same checks as `/app-store-check`. If ANY violations found, stop and report — do not proceed to build.

## Step 2: Run Conventions Check

Scan recently changed Swift files for coding convention violations (print statements, memory safety, threading). Follow the same checks as `/conventions-check`.

## Step 3: Verify Info.plist Configuration

Read `Whisperer/Info.plist` and verify:
- [ ] `NSMicrophoneUsageDescription` is present and says "transcribe your voice"
- [ ] `ITSAppUsesNonExemptEncryption` is `false`
- [ ] `LSUIElement` is `true` (menu bar app)
- [ ] `CFBundleShortVersionString` and `CFBundleVersion` are set
- [ ] No `NSAppleEventsUsageDescription` (was removed for compliance)

## Step 4: Verify Entitlements

Read `Whisperer/whisperer.entitlements` and verify:
- [ ] `com.apple.security.app-sandbox` is `true`
- [ ] `com.apple.security.network.client` is `true`
- [ ] `com.apple.security.device.audio-input` is `true`
- [ ] `com.apple.security.files.user-selected.read-write` is `true`
- [ ] No unexpected entitlements present (especially `network.server`)

## Step 5: Verify Permissions Configuration

Read `Whisperer/Permissions/PermissionManager.swift` and verify:
- [ ] `PermissionType` enum has exactly two cases: `microphone` and `accessibility`
- [ ] No references to `inputMonitoring` or Input Monitoring
- [ ] `requiredPermissionsGranted` only requires Accessibility when `systemWideDictationEnabled` is true
- [ ] Accessibility is optional — app works without it

## Step 6: Verify TextInjector (Clipboard-Only Architecture)

Read `Whisperer/TextInjection/TextInjector.swift` and verify:
- [ ] No `AXUIElementCopyAttributeValue` calls (MUST be removed)
- [ ] No `AXUIElementSetAttributeValue` calls (MUST be removed)
- [ ] No `getFocusedElement` or `insertIntoElement` methods
- [ ] Text entry uses clipboard + paste only: `NSPasteboard` → `CGEvent.post` (Cmd+V)
- [ ] `AXIsProcessTrusted` used only to check permission, not to manipulate elements
- [ ] Language uses "enter/entry" not "inject/insert" in user-facing strings

## Step 7: Verify System-Wide Dictation is Opt-In

Read `Whisperer/AppState.swift` and verify:
- [ ] `systemWideDictationEnabled` defaults to `false`
- [ ] Key listener is only created when `systemWideDictationEnabled` is `true`
- [ ] `startGlobalDictation()` / `stopGlobalDictation()` lifecycle is correct

## Step 8: Verify Onboarding Flow

Read `Whisperer/UI/OnboardingView.swift` and `Whisperer/UI/OnboardingWindow.swift`:
- [ ] Onboarding shows on first launch when `hasCompletedOnboarding` is false
- [ ] Onboarding requests Microphone permission (required)
- [ ] System-wide dictation page is labeled "Optional"
- [ ] "Enable System-Wide Dictation" and "Set Up Later" buttons both present
- [ ] Accessibility permission text says "detect shortcut key and paste transcribed text"
- [ ] Onboarding sets `hasCompletedOnboarding = true` on completion
- [ ] No banned APIs used in onboarding

## Step 9: Verify App Icon

Check `Whisperer/Assets.xcassets/AppIcon.appiconset/`:
- [ ] All 10 macOS icon sizes present (16, 16@2x, 32, 32@2x, 128, 128@2x, 256, 256@2x, 512, 512@2x)
- [ ] Icons use dark navy background with blue-purple gradient waveform
- [ ] `Contents.json` references all filenames correctly

## Step 10: Bump Version

Ask the user whether to bump minor version (e.g., 1.1 → 1.2) or just build number.
Update in BOTH places:
- `Whisperer/Info.plist`: `CFBundleShortVersionString` and `CFBundleVersion`
- `Whisperer.xcodeproj/project.pbxproj`: `MARKETING_VERSION` (both Debug and Release) and `CURRENT_PROJECT_VERSION` (both Debug and Release)

## Step 11: Build Release

```bash
xcodebuild clean build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS" 2>&1
```

Report build result (success/failure) and warning count. If build fails, stop and report errors.

## Step 12: Archive

```bash
xcodebuild archive -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "generic/platform=macOS" -archivePath build/Whisperer.xcarchive 2>&1
```

Do NOT pass `CODE_SIGN_IDENTITY` — the project uses automatic signing. If archive fails, report errors.

## Step 13: Export & Upload to App Store Connect

Create `build/ExportOptions.plist` if it doesn't exist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>8NM6EHZB4G</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
```

Then export and upload:

```bash
xcodebuild -exportArchive -archivePath build/Whisperer.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates 2>&1
```

Verify output contains "EXPORT SUCCEEDED" and "Upload succeeded".

## Step 14: Generate Submission Summary

Output a summary with:

### Build Status
- Release build: PASS/FAIL
- Warning count: N
- Conventions violations: N

### Compliance Status
- Banned APIs found: YES/NO
- Permissions correct: YES/NO
- Entitlements correct: YES/NO
- Info.plist correct: YES/NO
- TextInjector clipboard-only: YES/NO
- System-wide dictation opt-in: YES/NO

### Version Info
- Version: (from Info.plist)
- Build: (from Info.plist)

### Upload Status
- Archive: PASS/FAIL
- Upload to App Store Connect: PASS/FAIL

### Reviewer Notes
Generate reviewer notes using this template (MUST be under 4000 characters). Fill in current version:

```
Thank you for your feedback. v{VERSION} makes significant architectural changes to address every Guideline 2.4.5 concern.

WHAT IS WHISPERER:
An assistive dictation tool — an alternative text input method for users who cannot or prefer not to type (RSI, carpal tunnel, mobility limitations, temporary injuries, or anyone who works faster by voice). It provides the same "dictate anywhere you can type" capability as Apple's built-in Dictation, but runs a local Whisper AI model for 100% offline, private transcription. No data ever leaves the Mac.

ALL FLAGGED APIs REMOVED:
Every API cited in the rejection has been deleted from source and binary:
• CGEventTap/CGEventTapCreate — REMOVED. No event taps of any kind.
• IOHIDManager/IOKit HID — REMOVED. No hardware-level monitoring.
• NSEvent globalMonitor with keyDown/keyUp — REMOVED. No keystroke monitoring.
• Input Monitoring permission — REMOVED entirely.
• AXUIElementCopyAttributeValue — REMOVED. We no longer read AX element attributes.
• AXUIElementSetAttributeValue — REMOVED. We no longer write to AX elements.
• NSAppleEventsUsageDescription — REMOVED from Info.plist.
None of these symbols exist in our binary.

KEY ARCHITECTURAL CHANGES:
1. System-wide dictation is OPT-IN (default OFF). A 4-page onboarding guides first-run setup. The final page presents dictation as explicitly "Optional" with "Enable" and "Set Up Later" buttons. The core app — recording, transcription, history, clipboard copy — works fully without it and without Accessibility.

2. Text entry rewritten — clipboard+paste ONLY. All direct AX element manipulation removed. The mechanism is now: copy transcription to NSPasteboard → post one Cmd+V via CGEvent.post. Same clipboard-paste approach as macOS built-in Dictation. No AX elements are read, queried, or modified.

PERMISSIONS — WHY EACH IS NEEDED:

1. Microphone (required)
Records voice for on-device speech-to-text — the core function of a dictation app. Audio captured only while user holds their trigger key. All processing runs locally via whisper.cpp (MIT licensed). No audio ever transmitted.

2. Accessibility (optional — only when user enables system-wide dictation)
CGEvent.post requires AXIsProcessTrusted() to deliver a Cmd+V paste keystroke to the frontmost app. That is the sole reason this permission is needed. We post one paste event so dictated text appears where the user is typing — the same assistive behavior as Apple's built-in Dictation and Voice Control.
Without Accessibility: app still works fully. Transcriptions copy to clipboard for manual paste.

SHORTCUT DETECTION (no keystroke monitoring):
• Fn key: NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) — modifier state only. Detects Fn press/release via keyCode 63. No typed characters observed.
• Custom shortcuts: Carbon RegisterEventHotKey — standard macOS hotkey API. No Input Monitoring needed.

DOES NOT: create event taps • use IOKit HID • monitor keystrokes • read/write AX elements • log or transmit input • require Input Monitoring • use ChatGPT/OpenAI cloud

HOW TO TEST:
Core (no Accessibility): Launch → onboarding → grant Microphone → "Set Up Later" → menu bar → record → speak → transcription appears → copy to clipboard.
System-wide (optional): Settings → enable System-Wide Dictation → grant Accessibility → TextEdit → hold Fn → speak → release → text at cursor.
Tip: Set Globe key to "Do Nothing" in System Settings → Keyboard → Modifier Keys.

NO SIGN-IN REQUIRED — uncheck "Sign-in required."
PRIVACY: 100% offline. No data transmitted. No accounts. No analytics.
EXPORT: HTTPS only (exempt). No proprietary encryption.
CHINA (Guideline 5): No ChatGPT/OpenAI cloud. whisper.cpp runs on-device. No network needed. Previous "OpenAI" metadata removed.
IAP: com.ivy.whisperer.propack
```

### App Store Description
Generate the App Store description using this template:

```
Whisperer is a fast, completely offline voice-to-text app for macOS. Record voice memos, transcribe audio, and dictate text — all processed locally on your Mac. Nothing ever leaves your device.

THREE WAYS TO USE

1. Quick Transcription
Click the menu bar icon, tap record, and speak. Your transcription appears instantly — copy it anywhere you need.

2. Voice Memo & History
Record longer passages and review them later in the Workspace. Every transcription is saved with audio playback, word count, and language metadata.

3. System-Wide Dictation (Optional)
Hold the Fn key in any app — Notes, Slack, VS Code, Safari — speak naturally, and release. Your transcribed text appears at the cursor. Enable this optional feature during onboarding or later in Settings.

100% PRIVATE & OFFLINE
All transcription runs locally on your Mac using whisper.cpp, a high-performance open-source speech recognition engine. Your voice never leaves your device. No cloud processing, no accounts, no subscriptions.

APPLE SILICON OPTIMIZED
Built for speed with Metal GPU acceleration. The recommended Large V3 Turbo model delivers exceptional accuracy with real-time transcription on Apple Silicon Macs.

LIVE PREVIEW
Watch your words appear as you speak with streaming transcription. A floating overlay shows your audio waveform and progress in real time.

10 WHISPER MODELS
Choose the perfect balance of speed, size, and accuracy:
• Large V3 Turbo Q5 (Recommended) — Best balance of speed and accuracy
• Tiny to Large V3 — From 75MB to 2.9GB
• English-optimized variants for native speakers

100+ LANGUAGES
Transcribe in over 100 languages. Set your preferred language or let the app auto-detect.

SMART RECORDING
• Hold-to-Record or Toggle mode
• Customizable keyboard shortcuts (Fn key or any key combination)
• Audio muting — optionally mutes other audio while recording
• Audio feedback — distinct sounds confirm recording start and stop
• Voice Activity Detection for improved accuracy

THOUGHTFUL DESIGN
• Lives in your menu bar — always available, never in the way
• Guided onboarding — set up permissions, download a model, and start dictating in minutes
• Workspace — browse, search, and manage your transcription history
• Custom dictionary — teach the app names, terms, and jargon

REQUIREMENTS
• macOS 13.0 (Ventura) or later
• ~2GB disk space for recommended model
• Apple Silicon recommended (Intel Macs supported)

PERMISSIONS
• Microphone — to record your voice for transcription
• Accessibility (optional) — to paste transcribed text at your cursor when using system-wide dictation

All processing happens locally. Your data stays on your Mac.
```

### Promotional Text

```
Offline voice-to-text transcription powered by Whisper AI with Apple Silicon acceleration. Record, transcribe, and dictate — 100% private, no cloud, no subscription.
```

### Keywords

```
voice to text,speech-to-text,dictation,transcription,whisper,offline,privacy,voice memo,accessibility,assistive
```

### Ready to Submit?
- If all checks pass and upload succeeded: "Build uploaded to App Store Connect. Copy reviewer notes into App Store Connect → App Information → Notes for Reviewer. Update Description, Promotional Text, and Keywords if changed."
- If any checks fail: "NOT ready — fix the issues above before submitting."

---
name: submission-prep
description: >
  Complete pre-App Store submission workflow: compliance scan, conventions
  check, Info.plist verification, entitlements validation, version bump,
  release build, archive, upload to App Store Connect, and reviewer notes
  generation. Use when preparing a build for App Store submission. Use when
  user says "submit to App Store", "prepare submission", "build for release",
  "generate reviewer notes", "upload to App Store Connect", or "prep for
  review".
metadata:
  version: 2.0.0
  category: deployment
  tags: [app-store, submission, release, build]
---

# Submission Prep — Pre-App Store Submission Checklist

Run through all automated checks, build, archive, upload, and generate App Store metadata.

## Instructions

### Step 1: Run App Store Compliance Check

Scan the entire `Whisperer/` directory for Guideline 2.4.5 violations (banned APIs, framing issues, permission red flags). Follow the same checks as the `app-store-check` skill. If ANY violations found, stop and report — do not proceed to build.

### Step 2: Run Conventions Check

Scan recently changed Swift files for coding convention violations (print statements, memory safety, threading). Follow the same checks as `/conventions-check`.

### Step 3: Verify Info.plist Configuration

Read `Whisperer/Info.plist` and verify:
- [ ] `NSMicrophoneUsageDescription` is present and says "transcribe your voice"
- [ ] `ITSAppUsesNonExemptEncryption` is `false`
- [ ] `LSUIElement` is `true` (menu bar app)
- [ ] `CFBundleShortVersionString` and `CFBundleVersion` are set
- [ ] No `NSAppleEventsUsageDescription` (was removed for compliance)
- [ ] No `NSServices` block (macOS Services were removed)

### Step 4: Verify Entitlements

Read `Whisperer/whisperer.entitlements` and verify:
- [ ] `com.apple.security.app-sandbox` is `true`
- [ ] `com.apple.security.network.client` is `true`
- [ ] `com.apple.security.device.audio-input` is `true`
- [ ] `com.apple.security.files.user-selected.read-write` is `true`
- [ ] No unexpected entitlements present (especially `network.server`)

### Step 5: Verify APP_STORE Compile Flag Removes All Accessibility

The App Store build uses `APP_STORE` compile flag (NOT `ENABLE_APP_SANDBOX` — that's a build setting, not a Swift flag). Verify these are wrapped with `#if !APP_STORE`:
- [ ] `TextInjector`: `hasAccessibilityPermission()`, `enterViaCGEventUnicode()`, `enterViaClipboardPaste()`, `simulatePaste()`
- [ ] `TextSelectionService`: entire file
- [ ] `PermissionManager`: `PermissionType.accessibility`, all AX tracking/checking methods
- [ ] `AppState`: `autoPasteEnabled` property, accessibility recheck observer, rewrite shortcut callbacks, rewrite state routing
- [ ] `WhispererApp`: Auto-paste toggle, accessibility permission UI, AI Post-Processing settings card
- [ ] `OnboardingView`: Accessibility page removed (no "Set Up Later" button)
- [ ] `SetupChecklistView`: "Enable Auto-Paste" checklist item
- [ ] `OverlayView`: Rewrite mode label, rewrite accent color
- [ ] `HistoryWindowView`: Rewrite section, Command Mode sidebar item, Feedback sidebar item

### Step 6: Verify Permission Request Language (Guideline 5.1.1(iv))

Apple rejects directive permission language. Search for:
- [ ] No "Grant Microphone Access" or "Grant [anything]" on buttons — use "Continue" or "Open Permissions"
- [ ] No "Set Up Later" or skip/delay buttons before permission requests
- [ ] No "Enable Auto-Paste to use" strings in App Store binary
- [ ] Descriptive text before permission is informational only, not directive

### Step 7: Verify Onboarding Flow

Read `Whisperer/UI/OnboardingView.swift`:
- [ ] Microphone page button says "Continue" (NOT "Grant Microphone Access")
- [ ] No skip/delay button before permission dialog (NO "Set Up Later")
- [ ] No Accessibility page in App Store build
- [ ] Onboarding sets `hasCompletedOnboarding = true` on completion

### Step 8: Verify App Icon

Check `Whisperer/Assets.xcassets/AppIcon.appiconset/`:
- [ ] All 10 macOS icon sizes present
- [ ] Icons use dark navy background with blue-purple gradient waveform
- [ ] `Contents.json` references all filenames correctly

### Step 9: Bump Version

Ask the user whether to bump minor version or just build number.
Update in BOTH places:
- `Whisperer/Info.plist`: `CFBundleShortVersionString` and `CFBundleVersion`
- `Whisperer.xcodeproj/project.pbxproj`: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`

### Step 10: Archive

```bash
xcodebuild clean archive -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS" -archivePath build/whisperer.xcarchive ARCHS=arm64 CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements ENABLE_APP_SANDBOX=YES
```

CRITICAL overrides: `ARCHS=arm64` (FluidAudio fails on x86_64), `CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements` (sandbox entitlements), `ENABLE_APP_SANDBOX=YES`.

### Step 11: Verify Binary

After archive, scan the binary for banned strings:
```bash
/usr/bin/strings build/whisperer.xcarchive/Products/Applications/whisperer.app/Contents/MacOS/whisperer | grep -iE "AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive"
```
Must return empty. If ANY match found, stop and fix.

### Step 12: Export and Upload to App Store Connect

```bash
xcodebuild -exportArchive -archivePath build/whisperer.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
```

ExportOptions.plist is at `build/ExportOptions.plist` (method=app-store-connect, destination=upload, teamID=8NM6EHZB4G, signingStyle=automatic).

Verify output contains "EXPORT SUCCEEDED" and "Upload succeeded".

### Step 13: Generate Submission Summary

Output a summary with build status, compliance status, version info, and upload status. Then generate reviewer notes using `references/reviewer-notes-template.md`.

## Troubleshooting

### Build Fails
- Check Xcode command line tools: `xcode-select -p`
- Project uses automatic signing — do not pass `CODE_SIGN_IDENTITY`

### Archive Fails
- Ensure `ARCHS=arm64` is set (FluidAudio x86_64 Float16 issue)
- Ensure sandbox entitlements override is present

### Upload Fails
- Verify `teamID` in ExportOptions.plist
- Check App Store Connect for processing status
- If build number already exists, bump CFBundleVersion

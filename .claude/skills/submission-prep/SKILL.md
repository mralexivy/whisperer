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
  version: 1.0.0
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

### Step 4: Verify Entitlements

Read `Whisperer/whisperer.entitlements` and verify:
- [ ] `com.apple.security.app-sandbox` is `true`
- [ ] `com.apple.security.network.client` is `true`
- [ ] `com.apple.security.device.audio-input` is `true`
- [ ] `com.apple.security.files.user-selected.read-write` is `true`
- [ ] No unexpected entitlements present (especially `network.server`)

### Step 5: Verify Permissions Configuration

Read `Whisperer/Permissions/PermissionManager.swift` and verify:
- [ ] `PermissionType` enum has exactly two cases: `microphone` and `accessibility`
- [ ] No references to `inputMonitoring` or Input Monitoring
- [ ] `requiredPermissionsGranted` only requires Accessibility when `systemWideDictationEnabled` is true
- [ ] Accessibility is optional — app works without it

### Step 6: Verify TextInjector (Clipboard-Only Architecture)

Read `Whisperer/TextInjection/TextInjector.swift` and verify:
- [ ] No `AXUIElementCopyAttributeValue` calls (MUST be removed)
- [ ] No `AXUIElementSetAttributeValue` calls (MUST be removed)
- [ ] No `getFocusedElement` or `insertIntoElement` methods
- [ ] Text entry uses clipboard + paste only: `NSPasteboard` -> `CGEvent.post` (Cmd+V)
- [ ] `AXIsProcessTrusted` used only to check permission, not to manipulate elements
- [ ] Language uses "enter/entry" not "inject/insert" in user-facing strings

### Step 7: Verify System-Wide Dictation is Opt-In

Read `Whisperer/AppState.swift` and verify:
- [ ] `systemWideDictationEnabled` defaults to `false`
- [ ] Key listener is only created when `systemWideDictationEnabled` is `true`
- [ ] `startGlobalDictation()` / `stopGlobalDictation()` lifecycle is correct

### Step 8: Verify Onboarding Flow

Read `Whisperer/UI/OnboardingView.swift` and `Whisperer/UI/OnboardingWindow.swift`:
- [ ] Onboarding shows on first launch when `hasCompletedOnboarding` is false
- [ ] Onboarding requests Microphone permission (required)
- [ ] System-wide dictation page is labeled "Optional"
- [ ] "Enable System-Wide Dictation" and "Set Up Later" buttons both present
- [ ] Accessibility permission text says "detect shortcut key and paste transcribed text"
- [ ] Onboarding sets `hasCompletedOnboarding = true` on completion
- [ ] No banned APIs used in onboarding

### Step 9: Verify App Icon

Check `Whisperer/Assets.xcassets/AppIcon.appiconset/`:
- [ ] All 10 macOS icon sizes present (16, 16@2x, 32, 32@2x, 128, 128@2x, 256, 256@2x, 512, 512@2x)
- [ ] Icons use dark navy background with blue-purple gradient waveform
- [ ] `Contents.json` references all filenames correctly

### Step 10: Bump Version

Ask the user whether to bump minor version (e.g., 1.1 -> 1.2) or just build number.
Update in BOTH places:
- `Whisperer/Info.plist`: `CFBundleShortVersionString` and `CFBundleVersion`
- `Whisperer.xcodeproj/project.pbxproj`: `MARKETING_VERSION` (both Debug and Release) and `CURRENT_PROJECT_VERSION` (both Debug and Release)

### Step 11: Build Release

```bash
xcodebuild clean build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS" 2>&1
```

Report build result (success/failure) and warning count. If build fails, stop and report errors.

### Step 12: Archive

```bash
xcodebuild archive -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "generic/platform=macOS" -archivePath build/Whisperer.xcarchive 2>&1
```

Do NOT pass `CODE_SIGN_IDENTITY` — the project uses automatic signing. If archive fails, report errors.

### Step 13: Export and Upload to App Store Connect

Create `build/ExportOptions.plist` if it doesn't exist (see `references/export-options.plist` for template), then export and upload:

```bash
xcodebuild -exportArchive -archivePath build/Whisperer.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates 2>&1
```

Verify output contains "EXPORT SUCCEEDED" and "Upload succeeded".

### Step 14: Generate Submission Summary

Output a summary with build status, compliance status, version info, and upload status. Then generate reviewer notes and App Store metadata using the templates in `references/`.

Consult these reference files for templates:
- `references/reviewer-notes-template.md` — Reviewer notes (must be under 4000 characters)
- `references/app-store-metadata.md` — App Store description, promotional text, keywords
- `references/export-options.plist` — ExportOptions.plist template

## Troubleshooting

### Build Fails
- Check Xcode command line tools are selected: `xcode-select -p`
- Verify signing: project uses automatic signing, do not pass `CODE_SIGN_IDENTITY`

### Archive Fails
- Ensure Release build succeeded first
- Check disk space for archive (~500MB)

### Upload Fails
- Verify `teamID` in ExportOptions.plist matches your Apple Developer team
- Check App Store Connect for processing status

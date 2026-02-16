# Submission Prep — Pre-App Store Submission Checklist

Run through all automated checks before uploading a build to App Store Connect.

## Step 1: Run App Store Compliance Check

Scan the entire `Whisperer/` directory for Guideline 2.4.5 violations (banned APIs, framing issues, permission red flags). Follow the same checks as `/app-store-check`. If ANY violations found, stop and report — do not proceed to build.

## Step 2: Run Conventions Check

Scan recently changed Swift files for coding convention violations (print statements, memory safety, threading). Follow the same checks as `/conventions-check`.

## Step 3: Build Release Configuration

```bash
xcodebuild clean build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS" 2>&1
```

Report build result (success/failure) and warning count. If build fails, stop and report errors.

## Step 4: Verify Info.plist Configuration

Read `Whisperer/Info.plist` and verify:
- [ ] `NSMicrophoneUsageDescription` is present and says "transcribe your voice"
- [ ] `ITSAppUsesNonExemptEncryption` is `false`
- [ ] `LSUIElement` is `true` (menu bar app)
- [ ] `CFBundleShortVersionString` and `CFBundleVersion` are set

## Step 5: Verify Entitlements

Read the `.entitlements` file and verify:
- [ ] `com.apple.security.app-sandbox` is `true`
- [ ] `com.apple.security.network.client` is `true`
- [ ] `com.apple.security.device.audio-input` is `true`
- [ ] No unexpected entitlements present (especially `network.server`)

## Step 6: Verify Permissions Configuration

Read `Whisperer/Permissions/PermissionManager.swift` and verify:
- [ ] `PermissionType` enum has exactly two cases: `microphone` and `accessibility`
- [ ] No references to `inputMonitoring` or Input Monitoring
- [ ] `allPermissionsGranted` checks only microphone + accessibility

## Step 7: Generate Submission Summary

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

### Version Info
- Version: (from Info.plist)
- Build: (from Info.plist)

### Reviewer Notes
Generate reviewer notes using this template — fill in the current version:

```
Whisperer is an assistive dictation and voice-to-text tool that enables hands-free text input.

ACCESSIBILITY USAGE:
We use Accessibility API (AXUIElement) solely for its intended assistive purpose — inserting user-dictated text into the focused text field. Users who cannot grant Accessibility can still use the app via clipboard fallback.

PERMISSIONS REQUIRED:
- Microphone: Voice recording for transcription
- Accessibility: Assistive text insertion into focused fields (optional)

NO INPUT MONITORING:
We do NOT monitor keystrokes. We do NOT use CGEventTap, IOKit HID, or global key event monitoring. Shortcut detection uses only NSEvent flagsChanged (modifier state) and Carbon RegisterEventHotKey.

TESTING:
1. Grant Microphone permission when prompted
2. Grant Accessibility permission for text injection (optional)
3. Wait for model download (~500MB, one-time)
4. Open TextEdit, hold Fn key, speak, release
5. App works 100% offline after model download

EXPORT COMPLIANCE: Uses HTTPS only (exempt). No proprietary encryption.
Pro Pack IAP: com.ivy.whisperer.propack
```

### Ready to Submit?
- If all checks pass: "Ready for submission. Copy reviewer notes above into App Store Connect."
- If any checks fail: "NOT ready — fix the issues above before submitting."

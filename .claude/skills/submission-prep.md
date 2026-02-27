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

## Step 7: Verify Onboarding Flow

Read `Whisperer/UI/OnboardingView.swift` and `Whisperer/UI/OnboardingWindow.swift`:
- [ ] Onboarding shows on first launch when `hasCompletedOnboarding` is false
- [ ] Onboarding requests Microphone and Accessibility permissions
- [ ] Onboarding triggers model download
- [ ] Onboarding sets `hasCompletedOnboarding = true` on completion
- [ ] No banned APIs used in onboarding permission requests

## Step 8: Verify App Icon

Check `Whisperer/Assets.xcassets/AppIcon.appiconset/`:
- [ ] All 10 macOS icon sizes present (16, 16@2x, 32, 32@2x, 128, 128@2x, 256, 256@2x, 512, 512@2x)
- [ ] Icons use dark navy background with blue-purple gradient waveform (matching app theme)
- [ ] `Contents.json` references all filenames correctly

## Step 9: Generate Submission Summary

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

FIRST LAUNCH EXPERIENCE:
On first launch, a guided onboarding flow walks users through permissions setup, model download, and shortcut configuration. The app is ready to use immediately after onboarding completes.

ACCESSIBILITY USAGE:
We use Accessibility API (AXUIElement) solely for its intended assistive purpose — inserting user-dictated text into the focused text field. Users who cannot grant Accessibility can still use the app via clipboard fallback.

PERMISSIONS REQUIRED:
- Microphone: Voice recording for transcription
- Accessibility: Assistive text insertion into focused fields (optional)

NO INPUT MONITORING:
We do NOT monitor keystrokes. We do NOT use CGEventTap, IOKit HID, or global key event monitoring. Shortcut detection uses only NSEvent flagsChanged (modifier state) and Carbon RegisterEventHotKey.

TESTING:
1. Launch the app — onboarding window appears on first run
2. Follow onboarding: grant Microphone permission, download a model, configure shortcut
3. Open TextEdit, hold Fn key (or configured shortcut), speak, release
4. Transcribed text appears in the focused field
5. Open Workspace from menu bar to see transcription history
6. App works 100% offline after model download

EXPORT COMPLIANCE: Uses HTTPS only (exempt). No proprietary encryption.
Pro Pack IAP: com.ivy.whisperer.propack
```

### Ready to Submit?
- If all checks pass: "Ready for submission. Copy reviewer notes above into App Store Connect."
- If any checks fail: "NOT ready — fix the issues above before submitting."

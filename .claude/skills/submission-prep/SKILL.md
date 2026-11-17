---
name: submission-prep
description: >
  Complete pre-App Store submission workflow: compliance scan, conventions
  check, Info.plist verification, entitlements validation, version bump,
  release build, archive of both the regular and the China edition, upload to App Store Connect, and reviewer notes
  generation. Use when preparing a build for App Store submission. Use when
  user says "submit to App Store", "prepare submission", "build for release",
  "generate reviewer notes", "upload to App Store Connect", or "prep for
  review".
metadata:
  version: 3.0.0
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

### Step 10: Archive — two builds, always both

Every submission produces **two** archives from the same commit and the same version/build number:

| | Regular edition | China edition |
|---|---|---|
| Configuration | `AppStore` | `AppStoreChina` |
| Compile flags | `APP_STORE` | `APP_STORE CHINA_EDITION` |
| Bundle ID | `com.ivy.whisperer` | `com.ivy.whisperer.cn` |
| App Store Connect record | the existing app (`6758626671`) | a **separate** app record |
| Territories | everything **except** China mainland | **China mainland only** |
| Regulated features | closed at runtime when the storefront is `CHN` (`MarketPolicy`) | compiled to the closed state, whatever the storefront says |
| Models downloaded from | Hugging Face (ModelScope when the storefront is `CHN`) | ModelScope |

Why two records: App Store Connect cannot ship a different binary to one territory within one record, and the China forms ask about "the app". The China record answers them **No / No** because the features are off, and the regular record is simply not sold in China mainland.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Regular edition
xcodebuild clean archive -project Whisperer.xcodeproj -scheme whisperer -configuration AppStore -destination "platform=macOS" -archivePath build/whisperer.xcarchive ARCHS=arm64
# China edition
xcodebuild clean archive -project Whisperer.xcodeproj -scheme whisperer -configuration AppStoreChina -destination "platform=macOS" -archivePath build/whisperer-china.xcarchive ARCHS=arm64
```

Both configurations already select `Whisperer/whisperer.entitlements` and `ENABLE_APP_SANDBOX=YES`. `ARCHS=arm64` is still required (FluidAudio fails on x86_64). Do not run `xcodebuild` from a Command Line Tools shell: set `DEVELOPER_DIR` as above.

### Step 11: Verify Binaries

Regular edition — banned strings, must return empty:
```bash
/usr/bin/strings build/whisperer.xcarchive/Products/Applications/whisperer.app/Contents/MacOS/whisperer | grep -iE "AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive"
```
Run the same scan on the China archive (`build/whisperer-china.xcarchive`). Then the China-only checks:

```bash
CN=build/whisperer-china.xcarchive/Products/Applications/whisperer.app
REG=build/whisperer.xcarchive/Products/Applications/whisperer.app
/usr/bin/defaults read "$CN/Contents/Info.plist" CFBundleIdentifier                 # com.ivy.whisperer.cn
/usr/bin/defaults read "$REG/Contents/Info.plist" CFBundleIdentifier                # com.ivy.whisperer
/usr/bin/strings "$CN/Contents/MacOS/whisperer"  | grep -c "whisperer-edition=china-mainland"   # 1
/usr/bin/strings "$REG/Contents/MacOS/whisperer" | grep -c "whisperer-edition=china-mainland"   # 0
```
Any other result: stop. The marker string exists only when `CHINA_EDITION` is compiled in, so it proves which edition a binary is. Both archives must carry the same `CFBundleShortVersionString` / `CFBundleVersion`.

Model sources for the China edition (needs network access to modelscope.cn):
```bash
scripts/verify-china-models.sh      # must end with "China model sources: all good"
```
It checks every ModelScope file the China edition downloads (existence, and SHA-256 equal to the pins in `ModelChecksums.swift`). Fix `ModelSources.swift` or the script when a file moved. If a model is missing it fails — do not submit.

Optional runtime check of the regular edition's geoblock: run a Debug build with `WHISPERER_FORCE_MARKET=china` and confirm that Ask AI, cloud/CLI providers, Command Mode, Cloud and Google sign-in are gone, and that MCP, dictation, meetings and local summaries still work.

### Step 12: Export and Upload to App Store Connect

```bash
xcodebuild -exportArchive -archivePath build/whisperer.xcarchive       -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
xcodebuild -exportArchive -archivePath build/whisperer-china.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export-china
```

ExportOptions.plist is at `build/ExportOptions.plist` (copy from `references/export-options.plist` if missing: method=app-store-connect, destination=upload, teamID=8NM6EHZB4G, signingStyle=automatic). The same file serves both editions; Xcode picks the provisioning by bundle id.

Verify each output contains "EXPORT SUCCEEDED" and "Upload succeeded". The China upload goes to the `com.ivy.whisperer.cn` record, so the record must exist first (see Step 14).

### Step 13: Generate Submission Summary

Output a summary with build status, compliance status, version info and upload status **for both editions**. Then generate reviewer notes using `references/reviewer-notes-template.md` (regular) and `references/china-edition.md` (China record).

### Step 14: App Store Connect — China edition (manual; Account Holder or Admin)

Do once when the China record does not exist, and re-check every release. Only the Account Holder / Admin can complete the China forms. Deadline for existing apps: **2027-01-31**, before the next version ships to China.

1. **App ID and record.** Certificates, Identifiers & Profiles → register App ID `com.ivy.whisperer.cn` with the same capabilities as the regular one (App Sandbox, network client, audio input, user-selected files, camera). App Store Connect → new macOS app, bundle `com.ivy.whisperer.cn`, name e.g. "Whisperer - Voice to Text" (add a suffix if the name is taken), SKU `whisperer-macos-cn-1`, primary language Chinese (Simplified).
2. **Availability.** China record → Pricing and Availability → **only China mainland**. Regular record → remove **China mainland** from availability.
3. **Compliance forms (China record).** *AI-Generated or Synthetic Content*: **No**. *Security Assessment*: **No**. Apple allows "No" when the features are "disabled or geoblocked in China mainland": in this edition they are compiled out of reach, not merely hidden. In the regular record do not answer for China (it is not sold there).
4. **In-App Purchase.** Done 2026-11-17: the China record sells `com.ivy.whisperer.propack` ($14.99, app $4.99); the regular app sells `com.ivy.whisperer.pro` (a product id cannot be reused in a record where it once existed). `StoreManager` picks the id by edition and honours either. Purchases do not carry over between the two apps. Tell users who bought in the regular app that a China purchase needs restoring in the China app (a note in the China description).
5. **Metadata.** zh-Hans description, keywords, screenshots (take them from the China build: no Ask AI tab, no cloud AI providers). Privacy policy URL and App Privacy answers are the same ("data not collected", transcription on-device).
6. **Review notes** (China record): paste `references/china-edition.md`. State that on-device transcription and local summaries are the only AI, that cloud AI, chat, voice alteration and sync are not present in this edition, and that models download from ModelScope (modelscope.cn).
7. **Encryption** answers match the regular record (HTTPS only, exempt).

### Step 15: Order and checks before pressing "Submit for Review"

- [ ] Same version and build in both records; both builds processed.
- [ ] `scripts/verify-china-models.sh` passed on the day of submission.
- [ ] Regular record: China mainland removed from availability.
- [ ] China record: forms answered No/No, availability China mainland only, review notes pasted.
- [ ] Neither record mentions features the other lacks in screenshots.

## Troubleshooting

### Build Fails
- Check Xcode command line tools: `xcode-select -p`; use `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- Project uses automatic signing — do not pass `CODE_SIGN_IDENTITY`

### Archive Fails
- Ensure `ARCHS=arm64` is set (FluidAudio x86_64 Float16 issue)
- China archive: the `AppStoreChina` configuration must exist in all four configuration lists (project, `whisperer` target, `WhispererTests`, "Privacy driver build"); a missing one shows as "configuration not found"

### Upload Fails
- Verify `teamID` in ExportOptions.plist
- Check App Store Connect for processing status
- If build number already exists, bump CFBundleVersion
- China upload "no matching app record": create the `com.ivy.whisperer.cn` record first (Step 14)

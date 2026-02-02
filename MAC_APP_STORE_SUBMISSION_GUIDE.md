# Complete Mac App Store Submission Guide for Whisperer

This guide walks you through every step of submitting your Whisperer app to the Mac App Store, from Xcode configuration to final submission.

---

## Phase 1: Pre-Submission Checklist

### ✅ Step 1.1: Host Your Privacy Policy (REQUIRED)

Apple requires a publicly accessible privacy policy URL. Choose one option:

**Option A: GitHub Pages (Recommended - Free)**
```bash
# 1. Create docs folder
mkdir -p docs
cp Whisperer/whisperer/whisperer/Resources/PrivacyPolicy.md docs/privacy.md

# 2. Commit and push
git add docs/privacy.md
git commit -m "Add privacy policy for App Store"
git push

# 3. Enable GitHub Pages:
# - Go to your repo on github.com
# - Settings → Pages
# - Source: Deploy from "docs" folder
# - Your URL will be: https://YOUR_USERNAME.github.io/REPO_NAME/privacy
```

**Option B: Notion (Easy)**
1. Create a new Notion page
2. Paste the privacy policy content
3. Click "Share" → "Share to web"
4. Copy the public URL

**Option C: GitHub Gist**
1. Go to gist.github.com
2. Create new gist with PrivacyPolicy.md
3. Make it public
4. Use the gist URL

### ✅ Step 1.2: Update Privacy Policy URL in Code

Once you have your URL, update WhispererApp.swift:

```swift
// Find this function around line 1582
private func openPrivacyPolicy() {
    // Replace with your actual URL
    if let url = URL(string: "https://YOUR_ACTUAL_URL_HERE") {
        NSWorkspace.shared.open(url)
    }
}
```

### ✅ Step 1.3: Add Acknowledgments.txt to Xcode

The file exists but needs to be added to your Xcode project:

1. Open `whisperer.xcodeproj` in Xcode
2. Right-click on `whisperer` group in Project Navigator
3. Select "Add Files to whisperer..."
4. Navigate to `Whisperer/whisperer/whisperer/Resources/Acknowledgments.txt`
5. ✅ Check "Copy items if needed"
6. ✅ Check "whisperer" under "Add to targets"
7. Click "Add"

### ✅ Step 1.4: Remove Info.plist from Copy Bundle Resources

Fix the Xcode warning:

1. Select "whisperer" target in Xcode
2. Click "Build Phases" tab
3. Expand "Copy Bundle Resources"
4. Find and remove "Info.plist" (if present)
5. Click the "-" button to remove it

### ✅ Step 1.5: Take Screenshots

You need Mac screenshots for App Store listing:

**Required sizes**: 1280x800 or 1440x900

**What to capture**:
1. Menu bar with recording in progress
2. Settings panel showing features
3. Transcription overlay with text
4. (Optional) Pro Pack purchase screen

**How to take screenshots**:
```bash
# Use macOS screenshot tool
Cmd + Shift + 5

# Or use specific size in Terminal
screencapture -x -R0,0,1280,800 screenshot1.png
```

---

## Phase 2: Xcode Project Configuration

### ✅ Step 2.1: Verify Bundle Identifier

1. Open Xcode project
2. Select "whisperer" target
3. Go to "Signing & Capabilities" tab
4. Verify Bundle Identifier: **`com.ivy.whisperer`**
   - ⚠️ This MUST match exactly what you'll use in App Store Connect

### ✅ Step 2.2: Set Version and Build Number

1. In Xcode, select "whisperer" target
2. Go to "General" tab
3. Under "Identity":
   - **Version**: 1.0
   - **Build**: 1

> **Note**: Increment Build number for each upload, even if Version stays the same

### ✅ Step 2.3: Configure Signing for Distribution

1. Go to "Signing & Capabilities" tab
2. **For Debug**:
   - ✅ Automatically manage signing
   - Team: Select your Apple Developer Team
   - Signing Certificate: "Apple Development"

3. **For Release** (create new configuration if needed):
   - ✅ Automatically manage signing
   - Team: Select your Apple Developer Team
   - Signing Certificate: "Apple Distribution"
   - Provisioning Profile: "Mac App Store"

### ✅ Step 2.4: Verify Entitlements

Check that `whisperer.entitlements` contains:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

⚠️ Make sure `com.apple.security.network.server` is NOT present (we removed it).

### ✅ Step 2.5: Verify Info.plist Settings

Check these keys are present:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>

<key>NSMicrophoneUsageDescription</key>
<string>Whisperer needs microphone access to transcribe your voice to text.</string>

<key>NSAppleEventsUsageDescription</key>
<string>Whisperer needs automation access to insert transcribed text into applications.</string>
```

---

## Phase 3: App Store Connect Setup

### ✅ Step 3.1: Access App Store Connect

1. Go to https://appstoreconnect.apple.com
2. Sign in with your Apple Developer account
3. Wait for account approval if pending (can take 24-48 hours)

### ✅ Step 3.2: Create App Record

1. Click "My Apps"
2. Click the "+" button
3. Select "New App"
4. Fill in:
   - **Platform**: macOS
   - **Name**: Whisperer
   - **Primary Language**: English (U.S.)
   - **Bundle ID**: Select `com.ivy.whisperer`
     - ⚠️ If not in list, you need to register it first:
       - Go to https://developer.apple.com/account
       - Certificates, IDs & Profiles → Identifiers
       - Click "+" → App IDs → Continue
       - Select "App" → Continue
       - Description: "Whisperer Voice to Text"
       - Bundle ID: Explicit - `com.ivy.whisperer`
       - Capabilities: Check "App Sandbox"
       - Register
   - **SKU**: whisperer-macos-1 (any unique identifier)
   - **User Access**: Full Access
5. Click "Create"

### ✅ Step 3.3: Set App Information

In your new app, go to "App Information":

1. **Category**:
   - Primary: Utilities
   - Secondary: Productivity

2. **License Agreement**: Standard Apple EULA (or upload custom)

3. **Privacy Policy URL**: Enter your hosted URL from Step 1.1

### ✅ Step 3.4: Set Pricing

1. Go to "Pricing and Availability"
2. Click "Add Pricing"
3. Select your base price:
   - **Recommended**: USD $0.99 (Tier 1) or $1.99 (Tier 2)
4. Select countries/regions (or select "All Countries")
5. Save

### ✅ Step 3.5: Create In-App Purchase (Pro Pack)

1. Go to "Features" → "In-App Purchases"
2. Click the "+" button
3. Select "Non-Consumable"
4. Fill in:
   - **Reference Name**: Pro Pack
   - **Product ID**: `com.ivy.whisperer.propack`
     - ⚠️ Must match exactly what's in StoreManager.swift
   - **Cleared for Sale**: Yes

5. Add Pricing:
   - **Price**: USD $4.99 (Tier 5) to $9.99 (Tier 10)
   - Recommended: $4.99 or $6.99

6. Add Localization (English):
   - **Display Name**: Pro Pack
   - **Description**:
     ```
     Unlock Pro Pack to access:
     • Code Mode - Dictate code with spoken symbols and casing
     • Per-App Profiles - Auto-switch settings by application
     • Personal Dictionary - Add custom words for better accuracy
     • Pro Insertion Engine - Advanced text insertion with fallbacks
     ```
   - **Review Screenshot**: Optional but recommended (screenshot of Pro Pack features)

7. Click "Save"
8. Click "Submit for Review" (IAPs get reviewed with your app)

---

## Phase 4: Prepare App Metadata

### ✅ Step 4.1: Write App Description

Go to "App Store" tab → "App Information":

**Name**: Whisperer

**Subtitle** (Optional, 30 chars):
```
Voice to Text for Mac
```

**Description** (4000 chars max):
```
Instantly transcribe your voice to text in any macOS app. Hold a key, speak, and watch your words appear—100% offline and private.

FEATURES
• 100% offline transcription - Your voice never leaves your Mac
• Works everywhere - Safari, VS Code, Slack, Terminal, TextEdit, and more
• Real-time preview - See your words as you speak
• Multiple AI models - Choose speed vs accuracy
• 90+ languages supported
• Privacy-first - No cloud, no analytics, no data collection

Powered by OpenAI's Whisper AI, running entirely on your device. Perfect for developers, writers, and anyone who wants fast, accurate voice-to-text without compromising privacy.

UPGRADE TO PRO PACK
• Code Mode - Dictate code with spoken symbols ("open paren", "arrow", "camel case")
• Per-App Profiles - Auto-switch settings for Slack, VS Code, Terminal, and other apps
• Personal Dictionary - Add custom words, names, and technical terms
• Pro Insertion Engine - Advanced paste with clipboard safety and fallbacks

PRIVACY FOCUSED
All transcription happens on your Mac. No internet required after initial model download. No data collection, no tracking, no cloud uploads.

EASY TO USE
1. Grant microphone and accessibility permissions
2. Download the AI model (one-time, ~500MB)
3. Hold Fn key, speak, release
4. Your text appears instantly

Perfect for:
• Developers who need to dictate code
• Writers working on drafts
• Anyone tired of typing
• Users who value privacy
• Multilingual users (supports 90+ languages)
```

**Keywords** (100 chars max, comma-separated):
```
voice to text,speech to text,dictation,transcription,whisper,voice typing,accessibility,developer
```

**Support URL**: Your website or GitHub repo
```
https://github.com/YOUR_USERNAME/whisperer
```

**Marketing URL** (Optional): Same as above

### ✅ Step 4.2: Upload Screenshots

1. Go to "macOS" → "Screenshots and Preview"
2. Required sizes: 1280x800 or 1440x900
3. Upload at least 3 screenshots (max 10)
4. Drag to reorder (first screenshot shows in search results)

**Recommended screenshots**:
1. App in action with transcription overlay
2. Settings panel showing features
3. Multiple apps showing it works everywhere
4. (Optional) Pro Pack feature comparison

### ✅ Step 4.3: Set App Privacy

1. Go to "App Privacy"
2. Click "Edit"
3. **Data Collection**: Select "No, we do not collect data from this app"
4. Save

### ✅ Step 4.4: Export Compliance

1. Go to "App Information" → "Export Compliance"
2. **Does your app use encryption?**: Yes
3. **Does your app qualify for exemption?**: Yes
4. **Why does your app qualify?**: Uses standard encryption for HTTPS only
5. Save

(This matches the `ITSAppUsesNonExemptEncryption = NO` in Info.plist)

---

## Phase 5: Build and Archive for Distribution

### ✅ Step 5.1: Clean Build Folder

In Xcode:
```
Product → Clean Build Folder (Cmd + Shift + K)
```

### ✅ Step 5.2: Select Archive Scheme

1. In Xcode toolbar, click the scheme dropdown (next to play/stop buttons)
2. Select "Any Mac" as destination (NOT "My Mac")
3. Verify scheme is set to "whisperer"

### ✅ Step 5.3: Create Archive

1. In Xcode menu: `Product → Archive`
2. Wait for build to complete (2-5 minutes)
3. The Organizer window will open automatically

**If build fails**:
- Check error messages in Issue Navigator (⌘ + 5)
- Common issues:
  - Signing issues: Go to Signing & Capabilities, reselect team
  - Missing dependencies: Ensure whisper.cpp is built
  - Code errors: Fix any compilation errors

### ✅ Step 5.4: Validate Archive (Optional but Recommended)

In Organizer window:

1. Select your archive
2. Click "Validate App"
3. Select your team
4. Click "Validate"
5. Wait for validation (checks for common issues)
6. If validation passes, proceed to distribution

### ✅ Step 5.5: Distribute to App Store

In Organizer window:

1. Select your archive
2. Click "Distribute App"
3. Select **"App Store Connect"**
4. Click "Next"
5. Select **"Upload"**
6. Click "Next"
7. Distribution options:
   - ✅ Upload your app's symbols
   - ✅ Manage Version and Build Number (Xcode will auto-increment)
8. Click "Next"
9. Select signing:
   - ✅ Automatically manage signing
10. Click "Next"
11. Review summary
12. Click "Upload"
13. Wait for upload to complete (5-15 minutes depending on internet speed)

---

## Phase 6: TestFlight for Mac (Yes, it exists!)

### ✅ Step 6.1: Enable TestFlight

After upload completes:

1. Go to App Store Connect
2. Go to "TestFlight" tab
3. Your build will appear under "macOS" after processing (~30-60 min)
4. Status will show "Processing" → "Ready to Submit" → "Ready to Test"

### ✅ Step 6.2: Add Internal Testers

1. Under "Internal Testing", click "+" to add testers
2. Add up to 100 testers (must have App Store Connect accounts)
3. Enter emails of your team members
4. They'll receive an invitation email

### ✅ Step 6.3: Add External Testers (Optional)

1. Create a test group under "External Testing"
2. Add testers (they don't need developer accounts)
3. Add build to test group
4. Submit for Beta Review (faster than full review, ~24 hours)
5. Once approved, testers can install via TestFlight

### ✅ Step 6.4: Testers Install TestFlight App

Testers need to:

1. Download TestFlight for Mac from Mac App Store
2. Open TestFlight app
3. Sign in with their Apple ID
4. Accept invitation
5. Click "Install" next to Whisperer
6. Test and provide feedback

**TestFlight Features**:
- Automatic crash reporting
- Tester feedback collection
- Up to 90 days per build
- Test updates before production release

---

## Phase 7: Submit for App Review

### ✅ Step 7.1: Wait for Build Processing

After upload, your build will:

1. Appear in App Store Connect → "TestFlight" tab
2. Show "Processing" status (~30-60 minutes)
3. Change to "Ready to Submit"

You'll get an email when processing completes.

### ✅ Step 7.2: Add Build to Version

1. Go to "App Store" tab
2. Click on your version (e.g., "1.0 - Prepare for Submission")
3. Under "Build", click "Select a build"
4. Choose your uploaded build
5. Click "Done"

### ✅ Step 7.3: Complete Version Information

Fill in all required fields:

**What's New in This Version**:
```
Initial release of Whisperer - Private Voice to Text for Mac

Features:
• 100% offline voice transcription
• Works in any macOS app
• Real-time preview while speaking
• Multiple AI models (Small, Medium, Large)
• 90+ languages supported
• Pro Pack available: Code Mode, Per-App Profiles, Personal Dictionary
```

**Promotional Text** (Optional):
```
Private, offline voice-to-text for Mac. Hold Fn key, speak, and watch your words appear in any app.
```

**Description**: (Use description from Step 4.1)

**Keywords**: (Use keywords from Step 4.1)

**Screenshots**: (Upload from Step 4.2)

### ✅ Step 7.4: Add Review Notes

Scroll to "App Review Information":

**Notes**:
```
Testing Instructions:

1. The app requires these permissions on first launch:
   - Microphone (for voice input)
   - Accessibility (to insert text into other apps)
   - Input Monitoring (to detect Fn key)

2. First launch will download an AI model (~500MB) - this is one-time

3. To test transcription:
   - Open TextEdit or any text field
   - Hold the Fn key
   - Speak clearly: "Hello, this is a test"
   - Release Fn key
   - Text should appear in TextEdit

4. The Pro Pack in-app purchase is configured for:
   - Product ID: com.ivy.whisperer.propack
   - Price: [YOUR_PRICE]
   - Features: Code Mode, Per-App Profiles, Personal Dictionary, Pro Insertion

5. The app works 100% offline after model download

Contact: [YOUR_EMAIL]
```

**Sign-In Required**: No

**Demo Account**: Not applicable

**Contact Information**:
- First Name: [Your name]
- Last Name: [Your last name]
- Phone: [Your phone]
- Email: [Your email]

### ✅ Step 7.5: Review Content Rights

1. Check "Yes" for advertising identifier (if applicable, probably "No" for your app)
2. **Does this app use the Advertising Identifier?**: No

### ✅ Step 7.6: Submit for Review

1. Click "Save" at top right
2. Review all information one more time
3. Click "Submit for Review" button
4. Confirm submission

---

## Phase 8: Review Process

### What Happens Now?

1. **In Review** - Your app enters the review queue
   - Typical wait: 1-3 days (can be faster or slower)
   - You'll get email updates on status changes

2. **Possible Outcomes**:

   **✅ Approved**:
   - App moves to "Pending Developer Release"
   - You can release immediately or schedule release date
   - Click "Release This Version" to publish

   **⚠️ Metadata Rejected**:
   - Screenshots, description, or keywords need changes
   - Fix in App Store Connect and resubmit
   - No new build needed

   **❌ Binary Rejected**:
   - App has issues that need fixing
   - Read rejection message carefully
   - Fix issues in Xcode
   - Create new build and resubmit

3. **Common Rejection Reasons**:
   - Permissions not explained properly → Add clear usage descriptions
   - App crashes on review → Test thoroughly, use TestFlight first
   - Missing functionality → Ensure all advertised features work
   - Privacy policy issues → Verify URL works and policy is accurate
   - In-app purchase issues → Test IAP in sandbox environment

---

## Phase 9: Post-Approval

### ✅ After Approval

1. **Release Your App**:
   - Click "Release This Version" in App Store Connect
   - App appears on Mac App Store within 24 hours

2. **Monitor**:
   - Check Analytics in App Store Connect
   - Monitor crash reports
   - Respond to user reviews

3. **Updates**:
   - For updates, increment version/build numbers
   - Create new archive
   - Submit update through same process

---

## Troubleshooting Common Issues

### Issue: "No accounts with App Store Connect access"

**Solution**:
1. Your developer account isn't approved yet
2. Go to developer.apple.com/account
3. Complete enrollment ($99/year fee)
4. Wait for approval email (24-48 hours)

### Issue: Bundle ID not available

**Solution**:
1. Someone else registered that Bundle ID
2. Change to something unique: `com.yourname.whisperer`
3. Update everywhere: Xcode project, StoreManager.swift, App Store Connect

### Issue: "Signing for whisperer requires a development team"

**Solution**:
1. In Xcode → Preferences → Accounts
2. Click "+" → Add Apple ID
3. Sign in with developer account
4. Select team in project settings

### Issue: Build fails with code signing error

**Solution**:
1. Clean Build Folder (Cmd + Shift + K)
2. Quit Xcode
3. Delete derived data: `~/Library/Developer/Xcode/DerivedData`
4. Reopen Xcode
5. Try archive again

### Issue: Upload fails with "Invalid Toolchain"

**Solution**:
1. Update Xcode to latest version
2. Download from Mac App Store or developer.apple.com
3. Try upload again

### Issue: TestFlight build processing forever

**Solution**:
1. Usually resolves in 1-2 hours
2. If stuck >4 hours, create new archive and upload
3. Check Apple Developer System Status: developer.apple.com/system-status

---

## Quick Reference Checklist

Copy this checklist and check off as you complete each step:

**Before You Start**:
- [ ] Developer account approved
- [ ] Privacy policy hosted online
- [ ] Privacy policy URL updated in code
- [ ] Acknowledgments.txt added to Xcode project
- [ ] Screenshots taken (1280x800 or 1440x900)

**Xcode Configuration**:
- [ ] Bundle ID set: `com.ivy.whisperer`
- [ ] Version set to 1.0, Build set to 1
- [ ] Signing team selected
- [ ] Entitlements verified
- [ ] Info.plist verified

**App Store Connect**:
- [ ] App created with correct Bundle ID
- [ ] Base app pricing set
- [ ] Pro Pack IAP created: `com.ivy.whisperer.propack`
- [ ] App description written
- [ ] Keywords added
- [ ] Screenshots uploaded
- [ ] Privacy policy URL added
- [ ] Export compliance answered

**Build & Submit**:
- [ ] Clean build folder
- [ ] Create archive (Product → Archive)
- [ ] Validate app (optional but recommended)
- [ ] Upload to App Store Connect
- [ ] Wait for processing (30-60 min)
- [ ] Add build to version
- [ ] Fill review notes
- [ ] Submit for review

**Post-Submission**:
- [ ] (Optional) Test with TestFlight first
- [ ] Monitor review status
- [ ] Release when approved

---

## Helpful Resources

- **App Store Connect**: https://appstoreconnect.apple.com
- **Developer Account**: https://developer.apple.com/account
- **App Review Guidelines**: https://developer.apple.com/app-store/review/guidelines/
- **StoreKit Testing**: https://developer.apple.com/documentation/storekit/in-app_purchase/testing_in-app_purchases_with_sandbox
- **Mac App Store Submission**: https://developer.apple.com/help/app-store-connect/

---

## Support

If you encounter issues:

1. Check Apple Developer Forums: https://developer.apple.com/forums/
2. Check App Store Connect help: https://developer.apple.com/help/app-store-connect/
3. Contact Apple Developer Support (available with paid account)

---

**Good luck with your submission! 🚀**

Your app is well-prepared and ready for the Mac App Store.

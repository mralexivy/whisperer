# Final Pre-Submission Checklist

## ✅ Completed Items

Great progress! Here's what's already done:

- [x] **Track A Implementation** - All App Store foundation complete
  - [x] Receipt validation (ReceiptValidator.swift)
  - [x] StoreKit 2 integration (StoreManager.swift)
  - [x] Purchase UI (PurchaseView.swift)
  - [x] Privacy policy created
  - [x] License attribution (Acknowledgments.txt)
  - [x] Export compliance (Info.plist)
  - [x] Entitlements cleaned up

- [x] **Website & URLs**
  - [x] Landing page deployed at https://whispererapp.com
  - [x] Privacy policy live at https://whispererapp.com/privacy/
  - [x] Code updated with correct URLs
  - [x] Build compiles successfully

---

## 🔧 Remaining Steps Before Submission

### Step 1: Add Acknowledgments.txt to Xcode (2 minutes)

**Status**: ⏳ TO DO

The file exists but isn't included in your Xcode target yet.

**How to do it**:
1. Open `whisperer.xcodeproj` in Xcode (double-click it)
2. In left sidebar (Project Navigator), right-click on the "whisperer" folder
3. Select "Add Files to whisperer..."
4. Navigate to and select: `Whisperer/whisperer/whisperer/Resources/Acknowledgments.txt`
5. ✅ Check "Copy items if needed"
6. ✅ Check "whisperer" under "Add to targets"
7. Click "Add"

**How to verify it worked**:
- You should see Acknowledgments.txt in the Project Navigator
- It should have a checkbox icon (not grayed out) next to it

---

### Step 2: Take App Screenshots (15 minutes)

**Status**: ⏳ TO DO

You need 3-5 screenshots sized **1280x800** or **1440x900** for the Mac App Store.

**What to capture**:
1. **Main UI** - Menu bar with recording overlay visible
2. **Settings Panel** - Show the features and models
3. **In Action** - App working in different applications (TextEdit, VS Code, etc.)
4. **Pro Pack** - Purchase screen (optional but recommended)

**How to take screenshots**:

```bash
# Option 1: Use macOS screenshot tool
# Press Cmd + Shift + 5
# Select "Capture Selected Portion"
# Manually resize to 1280x800

# Option 2: Use Terminal for exact size
screencapture -x -R0,0,1280,800 ~/Desktop/whisperer-screenshot-1.png
screencapture -x -R0,0,1280,800 ~/Desktop/whisperer-screenshot-2.png
screencapture -x -R0,0,1280,800 ~/Desktop/whisperer-screenshot-3.png
```

**Tips**:
- Use a clean desktop background
- Show the app actively transcribing
- Make text readable
- Highlight unique features

**Save screenshots to**: A dedicated folder like `~/Desktop/Whisperer Screenshots/`

---

### Step 3: Wait for Developer Account Approval (24-48 hours)

**Status**: ⏳ WAITING (if not already approved)

**Check your status**:
1. Go to https://developer.apple.com/account
2. Sign in with your Apple ID
3. Look for "Account Holder" or "Admin" status

**If approved**:
- You'll see "Membership" section with "Active" status
- You can access App Store Connect
- Move to next step

**If pending**:
- Check your email for approval notification
- Usually takes 24-48 hours
- Make sure you've paid the $99/year fee

---

### Step 4: Create App in App Store Connect (15 minutes)

**Status**: ⏳ TO DO (after account approval)

**Instructions**:
1. Go to https://appstoreconnect.apple.com
2. Click "My Apps"
3. Click "+" button → "New App"
4. Fill in:
   - **Platform**: macOS
   - **Name**: Whisperer
   - **Primary Language**: English (U.S.)
   - **Bundle ID**: Create new → `com.ivy.whisperer`
     - If Bundle ID doesn't exist, register it first at developer.apple.com/account
   - **SKU**: `whisperer-macos-1` (can be anything unique)
   - **User Access**: Full Access
5. Click "Create"

---

### Step 5: Configure App Store Connect (30 minutes)

**Status**: ⏳ TO DO

After creating the app, configure these sections:

#### A. App Information
- **Category**:
  - Primary: Utilities
  - Secondary: Productivity
- **License Agreement**: Standard Apple EULA
- **Privacy Policy URL**: `https://whispererapp.com/privacy/`

#### B. Pricing
- **Base App Price**: $0.99 (Tier 1) or $1.99 (Tier 2)
  - Recommendation: Start with $0.99 for better conversion
- **Availability**: All countries

#### C. Create Pro Pack IAP
1. Go to "Features" → "In-App Purchases"
2. Click "+" → "Non-Consumable"
3. Fill in:
   - **Reference Name**: Pro Pack
   - **Product ID**: `com.ivy.whisperer.propack`
   - **Price**: $4.99 (Tier 5) or $6.99 (Tier 7)
     - Recommendation: $4.99 for better upgrade rate
4. Add Localization (English):
   - **Display Name**: Pro Pack
   - **Description**:
     ```
     Unlock Pro Pack to access:
     • Code Mode - Dictate code with spoken symbols and casing commands
     • Per-App Profiles - Auto-switch settings for different applications
     • Personal Dictionary - Add custom words for better accuracy
     • Pro Insertion Engine - Advanced text insertion with clipboard safety
     ```
5. Save and submit for review

#### D. App Privacy
- **Data Collection**: "No, we do not collect data from this app"
- Save

#### E. App Store Listing
**Description**:
```
Instantly transcribe your voice to text in any macOS app. Hold a key, speak, and watch your words appear—100% offline and private.

FEATURES
• 100% offline transcription - Your voice never leaves your Mac
• Works everywhere - Safari, VS Code, Slack, Terminal, and more
• Real-time preview - See your words as you speak
• Multiple AI models - Choose speed vs accuracy
• 90+ languages supported
• Privacy-first - No cloud, no analytics, no data collection

Powered by OpenAI's Whisper AI, running entirely on your device.

UPGRADE TO PRO PACK
• Code Mode - Dictate code with spoken symbols and casing
• Per-App Profiles - Auto-switch settings per application
• Personal Dictionary - Custom words for better accuracy
• Pro Insertion Engine - Advanced paste with fallbacks

PRIVACY FOCUSED
All transcription happens on your Mac. No internet required after initial model download. No data collection, no tracking, no cloud uploads.
```

**Keywords** (100 chars max):
```
voice to text,speech to text,dictation,transcription,whisper,developer,code,privacy,offline
```

**Support URL**: `https://whispererapp.com`
**Marketing URL**: `https://whispererapp.com`

**What's New in This Version**:
```
Initial release of Whisperer - Private Voice to Text for Mac

Features:
• 100% offline voice transcription
• Works in any macOS app
• Real-time preview while speaking
• Multiple AI models
• 90+ languages supported
• Pro Pack with Code Mode, Profiles, and Dictionary
```

#### F. Upload Screenshots
- Drag and drop your 3-5 screenshots from Step 2
- First screenshot shows in search results (make it compelling!)

---

### Step 6: Build and Archive for App Store (10 minutes)

**Status**: ⏳ TO DO

**In Xcode**:

1. **Clean Build Folder**:
   - Menu: `Product → Clean Build Folder` (Cmd+Shift+K)

2. **Select Destination**:
   - Top toolbar: Select "Any Mac" (not "My Mac")

3. **Create Archive**:
   - Menu: `Product → Archive`
   - Wait for build (2-5 minutes)
   - Organizer window opens automatically

4. **Validate Archive** (recommended):
   - Select your archive
   - Click "Validate App"
   - Select your team
   - Click "Validate"
   - Wait for validation to complete

5. **Distribute to App Store**:
   - Click "Distribute App"
   - Select "App Store Connect" → Next
   - Select "Upload" → Next
   - Check options:
     - ✅ Upload your app's symbols (for crash reports)
     - ✅ Manage Version and Build Number
   - Click Next
   - Select "Automatically manage signing" → Next
   - Review summary → Click "Upload"
   - Wait for upload (5-15 minutes)

**If you get signing errors**:
- Make sure you selected your Apple Developer team
- Check that Bundle ID matches: `com.ivy.whisperer`
- Try: Xcode → Preferences → Accounts → Download Manual Profiles

---

### Step 7: Wait for Build Processing (30-60 minutes)

**Status**: ⏳ WAITING (after upload)

After upload completes:
1. Go to App Store Connect → TestFlight tab
2. Your build will show "Processing"
3. Wait 30-60 minutes for processing to complete
4. You'll get an email when ready
5. Status changes to "Ready to Submit"

**Optional: Test with TestFlight**
- Download TestFlight from Mac App Store
- Add yourself as internal tester
- Test the full app before review
- Recommended to catch issues early!

---

### Step 8: Submit for Review (15 minutes)

**Status**: ⏳ TO DO (after processing complete)

1. Go to App Store Connect → "App Store" tab
2. Click on version "1.0 - Prepare for Submission"
3. Under "Build", click "Select a build before you submit your app"
4. Choose your processed build → Done
5. Scroll to "App Review Information"
6. Add **Review Notes**:

```
Testing Instructions:

1. The app requires these permissions on first launch:
   - Microphone (for voice input)
   - Accessibility (to insert text into other apps)
   - Input Monitoring (to detect Fn key)

2. First launch downloads an AI model (~500MB) - this is one-time and normal

3. To test transcription:
   - Open TextEdit or any text field
   - Hold the Fn key
   - Speak clearly: "Hello, this is a test"
   - Release Fn key
   - Text should appear immediately

4. The Pro Pack IAP:
   - Product ID: com.ivy.whisperer.propack
   - Price: $X.XX
   - Unlocks: Code Mode, Per-App Profiles, Personal Dictionary, Pro Insertion
   - Can be tested in Sandbox

5. App works 100% offline after model download

Contact: [YOUR_EMAIL]
Website: https://whispererapp.com
```

7. Add your **Contact Information**
8. Click "Save"
9. Click **"Submit for Review"**
10. Confirm submission

---

## 📊 Timeline to Launch

From where you are now:

1. **Today**: Steps 1-2 (Add files, take screenshots) - 30 minutes
2. **Wait**: Developer account approval - 0-48 hours
3. **Day 1**: Steps 4-6 (App Store Connect setup, upload) - 2 hours
4. **Wait**: Build processing - 1 hour
5. **Day 1**: Step 8 (Submit for review) - 15 minutes
6. **Wait**: App Review - 1-3 days typically
7. **Launch Day**: Click "Release" when approved!

**Total active time**: ~3 hours
**Total calendar time**: 2-5 days

---

## ✅ Quick Summary

**What you have**:
- ✅ Fully implemented Track A (App Store foundation)
- ✅ Website with privacy policy
- ✅ Code updated and building successfully
- ✅ Pro Pack IAP infrastructure ready

**What you need**:
- ⏳ Add Acknowledgments.txt to Xcode target
- ⏳ Take 3-5 screenshots
- ⏳ Wait for developer account (if not approved)
- ⏳ Configure App Store Connect
- ⏳ Upload build
- ⏳ Submit for review

**You're almost there!** The hard work (Track A implementation) is done. Now it's just configuration and uploading.

---

## 🆘 Need Help?

- **Full guide**: See `MAC_APP_STORE_SUBMISSION_GUIDE.md`
- **Immediate steps**: See `IMMEDIATE_NEXT_STEPS.md`
- **Track A summary**: See `TRACK_A_COMPLETE.md`

---

**Next action**: Add Acknowledgments.txt to Xcode, then take screenshots! 📸

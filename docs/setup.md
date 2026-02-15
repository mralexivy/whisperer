# Xcode Project Setup Guide

Since the .xcodeproj file cannot be generated programmatically, follow these steps to create the Xcode project:

## Quick Setup (5 minutes)

### Step 1: Create New Xcode Project

1. Open **Xcode**
2. File → New → Project
3. Choose **macOS** → **App**
4. Click **Next**

### Step 2: Configure Project

Fill in the project settings:

- **Product Name**: `Whisperer`
- **Team**: (Select your team)
- **Organization Identifier**: `com.yourname` (or your identifier)
- **Bundle Identifier**: Will auto-generate as `com.yourname.Whisperer`
- **Interface**: **SwiftUI**
- **Language**: **Swift**
- **Storage**: None
- **Uncheck**: "Create Document-Based Application"
- **Include Tests**: Optional

Click **Next**, then save in: `/Users/alexanderi/Downloads/whisperer/Whisperer/`

⚠️ **Important**: Save it INSIDE the existing Whisperer directory (the one containing this file)

### Step 3: Clean Up Default Files

The new project will have some default files we don't need:

1. In Project Navigator, **delete** these files:
   - `ContentView.swift` (select, right-click → Delete → Move to Trash)
   - Any default preview files

### Step 4: Add Source Files

Now add all the source files to the project:

1. **Add WhispererApp.swift**:
   - Drag `WhispererApp.swift` from Finder into the Xcode project
   - ✅ Check "Copy items if needed"
   - ✅ Check "Create groups"
   - ✅ Select "Whisperer" target
   - Click **Add**

2. **Add AppState.swift**:
   - Same process as above

3. **Add UI folder**:
   - Drag entire `UI/` folder into project
   - Same options as above

4. **Add Audio folder**:
   - Drag `Audio/` folder into project

5. **Add KeyListener folder**:
   - Drag `KeyListener/` folder into project

6. **Add Transcription folder**:
   - Drag `Transcription/` folder into project

7. **Add TextInjection folder**:
   - Drag `TextInjection/` folder into project

8. **Add Resources**:
   - Drag `Resources/whisper-cli` into project
   - ⚠️ **Important**: Ensure it's added to "Copy Bundle Resources" in Build Phases

### Step 5: Replace Info.plist

1. In Xcode, select the existing `Info.plist` in Project Navigator
2. Delete it (Move to Trash)
3. Drag the new `Info.plist` from this directory into the project
4. Ensure it's added to the Whisperer target

### Step 6: Configure Build Settings

#### General Tab

1. Select the **Whisperer** project in Navigator
2. Select the **Whisperer** target
3. Go to **General** tab:
   - **Minimum Deployments**: macOS 13.0 or higher

#### Signing & Capabilities Tab

1. Go to **Signing & Capabilities**
2. Enable **Hardened Runtime**
3. Under Hardened Runtime capabilities, enable:
   - ✅ Audio Input
   - ✅ User Selected Files (Read Only)

#### Build Phases Tab

1. Go to **Build Phases**
2. Expand **Link Binary With Libraries**
3. Click **+** and add:
   - `AVFoundation.framework`
   - `IOKit.framework`
   - `ApplicationServices.framework`
   - (Cocoa.framework should already be there)

4. Expand **Copy Bundle Resources**
5. Verify `whisper-cli` is in the list
   - If not, click **+** and add it

### Step 7: Fix Any Compilation Errors

If you see any errors:

1. Check that all files are in the target:
   - Select each .swift file
   - Check "Target Membership" in File Inspector (right panel)
   - Ensure "Whisperer" is checked

2. Clean build folder: Product → Clean Build Folder (⌘⇧K)

### Step 8: Build and Run

1. **Build**: Product → Build (⌘B)
   - Fix any errors that appear
2. **Run**: Product → Run (⌘R)

The app should launch and appear in the menu bar!

## First Launch Setup

When you first run the app:

1. **Microphone Permission**: Click "OK" when prompted
2. **Accessibility Permission**:
   - System will prompt you to open System Settings
   - Go to Privacy & Security → Accessibility
   - Find "Whisperer" and toggle it ON
3. **Input Monitoring**: May prompt, click "Open System Settings" and enable
4. **Model Download**: The app will download the Whisper model (~1.5GB)
   - This happens automatically in the background
   - Check the menu bar icon's menu to see progress

## Testing

Once permissions are granted and model is downloaded:

1. Open any text app (Notes, TextEdit, browser)
2. Click in a text field
3. **Hold Fn (Globe) key**
4. Speak: "This is a test"
5. **Release Fn key**
6. Wait 2-3 seconds
7. Your text should appear!

## Troubleshooting Setup

### "Build Failed" Errors

**Swift Compiler Error**: Missing file references
- Solution: Check Step 4 again, ensure all files are added

**"No such module 'AVFoundation'"**
- Solution: See Step 6, Build Phases, add AVFoundation.framework

**"whisper-cli not found at runtime"**
- Solution: Check Build Phases → Copy Bundle Resources, ensure whisper-cli is listed

### Globe Key Issues

**System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys**
- Set Globe Key to "Do Nothing"

### Permission Issues

If permissions don't work:
1. Quit Whisperer
2. System Settings → Privacy & Security
3. Remove Whisperer from denied list
4. Relaunch Whisperer

## Alternative: Command Line Build (Advanced)

If you prefer not to use Xcode GUI:

```bash
# This won't work yet - requires .xcodeproj to exist first
xcodebuild -project Whisperer.xcodeproj -scheme Whisperer -configuration Release build
```

You MUST create the .xcodeproj via Xcode GUI first (Steps 1-2 above).

## Need Help?

Check the main README.md for:
- Architecture overview
- Component details
- Technical specifications

---

**Estimated setup time**: 5-10 minutes (plus model download time)

**Result**: Fully functional voice-to-text app in your menu bar! 🎙️

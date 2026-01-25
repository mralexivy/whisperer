# Open Existing Xcode Project and Add Files

All source files are now in the correct location. Follow these steps:

## Step 1: Open the Project

```bash
cd /Users/alexanderi/Downloads/whisperer/Whisperer/whisperer
open whisperer.xcodeproj
```

Or double-click on `whisperer.xcodeproj` in Finder.

## Step 2: Add All Files to Xcode

Once Xcode opens:

1. **Select all Swift files and resources**:
   - In Finder, navigate to: `/Users/alexanderi/Downloads/whisperer/Whisperer/whisperer/whisperer/`
   - Select these files and folders:
     - `WhispererApp.swift`
     - `AppState.swift`
     - `Info.plist`
     - `UI/` (entire folder)
     - `Audio/` (entire folder)
     - `KeyListener/` (entire folder)
     - `Transcription/` (entire folder)
     - `TextInjection/` (entire folder)
     - `Resources/` (entire folder)

2. **Drag into Xcode**:
   - Drag all selected items into the Xcode project navigator (left sidebar)
   - When the dialog appears:
     - ✅ **Copy items if needed** (should already be unchecked since they're in the right place)
     - ✅ **Create groups**
     - ✅ **Add to targets: whisperer**
   - Click **Add**

## Step 3: Configure Build Settings

### 3a. Link Frameworks

1. Select the project in navigator → Target → **Build Phases**
2. Expand **Link Binary With Libraries**
3. Click **+** and add:
   - `AVFoundation.framework`
   - `IOKit.framework`
   - `ApplicationServices.framework`

### 3b. Copy Resources

1. Still in **Build Phases**, expand **Copy Bundle Resources**
2. Verify `whisper-cli` is listed
3. If not, click **+** → Add Other → navigate to `Resources/whisper-cli`

### 3c. Signing & Capabilities

1. Go to **Signing & Capabilities** tab
2. Enable **Hardened Runtime**
3. Under Hardened Runtime → Resource Access, enable:
   - ✅ **Audio Input**
4. That's it! Other permissions (Accessibility, Input Monitoring) are requested at runtime

## Step 4: Build and Run

```
Product → Build (⌘B)
Product → Run (⌘R)
```

## Expected Behavior

When you run the app:

1. Menu bar icon appears (waveform)
2. First launch:
   - Microphone permission prompt → Allow
   - Accessibility permission prompt → Open System Settings → Enable
   - Input Monitoring permission → Allow
3. Model downloads automatically (~1.5GB, 5-10 minutes)
4. Once complete, test:
   - Hold **Fn key** → speak → release **Fn**
   - Text appears in focused field!

## Files Added

✅ 11 Swift files:
- WhispererApp.swift
- AppState.swift
- UI/OverlayPanel.swift
- UI/OverlayView.swift
- UI/WaveformView.swift
- Audio/AudioRecorder.swift
- KeyListener/GlobalKeyListener.swift
- Transcription/ModelDownloader.swift
- Transcription/WhisperRunner.swift
- TextInjection/TextInjector.swift

✅ Resources:
- Resources/whisper-cli (806 KB)
- Info.plist

## Troubleshooting

**"Duplicate symbols" error**:
- Remove any duplicate files from the project

**"Cannot find type 'AppState'"**:
- Clean build folder: Product → Clean Build Folder (⌘⇧K)
- Rebuild

**whisper-cli not found at runtime**:
- Check Build Phases → Copy Bundle Resources
- Ensure whisper-cli has execute permissions (it should)

---

**Your app is ready to build!** 🎉

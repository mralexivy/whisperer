# Whisperer - Voice-to-Text macOS App

Native macOS menu bar app for hold-to-talk voice transcription using local whisper.cpp.

## Features

- **Hold Fn (Globe) key** to record audio with live waveform
- **Release Fn** to stop and transcribe using whisper.cpp large-v3-turbo
- **Auto-paste** transcribed text into any focused text field
- **Works across all apps** - Safari, Chrome, VS Code, Slack, Notes, etc.
- **Completely offline** - local transcription, no cloud required
- **Fast** - Apple Silicon optimized with Metal acceleration

## Project Structure

```
Whisperer/
├── WhispererApp.swift           # App entry point
├── AppState.swift               # State machine
├── Info.plist                   # Permissions
│
├── UI/
│   ├── OverlayPanel.swift       # Floating panel
│   ├── OverlayView.swift        # SwiftUI overlay
│   └── WaveformView.swift       # Audio visualization
│
├── Audio/
│   └── AudioRecorder.swift      # Mic capture + waveform
│
├── KeyListener/
│   └── GlobalKeyListener.swift  # Fn key detection
│
├── Transcription/
│   ├── WhisperRunner.swift      # whisper.cpp executor
│   └── ModelDownloader.swift    # Model download
│
├── TextInjection/
│   └── TextInjector.swift       # Cross-app text paste
│
└── Resources/
    └── whisper-cli              # Whisper.cpp binary
```

## Setup Instructions

### 1. Create Xcode Project

1. Open Xcode
2. Create New Project → macOS → App
3. Product Name: **Whisperer**
4. Interface: **SwiftUI**
5. Language: **Swift**
6. Uncheck "Create Document-Based Application"
7. Save in this directory

### 2. Add Source Files

1. Delete the default ContentView.swift
2. Add all Swift files from the directories above:
   - Drag folders into Xcode: UI/, Audio/, KeyListener/, Transcription/, TextInjection/
   - Add WhispererApp.swift and AppState.swift
3. Replace Info.plist with the one provided

### 3. Add whisper-cli Binary

1. In Xcode, add `Resources/whisper-cli` to the project
2. In Build Phases → Copy Bundle Resources, verify whisper-cli is included
3. Select whisper-cli in project navigator
4. In File Inspector, ensure "Target Membership" is checked

### 4. Configure Build Settings

1. Select project in navigator → Target → General
2. Minimum Deployments: **macOS 13.0** or higher
3. In Signing & Capabilities:
   - Enable "Hardened Runtime"
   - Under Hardened Runtime, enable:
     - Audio Input
     - User Selected Files (Read Only)

### 5. Link Frameworks

In Build Phases → Link Binary With Libraries, add:
- AVFoundation.framework
- Cocoa.framework
- IOKit.framework
- ApplicationServices.framework

### 6. Build and Run

1. Build the project (⌘B)
2. Run (⌘R)
3. On first launch:
   - Grant **Microphone** permission when prompted
   - Grant **Accessibility** permission in System Settings > Privacy & Security > Accessibility
   - Grant **Input Monitoring** if prompted
   - The app will download the whisper model (~1.5GB) - this may take a few minutes

## Usage

1. **Menu Bar**: Look for the Whisperer icon (waveform)
2. **Configure Globe Key**:
   - Go to System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys
   - Set Globe Key to "Do Nothing" (prevents emoji picker conflict)
3. **Record**: Hold Fn (Globe) key
4. **Stop**: Release Fn key or click X in popup
5. **Text Injection**: Transcribed text automatically appears in focused text field

## Permissions Required

| Permission | Why Needed | Where to Grant |
|------------|-----------|----------------|
| Microphone | Record audio | Auto-prompted on first use |
| Accessibility | Insert text across apps | System Settings > Privacy & Security > Accessibility |
| Input Monitoring | Capture Fn key globally | Auto-prompted on first use |

## Troubleshooting

### Fn Key Not Working

1. Check Globe key setting: System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys
2. Ensure "Input Monitoring" permission is granted
3. Try restarting the app

### No Text Appearing After Transcription

1. Verify Accessibility permission is granted
2. Make sure a text field is focused before releasing Fn
3. Check Console.app for error messages

### Model Download Failing

1. Check internet connection
2. Verify disk space (~2GB needed)
3. Model location: `~/Library/Application Support/Whisperer/`
4. Manual download: https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

### App Not Appearing in Menu Bar

1. Verify LSUIElement=YES in Info.plist
2. Check if app is running in Activity Monitor
3. Restart Mac if needed

## Technical Details

- **Audio Format**: Mono, 16kHz, PCM Int16 (optimal for Whisper)
- **Model**: ggml-large-v3-turbo (~1.5GB)
- **Transcription**: Local whisper.cpp with Metal acceleration
- **Fn Detection**: 3-layer approach (CGEventTap + IOKit HID + NSEvent)
- **Text Injection**: Accessibility API with clipboard fallback

## Building for Distribution

1. Archive the app (Product → Archive)
2. Export for Mac App Store or Developer ID
3. Notarize for Gatekeeper (required for distribution outside App Store)

## License

All source code is provided as-is for the Whisperer project.

## Credits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) - High-performance inference of OpenAI's Whisper model
- [OpenAI Whisper](https://github.com/openai/whisper) - Robust speech recognition model

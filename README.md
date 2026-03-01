# Whisperer

A native macOS menu bar app for instant voice-to-text transcription. Hold a key, speak, release — your words appear wherever you're typing. Completely offline, powered by whisper.cpp with Apple Silicon optimization.

---

## Features

### Core Functionality

- **Hold-to-Record Transcription** — Hold the Fn key (or any custom shortcut), speak, and release. Your transcribed text is automatically inserted into the focused text field.
- **100% Offline** — All transcription happens locally on your Mac using whisper.cpp. No internet connection required, no data leaves your device.
- **Works Everywhere** — Automatically pastes transcribed text into any app: Safari, Chrome, VS Code, Slack, Notes, Terminal, and more.
- **Real-time Preview** — See your words appear as you speak with live streaming transcription.
- **Apple Silicon Optimized** — Metal GPU acceleration for fast, efficient transcription.

### Audio

- **System Audio Muting** — Optionally mutes other audio during recording to prevent feedback and interference (great for Zoom calls).
- **Sound Feedback** — Distinct audio cues (Tink/Pop) confirm when recording starts and stops.
- **Multiple Microphones** — Choose from any connected input device, or use the system default.
- **Live Waveform** — Visual feedback shows audio levels in real-time during recording.
- **Auto-Recovery** — Automatically recovers from audio device disconnections or system changes.

### Keyboard Shortcuts

- **Fn Key Detection** — Detects Fn key via `NSEvent.flagsChanged` (keyCode 63) and custom shortcuts via Carbon `RegisterEventHotKey`. App Store compliant — no event taps or input monitoring.
- **Smart Combo Filtering** — Automatically cancels recording when you press Fn+Volume, Fn+Brightness, or other Fn+key combinations — no accidental recordings during Zoom calls.
- **Customizable Shortcuts** — Configure any key or modifier combination as your recording trigger.
- **Two Recording Modes**:
  - **Hold to Record** (default) — Hold the shortcut to record, release to stop and transcribe.
  - **Toggle Mode** — Press once to start, press again to stop.
- **Fn Calibration** — Learn your specific keyboard's Fn key for reliable detection.

### Whisper Models

Choose from 10 different models based on your needs:

| Model | Size | Speed | Best For |
|-------|------|-------|----------|
| **Large V3 Turbo Q5** | 547 MB | Fast | Recommended — best balance of speed, size & accuracy |
| Large V3 Turbo | 1.5 GB | Fast | 8x faster than Large V3, high accuracy |
| Distil Large V3 | 756 MB | Very Fast | 6x faster than Large V3, good accuracy |
| Distil Small (EN) | 166 MB | Very Fast | English only, 2x faster than Small |
| Large V3 Q5 | 1.1 GB | Medium | Quantized Large V3, smaller file |
| Large V3 | 2.9 GB | Slowest | Maximum accuracy |
| Medium | 1.5 GB | Slow | Good accuracy, moderate size |
| Small | 466 MB | Medium | Balanced option |
| Base | 142 MB | Fast | Quick transcription |
| Tiny | 75 MB | Fastest | Minimal resources |

- **In-App Download** — Download models directly from Hugging Face with progress tracking.
- **Model Pre-loading** — Keeps the selected model in memory for instant recording start (no loading delay).
- **Hot-Swapping** — Switch between downloaded models without restarting.

### Language Support

- **100+ Languages** — Supports all languages available in OpenAI Whisper.
- **Language Selection** — Choose your transcription language in settings for best accuracy.
- **Auto-Detection** — Optional automatic language detection (may be less reliable than explicit selection).

### Voice Activity Detection (VAD)

- **Silero VAD Integration** — Optional voice activity detection for improved transcription accuracy.
- **Automatic Download** — The small (~2MB) VAD model downloads automatically if needed.
- **Graceful Fallback** — App works perfectly fine without VAD if loading fails.

### Streaming Transcription

The app uses an advanced streaming architecture:

- **2-Second Chunks** — Processes audio every 2 seconds for real-time feedback.
- **0.5s Overlap** — Audio overlap between chunks prevents word cutoff at boundaries.
- **Context Carrying** — Uses previous transcription as a prompt for better continuity.
- **Deduplication** — Automatically removes repeated words at chunk boundaries.
- **Final Pass Refinement** — Re-transcribes the complete recording when you stop for maximum accuracy.
- **Recording Saving** — Optionally saves recordings as WAV files with timestamps and transcription previews in the filename.
- **5-Minute Maximum** — Memory-bounded to prevent issues on very long recordings.

### User Interface

- **Menu Bar App** — Lives quietly in your menu bar, no dock icon.
- **Floating Overlay** — Appears during recording showing:
  - Live waveform visualization
  - Real-time transcription text (ticker-style, last ~120 characters)
  - Recording status indicator with pulsing dot
  - Cancel button
- **Dark Navy Theme** — Unified always-dark design with blue-purple accents across all windows.
- **Tabbed Settings**:
  - **Status** — Current model, microphone, shortcut, and quick usage guide
  - **Models** — Browse and download available models
  - **Settings** — Audio, language, microphone, shortcut, permissions, and diagnostics

### Reliability & Diagnostics

- **Centralized Logging** — Detailed logs saved to `~/Library/Logs/Whisperer/`
- **Log Rotation** — Automatic rotation at 10MB, keeps 7 historical files
- **Crash Handler** — Records crash information for debugging
- **Queue Health Monitoring** — Internal monitoring for stability
- **Graceful Shutdown** — Properly releases whisper resources on quit to prevent crashes
- **Startup Grace Period** — 1.5s buffer after recording starts to ignore audio configuration changes

---

## Requirements

- **macOS 13.0** (Ventura) or later
- **Apple Silicon** recommended (Intel Macs supported but slower)
- **~2GB disk space** for the recommended model

---

## Permissions

Whisperer requires up to two system permissions:

| Permission | Purpose | Required? | How to Grant |
|------------|---------|-----------|--------------|
| **Microphone** | Record your voice for transcription | Yes | Auto-prompted on first use |
| **Accessibility** | Paste transcribed text at cursor (system-wide dictation) | Optional | System Settings → Privacy & Security → Accessibility |

A guided onboarding flow walks you through permissions on first launch. The app works fully without Accessibility — transcriptions copy to clipboard for manual paste.

---

## Installation

### From Xcode (Development)

1. **Clone or download** this repository
2. **Open** `whisperer.xcodeproj` in Xcode
3. **Select** your development team in Signing & Capabilities
4. **Build and Run** (⌘R)

### First Launch

1. **Complete onboarding** — Grant Microphone permission, download a model, configure your shortcut
2. **Configure Globe key** (optional but recommended):
   - Go to System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys
   - Set "Globe key" to "Do Nothing" (prevents emoji picker conflict)
3. **Wait for model download** — The default model (~547MB) downloads automatically
4. **Start using** — Hold Fn, speak, release!

---

## Usage

### Basic Workflow

1. **Focus** a text field in any application
2. **Hold** the Fn key (or your configured shortcut)
3. **Speak** — watch the live waveform and transcription preview
4. **Release** — your transcribed text appears in the text field

### Menu Bar

Click the Whisperer icon in your menu bar to:

- View current status and model
- Download and switch between models
- Configure settings (language, microphone, shortcut)
- Check permission status
- View logs for troubleshooting
- Quit the app (⌘Q)

### Tips

- **Speak clearly** and at a normal pace for best results
- **Pause briefly** before releasing to capture your last words
- **Use the recommended model** (Large V3 Turbo Q5) for the best speed/accuracy balance
- **Set your language explicitly** rather than using auto-detect for better accuracy
- **Enable audio muting** if you're on calls to prevent feedback

---

## Troubleshooting

### Fn Key Not Working

1. **Check Globe key setting**: System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys → Set Globe key to "Do Nothing"
2. **Try Fn calibration** in Settings → Shortcut (if available)
3. **Consider using a different shortcut** if Fn detection remains unreliable

### Arrow Keys Triggering Recording

This is handled automatically — the app filters out arrow key presses that set the Fn flag internally on macOS.

### Recording Cancels Unexpectedly

This is intentional when pressing Fn+key combinations (like Fn+Volume). The app detects these combos and cancels to prevent accidental recordings during normal keyboard use.

### No Text Appearing After Transcription

1. **Verify Accessibility permission** is granted
2. **Make sure a text field is focused** before releasing the shortcut
3. **Check if the app supports text injection** (some apps block programmatic text entry)

### Transcription Quality Issues

1. **Try a larger model** for better accuracy
2. **Set your language explicitly** instead of auto-detect
3. **Speak closer to the microphone**
4. **Reduce background noise** or enable audio muting
5. **Check your microphone selection** in Settings

### Model Download Failing

1. Check your internet connection
2. Verify disk space (~2GB for recommended model)
3. Check `~/Library/Application Support/Whisperer/` for partial downloads
4. Try a different model

### App Crashes on Quit

This is fixed in the current version through graceful shutdown handling. If you experience crashes, check `~/Library/Logs/Whisperer/crash.log` for details.

### Viewing Logs

1. Open the menu bar menu
2. Go to Settings → Diagnostics
3. Click "Open Logs Folder"
4. View `whisperer.log` for detailed application logs

---

## Architecture

```
Whisperer/
├── WhispererApp.swift              # App entry point & menu bar setup
├── AppState.swift                  # Global state machine & recording workflow
│
├── UI/
│   ├── OverlayPanel.swift          # Floating NSPanel window
│   ├── OverlayView.swift           # SwiftUI overlay content
│   └── WaveformView.swift          # Audio level visualization
│
├── Audio/
│   ├── AudioRecorder.swift         # AVAudioEngine microphone capture
│   ├── AudioMuter.swift            # System volume control
│   ├── AudioDeviceManager.swift    # Input device enumeration
│   └── SoundPlayer.swift           # Start/stop sound effects
│
├── KeyListener/
│   ├── GlobalKeyListener.swift     # flagsChanged + Carbon hotkey detection
│   └── ShortcutConfig.swift        # Shortcut configuration & persistence
│
├── Transcription/
│   ├── WhisperBridge.swift         # whisper.cpp Swift wrapper
│   ├── WhisperModel.swift          # Model definitions & metadata
│   ├── WhisperRunner.swift         # CLI-based transcription (legacy)
│   ├── StreamingTranscriber.swift  # Real-time streaming transcription
│   ├── ModelDownloader.swift       # Hugging Face model downloads
│   └── SileroVAD.swift             # Voice activity detection
│
├── TextInjection/
│   └── TextInjector.swift          # Clipboard + paste text entry
│
├── Permissions/
│   └── PermissionManager.swift     # Centralized permission handling
│
├── Core/
│   ├── Logger.swift                # File-based logging system
│   ├── CrashHandler.swift          # Crash detection & reporting
│   ├── SafeLock.swift              # Thread-safe locking primitives
│   ├── TaskTracker.swift           # Async task tracking
│   └── QueueHealthMonitor.swift    # Queue health diagnostics
│
└── Resources/
    ├── whisper-cli                 # whisper.cpp binary (if used)
    └── Assets.xcassets             # App icons & images
```

---

## Technical Details

- **Audio Format**: 16kHz mono PCM Float32 (optimal for Whisper)
- **Chunk Size**: 2 seconds with 0.5 second overlap
- **Maximum Recording**: 5 minutes (~19MB in memory)
- **Model Storage**: `~/Library/Application Support/Whisperer/`
- **Log Storage**: `~/Library/Logs/Whisperer/`
- **Preferences**: Standard UserDefaults

### Shortcut Detection (App Store Compliant)

- **Fn key**: `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` — detects modifier state changes via keyCode 63, not keystrokes
- **Custom shortcuts**: Carbon `RegisterEventHotKey` — standard macOS hotkey API, no Input Monitoring required

### Text Entry

- **Clipboard + paste**: Copy transcription to `NSPasteboard`, post synthetic Cmd+V via `CGEvent.post(tap: .cgAnnotatedSessionEventTap)`
- **Without Accessibility**: Text copies to clipboard for manual paste

---

## Building for Distribution

1. **Archive** the app (Product → Archive)
2. **Export** for Mac App Store or Developer ID
3. **Notarize** for Gatekeeper (required for distribution outside App Store)

---

## Credits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — High-performance C++ inference of OpenAI's Whisper model
- [OpenAI Whisper](https://github.com/openai/whisper) — Robust speech recognition model
- [Silero VAD](https://github.com/snakers4/silero-vad) — Voice activity detection

---

## License

All source code is provided as-is for the Whisperer project.

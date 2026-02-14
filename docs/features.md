# Whisperer - Features Documentation

**Voice-to-Text for macOS** | Powered by whisper.cpp | 100% Offline

---

## Core Features

### Speech-to-Text Transcription
- **Real-time streaming transcription** with live preview during recording
- **Offline processing** - all transcription happens locally using whisper.cpp
- **Multi-language support** - configurable transcription language with auto-detect option
- **Final pass refinement** - re-transcribes complete audio at end for maximum accuracy

### Keyboard Shortcut Activation
- **Fn key** as default trigger (hold to record, release to transcribe)
- **Configurable shortcuts** - supports custom key + modifier combinations
- **Recording modes**: Hold-to-record or Toggle mode
- **Combo detection** - Fn+key combos (like Fn+F1) are filtered out to prevent accidental triggers
- **Fn key calibration** - learns your specific keyboard's Fn key for reliable detection
- **Multi-layer input detection**: CGEventTap, IOKit HID, and NSEvent monitors for maximum compatibility

### Text Injection
- **Accessibility API injection** - directly inserts text into focused text field
- **Clipboard fallback** - uses Cmd+V paste when direct injection unavailable
- **Preserves clipboard** - restores previous clipboard content after paste

---

## Audio System

### Recording
- **16kHz mono float32** audio format (optimized for Whisper)
- **Real-time amplitude monitoring** for waveform visualization
- **Configurable microphone selection** - choose from available input devices
- **Device recovery** - handles microphone disconnection/reconnection gracefully

### Audio Feedback
- **Start/stop sounds** - audible feedback when recording begins and ends
- **System audio muting** - optionally mutes other audio during recording (configurable)

### Voice Activity Detection (VAD)
- **Silero VAD integration** - neural network-based speech detection
- **Configurable sensitivity** - threshold, min speech/silence duration, padding
- **Streaming VAD** - real-time speech start/end detection
- **CPU-only processing** - runs on CPU to avoid GPU conflicts with Whisper

---

## Whisper Models

### Available Models
| Model | Size | Speed | Notes |
|-------|------|-------|-------|
| Tiny | 75 MB | Fastest | Quick, lower accuracy |
| Base | 142 MB | Fast | Good for simple dictation |
| Small | 466 MB | Medium | Balanced |
| Medium | 1.5 GB | Slow | High accuracy |
| Large V3 | 2.9 GB | Slowest | Maximum accuracy |
| Large V3 Turbo | 1.5 GB | Fast | 8x faster than Large V3 |
| **Large V3 Turbo Q5** | 547 MB | Fast | **Default** - best balance |
| Large V3 Q5 | 1.1 GB | Medium | Quantized, smaller file |
| Distil Large V3 | 756 MB | Very Fast | 6x faster than Large V3 |
| Distil Small (EN) | 166 MB | Very Fast | English only, 2x faster than Small |

### Model Management
- **On-demand download** from Hugging Face
- **Progress tracking** with percentage display
- **Pre-loading** - model stays in memory for instant recording start
- **Hot-swapping** - change models without restart

---

## Dictionary & Spell Correction

### SymSpell Fuzzy Matching
- **Edit distance matching** - finds corrections even with typos
- **Configurable sensitivity** (0-3 edit distance)
- **Phonetic matching** - catches homophones and similar-sounding words

### Dictionary Packs
- **Premium dictionary packs** - bundled correction databases
- **Pack management** - enable/disable individual packs
- **Version tracking** - automatic updates when pack versions change

### Custom Entries
- **User-defined corrections** - add your own terms
- **Categories** - organize entries by type
- **Enable/disable** - toggle individual entries
- **Import/Export** - JSON format for backup and sharing
- **Usage tracking** - counts how often each correction is applied

---

## Transcription History (Workspace)

### History Management
- **CoreData persistence** - all transcriptions saved locally
- **Search** - full-text search across transcriptions and notes
- **Filters** - All, Pinned, Flagged
- **Audio playback** - listen to original recordings
- **Waveform visualization** - generated from saved audio

### Record Features
- **Pin/Flag** - mark important transcriptions
- **Edit** - modify transcription text
- **Notes** - add context or annotations
- **Duration tracking** - records length of each recording
- **Model/Language metadata** - what settings were used

### Statistics
- Total recordings count
- Total words transcribed
- Total recording duration
- Average words per minute
- Days with recordings

### Quick Access
- **Fn+S shortcut** - toggle workspace window
- **Menu bar button** - open from status menu

---

## User Interface

### Menu Bar App
- **Accessory mode** - no dock icon, lives in menu bar
- **Status display** - shows current state (Ready, Listening, Transcribing)
- **Model badge** - indicates loaded model and status
- **Tab navigation** - Status, Models, Settings tabs

### Recording Overlay
- **Floating panel** - appears at screen bottom during recording
- **Non-activating** - doesn't steal focus from current app
- **Live transcription card** - shows text as you speak
- **Waveform visualization** - real-time audio amplitude display
- **State indicators** - visual feedback for recording/transcribing states

### Live Transcription Display
- **Typewriter animation** - text appears progressively
- **Keyword highlighting** - dictionary corrections shown with color
- **Correction popover** - click highlighted words to see original

---

## System Integration

### Permissions
- **Microphone** - for audio recording
- **Accessibility** - for text injection
- **Input Monitoring** - for global keyboard shortcuts

### App Store Ready
- **Receipt validation** - App Store licensing verification
- **Graceful shutdown** - proper resource cleanup on quit
- **Crash handling** - installed crash handlers with logging

### Diagnostics
- **Structured logging** - categorized log output (app, transcription, audio)
- **Log file access** - open logs folder from Settings
- **Crash log detection** - notifies if previous crash occurred
- **Queue health monitoring** - detects hung operations

---

## Technical Architecture

### Threading & Concurrency
- **SafeLock** - timeout-based locking to prevent deadlocks
- **MainActor isolation** - UI state on main thread
- **Background contexts** - CoreData operations off main thread
- **Async/await** - modern Swift concurrency throughout

### Memory Management
- **5-minute recording limit** - prevents unbounded memory growth (~19MB max)
- **Chunk-based processing** - 2-second audio chunks with 0.5s overlap
- **Explicit resource cleanup** - whisper/VAD contexts freed on shutdown

### Audio Pipeline
```
Microphone → AudioRecorder → StreamingTranscriber → WhisperBridge → DictionaryManager → TextInjector
                 ↓                    ↓
            Waveform UI          Live Preview
```

---

## Settings & Preferences

### Configurable Options
- **Transcription language** - 99 languages supported
- **Microphone selection** - system default or specific device
- **Keyboard shortcut** - Fn, modifier keys, or key combinations
- **Recording mode** - Hold-to-record or Toggle
- **Mute other audio** - pause system audio during recording
- **Dictionary enabled** - toggle spell correction
- **Fuzzy matching sensitivity** - 0 (exact) to 3 (loose)
- **Phonetic matching** - enable/disable sound-alike matching

### Persistence
All settings stored in UserDefaults:
- `selectedModel` - chosen Whisper model
- `selectedLanguage` - transcription language
- `muteOtherAudioDuringRecording` - audio muting preference
- `dictionaryEnabled` - spell correction toggle
- `fuzzyMatchingSensitivity` - edit distance setting
- `usePhoneticMatching` - phonetic correction toggle
- `dictionaryPackPreferences` - enabled packs and versions

---

## Version Info
- **Platform**: macOS (App Store)
- **Category**: Productivity
- **Privacy**: 100% offline - no data leaves your device

# Whisperer - Implementation Overview

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         WhispererApp                            │
│  Menu bar app (LSUIElement) with OverlayPanel                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                          AppState                               │
│  @MainActor singleton managing state machine + components       │
└─────────────────────────────────────────────────────────────────┘
        │              │              │              │
        ▼              ▼              ▼              ▼
┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐
│GlobalKey   │  │Audio       │  │Streaming   │  │Text        │
│Listener    │  │Recorder    │  │Transcriber │  │Injector    │
│(Fn detect) │  │(AVAudio)   │  │(whisper)   │  │(AX API)    │
└────────────┘  └────────────┘  └────────────┘  └────────────┘
                      │              │
                      ▼              ▼
               ┌─────────────────────────┐
               │     WhisperBridge       │
               │  (whisper.cpp native)   │
               └─────────────────────────┘
```

## Core Flow

1. **Fn Press** → `startRecording()` → Show overlay, start audio capture
2. **Audio chunks (1.5s)** → `StreamingTranscriber` → Live transcription in overlay
3. **Fn Release** → `stopRecording()` → Process remaining audio → Inject text

## Key Components

### AppState.swift
- Singleton state machine (`RecordingState` enum)
- Pre-loads WhisperBridge at startup for instant recording
- States: `idle` → `recording` → `stopping` → `inserting` → `idle`

### WhisperBridge.swift
- Native Swift wrapper for whisper.cpp C library
- GPU acceleration (Metal + Flash Attention)
- Thread-safe with `NSLock`
- Auto language detection (`wparams.language = nil`)

### StreamingTranscriber.swift
- Buffers audio samples, processes every 1.5 seconds
- Uses pre-loaded WhisperBridge (no disk I/O on start)
- Thread-safe `isProcessing` flag with lock
- Async transcription on background queue

### AudioRecorder.swift
- AVAudioEngine for real-time capture
- Converts to 16kHz mono float32 (whisper format)
- Streams samples via `onStreamingSamples` callback
- No file writing during recording (memory only)

### GlobalKeyListener.swift
- 3-layer Fn key detection:
  1. CGEventTap (primary)
  2. IOKit HID (backup)
  3. NSEvent global monitor

### OverlayPanel.swift
- Non-activating NSPanel (doesn't steal focus)
- Shows/hides based on recording state
- Positioned bottom-center of screen

## Model

- **ggml-large-v3-turbo.bin** (~1.5GB)
- Whisper 3 Turbo - fast + accurate
- Auto-downloaded on first run
- Pre-loaded into memory at app startup

## Performance Optimizations

| Optimization | Impact |
|--------------|--------|
| Model pre-loading | Instant recording start |
| 1.5s chunk streaming | Real-time transcription |
| GPU Metal + Flash Attention | Fast inference |
| Background queue transcription | No UI blocking |
| Thread-safe locks | No deadlocks |

## Dependencies

- whisper.cpp (static libraries)
- Metal.framework
- Accelerate.framework
- AVFoundation

## Required Permissions

1. **Microphone** - Audio capture
2. **Accessibility** - Text injection
3. **Input Monitoring** - Fn key detection

## File Structure

```
Whisperer/
├── WhispererApp.swift          # Entry point, AppDelegate
├── AppState.swift              # State machine, component wiring
├── Audio/
│   └── AudioRecorder.swift     # Mic capture, format conversion
├── KeyListener/
│   └── GlobalKeyListener.swift # Fn key detection
├── Transcription/
│   ├── WhisperBridge.swift     # whisper.cpp wrapper
│   ├── StreamingTranscriber.swift # Real-time chunking
│   ├── WhisperRunner.swift     # CLI fallback (unused)
│   └── ModelDownloader.swift   # First-run download
├── TextInjection/
│   └── TextInjector.swift      # AX API text insertion
└── UI/
    ├── OverlayPanel.swift      # NSPanel container
    ├── OverlayView.swift       # SwiftUI content
    └── WaveformView.swift      # Audio visualization
```

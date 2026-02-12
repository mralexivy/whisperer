# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Whisperer is a native macOS menu bar app for offline voice-to-text transcription. Users hold a key, speak, and release — transcribed text is injected into the focused text field. Powered by whisper.cpp with Apple Silicon Metal GPU acceleration. Entirely offline, no network required for transcription.

## Build Commands

```bash
# Build (Release)
xcodebuild build -project Whisperer/whisperer/whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS"

# Build (Debug)
xcodebuild build -project Whisperer/whisperer/whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"

# Clean build
xcodebuild clean build -project Whisperer/whisperer/whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"
```

There are no unit tests in this project. No linter is configured.

## Architecture

### Entry Point & State Machine

- **WhispererApp.swift** — `@main` SwiftUI app using `MenuBarExtra` (no dock icon, `.accessory` activation policy). Uses `@NSApplicationDelegateAdaptor` for `AppDelegate` which initializes all components.
- **AppState.swift** — `@MainActor` singleton (`AppState.shared`) managing the recording state machine. States flow: `idle → recording → stopping → transcribing → inserting → idle`. Also holds `@Published` references to all subsystem components (AudioRecorder, GlobalKeyListener, WhisperBridge, etc.).

### Audio Pipeline

```
Microphone → AudioRecorder → StreamingTranscriber → WhisperBridge → CorrectionEngine → TextInjector
                 ↓                    ↓
            Waveform UI          Live Preview
```

- **AudioRecorder** — `AVAudioEngine` capture, converts to 16kHz mono Float32 (Whisper's required format). Streams samples via callback.
- **StreamingTranscriber** — Buffers audio, processes 2-second chunks with 0.5s overlap. Uses context carrying (previous transcription as prompt) and deduplication. Does a final-pass re-transcription of the complete recording on stop.
- **WhisperBridge** — Native Swift wrapper around the whisper.cpp C library. Manages `whisper_context` lifecycle, Metal GPU acceleration. Thread-safe with locks.
- **SileroVAD** — Optional CoreML-based voice activity detection (~2MB model, CPU-only to avoid GPU contention with Whisper).

### Key Detection

- **GlobalKeyListener** — 3-layer Fn key detection: CGEventTap (primary) → IOKit HID (backup) → NSEvent monitor. Filters Fn+key combos to prevent accidental recordings.
- **ShortcutConfig** — Persists user's chosen shortcut to UserDefaults.

### Text Injection

- **TextInjector** — Primary: Accessibility API (`AXUIElementSetAttributeValue`). Fallback: clipboard + simulated Cmd+V. Restores previous clipboard content after paste.

### Dictionary & Spell Correction

- **CorrectionEngine** — Applies corrections using exact HashMap lookup, multi-word phrase matching, SymSpell fuzzy matching, and PhoneticMatcher.
- **DictionaryManager** — Manages dictionary entries (CoreData-backed via DictionaryEntryEntity), dictionary packs, and user custom entries.
- **SpellValidator** — Prevents fuzzy matching from incorrectly "correcting" valid English words.

### UI Layer

- **OverlayPanel** — Non-activating `NSPanel` that appears during recording at screen bottom. Doesn't steal focus from the current app.
- **OverlayView / LiveTranscriptionCard** — SwiftUI views showing waveform, live transcription text, and recording status.
- **HistoryWindowManager / HistoryWindow** — Separate window for transcription history (CoreData-persisted via `HistoryDatabase`).

### Core Infrastructure

- **Logger** — Custom file-based logging to `~/Library/Logs/Whisperer/` with rotation (10MB, 7 files). Subsystems: `.app`, `.audio`, `.transcription`, etc.
- **SafeLock** — Timeout-based NSLock wrapper to prevent deadlocks.
- **CrashHandler** — Signal handler that writes crash info to `~/Library/Logs/Whisperer/crash.log`.
- **QueueHealthMonitor** — Detects hung operations on dispatch queues.

## Key Paths

- **Source code**: `Whisperer/whisperer/whisperer/` (Swift files organized in Audio/, Core/, Dictionary/, History/, KeyListener/, Licensing/, Permissions/, Store/, TextInjection/, Transcription/, UI/)
- **Xcode project**: `Whisperer/whisperer/whisperer.xcodeproj`
- **whisper.cpp**: `whisper.cpp/` (vendored C++ library, not a git submodule)
- **Model storage** (runtime): `~/Library/Application Support/Whisperer/`
- **Log storage** (runtime): `~/Library/Logs/Whisperer/`
- **Bundle ID**: `com.ivy.whisperer`

## Concurrency Model

- `AppState` is `@MainActor`-isolated. All UI state updates go through it.
- `StreamingTranscriber` and `WhisperBridge` use `SafeLock` (timeout-based NSLock) for thread safety, not Swift actors.
- Audio processing and Whisper inference happen on background `DispatchQueue`s.
- 5-minute max recording limit prevents unbounded memory growth (~19MB max audio buffer).

## Custom Slash Commands

- `/final-review` — Launches 7 parallel review agents (Memory, Concurrency, Architecture, Consistency, Platform, State/Reliability, Security) then reconciles and applies fixes.

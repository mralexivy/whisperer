# Whisperer Architecture

## Entry Point & State Machine

**WhispererApp.swift** — `@main` SwiftUI app using `MenuBarExtra` (no dock icon, `.accessory` activation policy). Uses `@NSApplicationDelegateAdaptor` for `AppDelegate` which initializes all components.

**AppState.swift** — `@MainActor` singleton (`AppState.shared`) managing the recording state machine:

```
idle → recording(startTime) → stopping → transcribing(audioPath) → inserting(text) → idle
                                                                                  ↗
                                          downloadingModel(progress) ─────────────
```

**Why singleton?** Menu bar apps need centralized coordination. Multiple recording sources (Fn key, UI button) must sync through one truth source.

## Audio Pipeline

```
Microphone → AudioRecorder → StreamingTranscriber → WhisperBridge → CorrectionEngine → TextInjector
                 ↓                    ↓
            Waveform UI          Live Preview
```

- **AudioRecorder** — `AVAudioEngine` capture, converts to 16kHz mono Float32. Streams samples via `onStreamingSamples` callback.
- **StreamingTranscriber** — Buffers audio, processes 2s chunks with 0.5s overlap. Context carrying + deduplication. Final-pass re-transcription on stop.
- **WhisperBridge** — Swift wrapper around whisper.cpp C library. Manages `whisper_context` lifecycle, Metal GPU acceleration. Thread-safe with SafeLock.
- **SileroVAD** — Optional CoreML voice activity detection (~2MB model, CPU-only to avoid GPU contention).

## Key Design Decisions

### 1. SafeLock over Swift Actors
**Decision**: `SafeLock` (timeout-based NSLock) for WhisperBridge and StreamingTranscriber, not Swift actors.
**Why**: whisper.cpp is blocking C code. Swift actors suspend on await, not block. SafeLock provides timeout protection to prevent deadlocks. Timeout is 10s on Apple Silicon, 60s on Intel.
**Pitfall**: Never hold SafeLock from main thread if background work might need it.

### 2. Three-Layer Key Detection
**Decision**: CGEventTap (primary) → IOKit HID (backup) → NSEvent monitor (fallback).
**Why**: The Fn key behaves differently across keyboard types and macOS versions. Some keyboards don't generate CGEvents for Fn. IOKit catches what CGEventTap misses. NSEvent is the safety net.
**Pitfall**: Must filter Fn+key combos (Fn+F1 = brightness) to prevent accidental recordings.

### 3. Five-Minute Recording Limit
**Decision**: Hard cap at 5 minutes (~19MB audio buffer at 16kHz mono Float32).
**Why**: Unbounded audio buffering causes OOM on long sessions. 4,800,000 samples = ~19MB.
**Pitfall**: Don't remove this limit without implementing streaming-to-disk.

### 4. Pre-loaded Whisper Model
**Decision**: Model stays in memory after first load. WhisperBridge is created once and reused.
**Why**: Instant recording start. Loading large-v3-turbo takes 2-5s. Re-loading on every recording would add unacceptable latency.
**Pitfall**: ~1.5GB memory footprint for large models. This is intentional.

### 5. Text Injection: Accessibility API + Clipboard Fallback
**Decision**: Primary is `AXUIElementSetAttributeValue`. Fallback is clipboard + simulated Cmd+V.
**Why**: Accessibility API is instant and doesn't touch clipboard. But it doesn't work in all apps (Electron apps, some terminals). Clipboard fallback restores previous clipboard content after paste.

### 6. Non-Activating Overlay Panel
**Decision**: `NSPanel` with `[.borderless, .nonactivatingPanel]`, `hasShadow = false`.
**Why**: The recording overlay must NOT steal focus from the app where text will be inserted. `nonactivatingPanel` keeps the previous app as key window.
**Pitfall**: Use `.orderFront()`, NEVER `.makeKey()` or `.makeKeyAndOrderFront()`.

### 7. Context Carrying for Transcription
**Decision**: Last 100 characters of previous transcription passed as `initial_prompt` to next chunk.
**Why**: Whisper produces better continuity when it knows what came before. Reduces word repetition at chunk boundaries.

### 8. Final-Pass Re-transcription
**Decision**: On stop, re-transcribe the entire recording for final output (ignoring streaming results).
**Why**: Full-context transcription is significantly more accurate than stitched chunks. The streaming preview is for UX; the final pass is for accuracy.

## Component Ownership

```
WhispererApp
  └── AppDelegate
        └── AppState.shared (@MainActor)
              ├── AudioRecorder (owned, optional)
              ├── GlobalKeyListener (owned, optional)
              ├── WhisperRunner (owned, optional)
              ├── WhisperBridge (private, pre-loaded)
              ├── SileroVAD (private, optional)
              ├── StreamingTranscriber (private, created per recording)
              ├── TextInjector (owned, optional)
              ├── AudioMuter (owned, optional)
              ├── SoundPlayer (owned, optional)
              └── AudioDeviceManager.shared (shared singleton)
```

**Rule**: AppState holds service references. Services NEVER hold AppState references. Services communicate back via closures (`onStreamingSamples`, `onTranscription`).

## Dependency Direction

```
UI Layer (SwiftUI Views)
    ↓ reads @Published, calls methods
AppState (@MainActor singleton)
    ↓ holds references, calls methods
Services (AudioRecorder, WhisperBridge, TextInjector, etc.)
    ↓ uses
Infrastructure (Logger, SafeLock, CrashHandler)
```

**Never**: Service importing SwiftUI. View directly calling a Service (go through AppState). Infrastructure depending on Services.

## Data Persistence

| Data | Storage | Why |
|------|---------|-----|
| Transcription history | CoreData (`WhispererHistory.xcdatamodeld`) | Complex queries, relationships |
| Dictionary entries | CoreData (`DictionaryEntryEntity`) | Structured data, search |
| User preferences | UserDefaults | Simple key-value (model, language, mute) |
| Audio recordings | File system (`~/Library/Application Support/Whisperer/Recordings/`) | Large binary data |
| Whisper models | File system (`~/Library/Application Support/Whisperer/`) | ~500MB-1.5GB files |
| Logs | File system (`~/Library/Logs/Whisperer/`) | Rotation, crash recovery |

## Common Pitfalls

1. **WhisperBridge.transcribe() is blocking** — NEVER call from main thread. Always use `transcribeAsync()` or call from background DispatchQueue.

2. **OverlayPanel focus theft** — Use `.orderFront(nil)`, never `.makeKeyAndOrderFront(nil)`. The panel must not become key window.

3. **Audio engine config changes during muting** — `AudioMuter` changing system audio triggers `AVAudioEngineConfigurationChange` notification. AudioRecorder has a 1.5s startup grace period to ignore these.

4. **CoreData on wrong thread** — `HistoryManager` and `DictionaryManager` must use proper CoreData concurrency (performBackgroundTask for writes).

5. **Retain cycles in Task closures** — `Task { }` captures `self` strongly. Always use `[weak self]` in `Task.detached` and stored closures.

6. **VAD is optional** — The app works without SileroVAD. Never assume `sileroVAD != nil`. Always check: `vadEnabled = vad != nil`.

7. **Model download vs model loading** — `isModelDownloaded()` checks file existence. `isModelLoaded` checks if WhisperBridge has loaded the model into memory. Both must be true before recording.

8. **Clipboard restoration** — TextInjector's clipboard fallback saves and restores previous clipboard content. The restoration delay must be long enough for paste to complete but short enough to feel instant.

## Deep Reference

For whisper.cpp C interop details (context lifecycle, threading, C string lifetime, streaming pipeline, shutdown sequence), see [docs/references/whisper-cpp-integration.md](docs/references/whisper-cpp-integration.md).

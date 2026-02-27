# Whisperer Architecture

## Entry Point & State Machine

**WhispererApp.swift** — `@main` SwiftUI app using `MenuBarExtra` (no dock icon, `.accessory` activation policy). Uses `@NSApplicationDelegateAdaptor` for `AppDelegate` which initializes all components. Also contains `MBColors` (menu bar color palette), `MenuBarWindowConfigurator` (NSViewRepresentable for flat window chrome), and all menu bar tab views.

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
- **StreamingTranscriber** — Buffers audio, processes 2s chunks with 0.5s overlap (single-segment mode for speed). Context carrying + deduplication. Tail-only final pass on stop (only transcribes unprocessed audio after the last chunk, not the entire recording).
- **WhisperBridge** — Swift wrapper around whisper.cpp C library. Manages `whisper_context` lifecycle, Metal GPU acceleration. Thread-safe with SafeLock. Uses deterministic greedy decoding (temperature=0, no fallback ladder) and performance-core-aware thread count.
- **SileroVAD** — Optional Silero voice activity detection (~2MB model, CPU-only to avoid GPU contention). Provides both full segment detection and lightweight `hasSpeech()` probability check.

## Key Design Decisions

### 1. SafeLock over Swift Actors
**Decision**: `SafeLock` (timeout-based NSLock) for WhisperBridge and StreamingTranscriber, not Swift actors.
**Why**: whisper.cpp is blocking C code. Swift actors suspend on await, not block. SafeLock provides timeout protection to prevent deadlocks. Timeout is 10s on Apple Silicon, 60s on Intel.
**Pitfall**: Never hold SafeLock from main thread if background work might need it.

### 2. Key Detection (App Store Compliant)
**Decision**: `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` for Fn key + Carbon `RegisterEventHotKey` for key+modifier shortcuts.
**Why**: CGEventTap, IOKit HID, and global keyDown/keyUp monitors are rejected by App Store review (Guideline 2.4.5). The current approach uses only approved APIs: flagsChanged monitors modifier state changes (not keystrokes) and Carbon hotkeys are a standard macOS hotkey mechanism used by many approved apps.
**How it works**: Fn key detected via `event.keyCode == 63` in flagsChanged handler. Non-Fn shortcuts (e.g., Cmd+Shift+Space) registered via Carbon `RegisterEventHotKey` which fires pressed/released events for hold-to-record support.
**Pitfall**: Carbon hotkeys require proper cleanup — `UnregisterEventHotKey` and `RemoveEventHandler` in teardown. The `Unmanaged.passUnretained(self)` pointer must remain valid while the handler is registered.

### 3. Five-Minute Recording Limit
**Decision**: Hard cap at 5 minutes (~19MB audio buffer at 16kHz mono Float32).
**Why**: Unbounded audio buffering causes OOM on long sessions. 4,800,000 samples = ~19MB.
**Pitfall**: Don't remove this limit without implementing streaming-to-disk.

### 4. Pre-loaded Whisper Model
**Decision**: Model stays in memory after first load. WhisperBridge is created once and reused.
**Why**: Instant recording start. Loading large-v3-turbo takes 2-5s. Re-loading on every recording would add unacceptable latency.
**Pitfall**: ~1.5GB memory footprint for large models. This is intentional.

### 5. Text Injection: Accessibility API + Clipboard Fallback
**Decision**: Primary is `AXUIElementSetAttributeValue` (assistive text input). Fallback is clipboard + simulated Cmd+V via `CGEvent.post(tap: .cgAnnotatedSessionEventTap)`.
**Why**: Accessibility API is instant and doesn't touch clipboard. But it doesn't work in all apps (Electron apps, some terminals). Clipboard fallback restores previous clipboard content after paste. If Accessibility permission is denied entirely, text is copied to clipboard with a notification for the user to paste manually.
**Performance**: AX messaging timeout set to 100ms via `AXUIElementSetMessagingTimeout` to prevent blocking if the target app is hung. Text injection runs inline on the calling thread (not dispatched to a background queue) to avoid latency from queue contention.
**App Store framing**: Accessibility API usage is framed as assistive text input for dictation — this is its intended purpose and is approved by App Store review. `CGEvent.post` (posting synthetic events) is distinct from `CGEvent.tapCreate` (monitoring events) and does not require Input Monitoring.

### 6. Non-Activating Overlay Panel
**Decision**: `NSPanel` with `[.borderless, .nonactivatingPanel]`, `hasShadow = false`.
**Why**: The recording overlay must NOT steal focus from the app where text will be inserted. `nonactivatingPanel` keeps the previous app as key window.
**Pitfall**: Use `.orderFront()`, NEVER `.makeKey()` or `.makeKeyAndOrderFront()`.

### 7. Context Carrying for Transcription
**Decision**: Last 100 characters of previous transcription passed as `initial_prompt` to next chunk.
**Why**: Whisper produces better continuity when it knows what came before. Reduces word repetition at chunk boundaries.

### 8. Tail-Only Final Pass
**Decision**: On stop, only transcribe unprocessed audio after the last completed chunk (not the entire recording).
**Why**: Re-transcribing the full recording added seconds of latency after key release. Tail-only processing reduces final-pass latency by 10-15x while streaming chunks already provide good incremental results. Dictionary corrections are applied to the combined streaming + tail output.
**Pitfall**: If streaming quality degrades, consider adding a user preference for full re-transcription.

### 9. Deterministic Greedy Decoding
**Decision**: `temperature=0.0`, `temperature_inc=0.0` (no fallback ladder), greedy sampling with `best_of=1`.
**Why**: The default `temperature_inc=0.2` causes up to 6 decode retries per chunk at increasing temperatures when entropy/logprob thresholds aren't met. Each retry re-runs the full decoder. Disabling this makes per-chunk latency predictable. VAD already filters silence, so fallback retries add cost without benefit for dictation.

### 10. Performance-Core Thread Count
**Decision**: On Apple Silicon, query `hw.perflevel0.logicalcpu` to use only performance cores (minus 2 reserved for audio/UI). On Intel, cap at 8 threads.
**Why**: Using all cores (including efficiency cores) causes straggler effects where fast P-cores wait for slow E-cores. Reserving cores prevents contention with audio capture, VAD, and UI.

## Windows & UI Chrome

All windows share a unified dark navy theme (`#0C0C1A` background, `#14142B` card surfaces, blue-purple accents).

### Window Configuration Pattern
Every NSWindow is configured for flat dark appearance:
- `window.appearance = NSAppearance(named: .darkAqua)`
- `window.titlebarAppearsTransparent = true` (workspace only — menu bar uses `MenuBarWindowConfigurator`)
- `window.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)`
- `window.hasShadow = false` — flat appearance, no system border
- Content view layer: `cornerRadius = 10`, `masksToBounds = true`, `borderWidth = 0`

### Onboarding Window (OnboardingWindow + OnboardingView)
Borderless NSWindow (860x540) shown on first launch. Four-page guided setup:
1. **Welcome** — App introduction with brand animation
2. **Permissions** — Microphone + Accessibility permission requests
3. **Model Selection** — Download whisper model during setup
4. **Shortcut Setup** — Configure recording trigger key

Sets `hasCompletedOnboarding` in UserDefaults on completion. Launched from `AppDelegate.applicationDidFinishLaunching()` when flag is false.

### Menu Bar Window (MenuBarWindowConfigurator)
`NSViewRepresentable` that accesses the hosting NSWindow from SwiftUI's `MenuBarExtra` and applies the flat dark appearance. Necessary because `MenuBarExtra` doesn't expose its NSPanel directly.

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

8. **Clipboard restoration** — TextInjector's clipboard fallback saves and restores previous clipboard content after a 100ms paste delay. If Accessibility permission is denied, text is only copied to clipboard (no simulated paste) and a `TextCopiedToClipboard` notification is posted for the UI.

9. **AX messaging timeout** — Always set `AXUIElementSetMessagingTimeout` (100ms) on both the app element and the focused element before AX calls. A hung target app can otherwise block the entire text injection path indefinitely.

10. **Audio engine retry** — `AudioRecorder.startRecording()` retries once on ANY setup failure (not just device-specific errors). The retry tears down the engine completely via `cleanupEngineState()`, resets to the default device, waits 200ms, and tries again. This handles transient audio unit failures (error 1852797029) that occur when the audio device state changes between recordings.

## Deep Reference

For whisper.cpp C interop details (context lifecycle, threading, C string lifetime, streaming pipeline, shutdown sequence), see [docs/references/whisper-cpp-integration.md](docs/references/whisper-cpp-integration.md).

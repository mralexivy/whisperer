# Whisperer Agent Guide

## Critical Rules (Always Apply)

1. `AppState` is `@MainActor` — all UI state updates go through `AppState.shared`
2. `SafeLock` (timeout-based NSLock) for whisper.cpp thread safety, not Swift actors
3. `WhispererColors` only — no system semantic colors in workspace views
4. `Logger.shared` — no `print()` statements
5. 5-minute max recording limit prevents unbounded memory growth (~19MB)
6. `[weak self]` in all `Task.detached` closures and stored callbacks
7. Audio pipeline: Microphone → AudioRecorder → StreamingTranscriber → WhisperBridge → CorrectionEngine → TextInjector

## Naming Patterns

### Classes & Structs
- **Services**: `AudioRecorder`, `WhisperBridge`, `TextInjector` (noun + verb/purpose)
- **Managers**: `HistoryManager`, `DictionaryManager`, `AudioDeviceManager` (noun + Manager)
- **Views**: `TranscriptionRow`, `LiveTranscriptionCard`, `WaveformView` (semantic name + View)
- **Windows**: `HistoryWindow`, `OverlayPanel` (purpose + Window/Panel)
- **Errors**: `WhisperError`, `RecordingError`, `SafeLockError` (domain + Error, enums with `LocalizedError`)

### Properties
- **Bool flags**: `isRecording`, `isModelLoaded`, `isShuttingDown`, `memoryLimitReached`
- **Published state**: `@Published var state: RecordingState` (never `currentState` or `recordingState`)
- **Closures/callbacks**: `onStreamingSamples`, `onAmplitudeUpdate`, `onTranscription`, `onDeviceRecovery` (on + purpose)
- **Private backing with lock**: `_isProcessing` private, `isProcessing` computed with SafeLock
- **Constants**: `let maxRecordingDuration`, `let chunkDuration`, `let contextMaxLength`

### Methods
- **State transitions**: `startRecording()`, `stopRecording()`, `cancelRecording()`
- **Async variants**: `stopAsync()`, `transcribeAsync(samples:completion:)` — suffix `Async` or use `async` keyword
- **Internal helpers**: `private func processChunk()`, `private func performTranscription()`
- **Lifecycle**: `preloadModel()`, `preloadVAD()`, `releaseWhisperResources()`, `prepareForShutdown()`

## Error Handling

### Error Types — Enum with LocalizedError
```swift
enum WhisperError: Error, LocalizedError {
    case modelLoadFailed
    case transcriptionFailed
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load Whisper model"
        case .transcriptionFailed: return "Transcription failed"
        }
    }
}
```

### Error Propagation Pattern
- Services throw typed errors or return empty/default values
- AppState catches and sets `@Published var errorMessage: String?`
- Logging happens at the point of failure, before propagating
- `guard` + early return for precondition checks:
```swift
guard !isShuttingDown else {
    Logger.warning("Transcription skipped - shutting down", subsystem: .transcription)
    return ""
}
```

### SafeLock Error Handling
```swift
do {
    result = try ctxLock.withLock(timeout: lockTimeout) { ... }
} catch SafeLockError.timeout {
    Logger.error("Lock timeout after \(lockTimeout)s", subsystem: .transcription)
    return ""
} catch {
    Logger.error("Lock error: \(error.localizedDescription)", subsystem: .transcription)
    return ""
}
```

## Logging Discipline

### Use `Logger` static methods — NEVER `print()`
```swift
// Correct
Logger.debug("Buffer: \(currentCount)/\(chunkSize) samples", subsystem: .transcription)
Logger.info("WhisperBridge initialized", subsystem: .transcription)
Logger.warning("Selected device unavailable, using default", subsystem: .audio)
Logger.error("Failed to start audio engine: \(error)", subsystem: .audio)

// Wrong
print("Model loaded")  // NO — use Logger
```

### Log Levels
| Level | Usage |
|-------|-------|
| `.debug` | Development details, buffer states, progress. Filtered in Release builds. |
| `.info` | Operational events: model loaded, recording started, bridge initialized |
| `.warning` | Recoverable issues: device unavailable, lock timeout, VAD not loaded |
| `.error` | Failures requiring attention: transcription failed, engine start failed |
| `.critical` | Unrecoverable states (rarely used) |

### Subsystems
`.app`, `.audio`, `.transcription`, `.ui`, `.keyListener`, `.textInjection`, `.permissions`, `.model`

Choose the subsystem that matches the module the code lives in.

## Memory Management

### Weak self in closures and Tasks
```swift
// Task.detached — always [weak self]
Task.detached(priority: .userInitiated) { [weak self] in
    guard let self = self else { return }
    ...
}

// Callbacks — always [weak self]
audioRecorder?.onStreamingSamples = { [weak self] samples in
    self?.streamingTranscriber?.addSamples(samples)
}

// Combine subscriptions — always [weak self]
deviceSubscription = audioDeviceManager.$selectedDevice
    .sink { [weak self] device in
        guard let self = self else { return }
        ...
    }
```

### NotificationCenter Observers — remove in deinit
```swift
deinit {
    if let observer = configChangeObserver {
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
    }
}
```

### Autoreleasepool for audio callbacks
```swift
autoreleasepool {
    onStreamingSamples?(samples)
}
```

## Code Organization

### File Headers — minimal
```swift
//
//  FileName.swift
//  Whisperer
//
//  One-line purpose statement
//
```

### MARK Sections
```swift
// MARK: - Public Methods
// MARK: - Recording
// MARK: - Audio Engine Observers
// MARK: - Device Selection
// MARK: - Cleanup for Graceful Shutdown
```

### Comment Style — WHY not WHAT
```swift
// GOOD: explains the decision
// Voice processing disabled — it causes ~500ms+ startup delay due to
// KeystrokeSuppressor initialization. This delay cuts off first words.

// GOOD: explains a workaround
// CRITICAL: Force audio unit creation by querying format BEFORE setting device
// The audio unit is only created when we access outputFormat(forBus:)
_ = inputNode.outputFormat(forBus: 0)

// BAD: restates the obvious
// Set state to idle
state = .idle
```

## Swift Idioms

### Guard for Preconditions
```swift
guard state == .idle else { return }
guard let bridge = whisperBridge else {
    errorMessage = "Model not loaded yet."
    return
}
guard !samples.isEmpty else { return "" }
```

### UserDefaults Pattern
```swift
@Published var muteOtherAudioDuringRecording: Bool = true {
    didSet {
        UserDefaults.standard.set(muteOtherAudioDuringRecording, forKey: "muteOtherAudioDuringRecording")
    }
}
// Load in init:
if UserDefaults.standard.object(forKey: "muteOtherAudioDuringRecording") != nil {
    muteOtherAudioDuringRecording = UserDefaults.standard.bool(forKey: "muteOtherAudioDuringRecording")
}
```

### withUnsafeBufferPointer for C interop
```swift
samples.withUnsafeBufferPointer { ptr -> Int32 in
    whisper_full(ctx, wparams, ptr.baseAddress, Int32(samples.count))
}
```

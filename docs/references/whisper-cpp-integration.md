# whisper.cpp Integration Guide

## Overview

WhisperBridge.swift wraps the vendored whisper.cpp C library (at `whisper.cpp/`, NOT a git submodule). The C library is statically linked via bridging header and uses Metal GPU acceleration.

**Bridging header**: `Whisperer-Bridging-Header.h` includes `ggml.h` and `whisper.h`.

## Context Lifecycle

whisper_context MUST be managed carefully — Metal GPU resources are tied to the creating thread.

```swift
// Initialization — creates Metal GPU resources
var cparams = whisper_context_default_params()
cparams.use_gpu = true
cparams.flash_attn = WhisperBridge.isAppleSilicon  // Only on ARM
ctx = whisper_init_from_file_with_params(modelPath.path, cparams)

// GPU fallback — if Metal fails, retry CPU-only
if ctx == nil {
    cparams.use_gpu = false
    cparams.flash_attn = false
    ctx = whisper_init_from_file_with_params(modelPath.path, cparams)
}

// Cleanup — whisper_free releases Metal resources
// Must be called, or memory leaks
deinit {
    whisper_free(ctx)
}
```

## Thread Safety

whisper.cpp is NOT thread-safe. WhisperBridge uses SafeLock to serialize access:

```swift
private let ctxLock: SafeLock  // 10s timeout on Apple Silicon, 60s on Intel

func transcribe(samples: [Float], ...) -> String {
    guard !isShuttingDown else { return "" }

    do {
        return try ctxLock.withLock(timeout: lockTimeout) { [weak self] in
            guard let self = self else { return "" }
            return self.performTranscription(samples: samples, ...)
        }
    } catch SafeLockError.timeout {
        Logger.error("Lock timeout - possible deadlock", subsystem: .transcription)
        return ""
    }
}
```

**Async variant** dispatches to a dedicated serial queue:
```swift
private let queue = DispatchQueue(label: "whisper.transcribe", qos: .userInteractive)

func transcribeAsync(samples:, completion:) {
    queue.async { [weak self] in
        guard let self = self else { return }
        let text = self.transcribe(samples: samples, ...)
        completion(text)
    }
}
```

## Audio Format Requirements

| Parameter | Value |
|-----------|-------|
| Sample rate | 16,000 Hz (WHISPER_SAMPLE_RATE) |
| Channels | 1 (mono) |
| Format | Float32 (-1.0 to 1.0) |

AudioRecorder handles conversion from system audio (typically 48kHz stereo) to this format using `AVAudioConverter`.

## Transcription Parameters

```swift
var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
wparams.print_progress = false
wparams.print_special = false
wparams.print_realtime = false
wparams.print_timestamps = false
wparams.single_segment = singleSegment   // true for streaming chunks, false for longer audio
wparams.no_timestamps = true
wparams.n_threads = WhisperBridge.optimalThreadCount  // P-cores only on Apple Silicon
wparams.suppress_nst = true
wparams.suppress_blank = true

// Speed: deterministic greedy, no temperature fallback ladder
wparams.temperature = 0.0
wparams.temperature_inc = 0.0      // Prevents up to 6 decode retries per chunk

// Explicit thresholds (pinned to prevent drift from future whisper.cpp default changes)
wparams.no_speech_thold = 0.6
wparams.logprob_thold = -1.0
wparams.entropy_thold = 2.4

// Context carrying
if let prompt = initialPrompt, !prompt.isEmpty {
    wparams.no_context = false
    // initial_prompt set via withCString to keep C string alive
}

// Language (nil = auto-detect)
wparams.language = language == .auto ? nil : languageCode
// When language is explicit, disable auto-detection
if language != .auto {
    wparams.detect_language = false
}
```

## Thread Count

On Apple Silicon, thread count targets performance cores only (excludes efficiency cores):

```swift
private static let optimalThreadCount: Int32 = {
    if isAppleSilicon {
        // Query P-core count via sysctl, reserve 2 for audio/UI
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return max(2, count - 2)
        }
        return Int32(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    } else {
        return Int32(min(ProcessInfo.processInfo.activeProcessorCount, 8))
    }
}()
```

**Why not all cores?** Efficiency cores create straggler effects (P-cores wait for E-cores). Reserving 2 P-cores prevents contention with audio capture, VAD, and UI rendering.

## C String Lifetime

C strings passed to whisper_full must remain alive during the call. Use `withCString`:

```swift
// CORRECT: C string alive during whisper_full
language.rawValue.withCString { langPtr in
    wparams.language = langPtr
    prompt.withCString { promptPtr in
        wparams.initial_prompt = promptPtr
        whisper_full(ctx, wparams, ptr.baseAddress, count)
    }
}

// WRONG: C string may be freed before whisper_full
wparams.language = language.rawValue  // Dangling pointer!
```

## Reading Results

```swift
let nSegments = whisper_full_n_segments(ctx)
var text = ""
for i in 0..<nSegments {
    if let segmentText = whisper_full_get_segment_text(ctx, i) {
        text += String(cString: segmentText)
    }
}
return text.trimmingCharacters(in: .whitespacesAndNewlines)
```

## Streaming Pipeline (StreamingTranscriber)

```
Audio samples → Buffer (audioBuffer)
                    ↓ when buffer >= 32,000 samples (2s)
                VAD check (hasSpeech — lightweight probability check)
                    ↓ if speech detected
                Prepend overlap (8,000 samples / 0.5s from previous chunk)
                    ↓
                WhisperBridge.transcribeAsync(singleSegment: true)
                    ↓
                Update lastProcessedSampleIndex
                    ↓
                Deduplicate overlapping words
                    ↓
                Append to fullTranscription
                    ↓
                Update live preview (main thread callback)

On stop (tail-only final pass):
    Compute tail = allRecordedSamples[lastProcessedSampleIndex...]
    If tail > 0.3s: VAD-filter tail → transcribe tail only → deduplicate → append
    Apply DictionaryManager corrections to combined streaming + tail result
```

**Key difference from full re-transcription**: Only unprocessed audio after the last chunk is transcribed on stop, not the entire recording. For a 30s recording where ~1-2s of tail remains, this reduces final-pass latency by 10-15x.

**Memory bounds**: Max 5 minutes = 4,800,000 samples (~19MB). Samples dropped after limit.

## Model Files

- **Location**: `~/Library/Application Support/Whisperer/`
- **Naming**: `ggml-{model-name}.bin` (e.g., `ggml-large-v3-turbo.bin`)
- **Download source**: Hugging Face via `ModelDownloader`
- **Sizes**: tiny (~75MB), base (~140MB), small (~460MB), medium (~1.5GB), large-v3-turbo (~1.5GB)

## Health Monitoring

WhisperBridge registers its queue for health monitoring:
```swift
QueueHealthMonitor.shared.monitor(queue: queue, name: "whisper.transcribe")
```

Context health check verifies the pointer is valid:
```swift
func isContextHealthy() -> Bool {
    try ctxLock.withLock(timeout: 1.0) {
        guard ctx != nil, isInitialized, !isShuttingDown else { return false }
        _ = whisper_full_n_segments(ctx!)  // Quick validity check
        return true
    }
}
```

## Shutdown Sequence

```swift
// 1. AppState.releaseWhisperResources()
streamingTranscriber = nil     // Stop streaming
sileroVAD = nil                // Free VAD context (smaller)
whisperBridge = nil            // Triggers WhisperBridge.deinit

// 2. WhisperBridge.prepareForShutdown()
isShuttingDown = true          // Prevent new transcriptions
queue.sync { }                 // Wait for in-flight operations

// 3. WhisperBridge.deinit
ctxLock.withLock(timeout: 2.0) {
    whisper_free(ctx)          // Free C resources
}
```

# Agent 9 — Whisper.cpp, GPU & ANE Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file in `Transcription/`, particularly `WhisperBridge.swift`, `StreamingTranscriber.swift`, `ModelPool.swift`, `VocabularyStore.swift`, `FluidAudioBridge.swift`
- Reference: `docs/references/whisper-cpp-integration.md`, `docs/references/language-routing.md`, `CLAUDE.md` Critical Rules

## Output
Write to `.claude/review-state/findings/agent-09.md`
Return: `Agent 9 (Whisper/GPU/ANE): X P0, Y P1, Z P2`

## Preamble

Run when `changed-files.txt` contains files from `Transcription/` or `Vendor/`. Read `docs/knowledge/transcription/rules.md` if it exists.

## Focus Checklist

### Preview Bridge CPU-Only Invariant

**P0**: `ModelPool.previewBridge` must always be initialized with `useGPU: false`. Pattern: any `WhisperBridge(modelURL:useGPU:true)` in `ModelPool` for the preview/detector bridge. GPU use by the preview bridge causes Metal contention with the main model and SwiftUI rendering, freezing HUD animations. CoreML encoder still uses ANE regardless of the `useGPU` flag (loaded unconditionally by whisper.cpp).

### Single Preview/Detector Context

**P0**: The preview bridge and language detection bridge must be THE SAME `WhisperBridge` instance. Pattern: any second `WhisperBridge` instance created for language detection (even if CPU-only). Two contexts waste ~77MB and risk double GPU/ANE contention. `WhisperBridge.detectLanguage()` uses the shared `previewBridge` context, serialized via `ctxLock`.

### ModelPool Warm-Check on Model Binary Only

**P0**: The warm-check in `ModelPool.routeTarget()` and `ModelRouter.resolve()` must compare `model` + `backend` fields ONLY — NOT the full `ModelProfile` including `language`. Same `.bin` file with different `language` values = same backend = warm hit. Loading a "different" model that is actually the same binary during recording causes a 1.6s GPU freeze. Pattern: warm check using `profile == existingProfile` (full equality with language) instead of `profile.model == existing.model && profile.backend == existing.backend`.

### mel-before-detect Order

**P1**: `whisper_lang_auto_detect()` MUST be preceded by `whisper_pcm_to_mel()`. Calling detection without mel preparation is undefined behavior. Pattern: any `whisper_lang_auto_detect(ctx, ...)` call not immediately following a `whisper_pcm_to_mel(ctx, ...)` call on the same context.

### C String Lifetime in whisper_full

**P1**: C strings (language codes, initial_prompt) passed to `wparams.language` and `wparams.initial_prompt` must remain alive for the entire duration of `whisper_full()`. Pattern: any `wparams.language = language.rawValue` without `withCString` wrapping — the `String` may be freed before `whisper_full` reads the pointer.

Required pattern:
```swift
language.rawValue.withCString { langPtr in
    wparams.language = langPtr
    prompt.withCString { promptPtr in
        wparams.initial_prompt = promptPtr
        whisper_full(ctx, wparams, samples, count)
    }
}
```

Flag: any `.language` or `.initial_prompt` assignment outside a `withCString` closure.

### Streaming Transcription Parameters

All streaming chunk transcriptions must use:
- `wparams.no_context = true` — prevents progressive quality degradation (**BUG-T05**: `no_context = false` in streaming mode)
- `wparams.single_segment = true` — for streaming chunks (false only for longer-form final pass)
- `wparams.temperature = 0.0`
- `wparams.temperature_inc = 0.0` — disables 6-retry fallback ladder
- `wparams.suppress_nst = true`
- `wparams.suppress_blank = true`
- `wparams.detect_language = false` — when language is explicit (prevents re-detection overhead)

Flag: any streaming call with `no_context = false`, `temperature_inc != 0.0`, or `detect_language = true` when language is already set.

### Empty Chunk Sample Index Advancement

**BUG-T09 (P1)**: `lastTranscribedSampleIndex` must NOT be advanced when the transcription result is empty. Pattern: `lastTranscribedSampleIndex = chunk.endSample` inside a branch that also handles empty or trimmed-to-blank results. Fix: only advance the index when `trimmedResult.isEmpty == false`. An empty advance causes the tail pass to miss that audio.

### TranscriptionBackend requestAbort()

**BUG-T08 (P1)**: Every class conforming to `TranscriptionBackend` protocol must implement a meaningful `requestAbort()`. A no-op `requestAbort()` is only safe for synchronous backends with no async inference path. Pattern: any `TranscriptionBackend` conformer that has `func requestAbort() {}` (empty body) when it runs CoreML/ANE inference. The last chunk is silently lost on stop.

### Tail-Only Final Pass

The final pass on `stop()` must transcribe ONLY unprocessed audio after `lastTranscribedSampleIndex` — not the full recording. Pattern: any `transcribeAsync(samples: allRecordedSamples, ...)` call in `stop()` without slicing from `lastTranscribedSampleIndex`. Re-transcribing the full recording adds 10-15x latency.

Minimum tail length threshold: `tailSamples.count > Int(0.3 * 16000)` (0.3s) — skip tail transcription if too short to contain meaningful speech.

### ANE Model Serialization

**BUG-C06 (P0)**: CoreML/ANE inference must be serialized. Pattern: any fire-and-forget `Task { model.finish() }` or `Task { eouManager.finish() }` that is not awaited before starting the next CoreML/ANE model (`fluidBridge.startSession()`, `fluidBridge.processAudio()`). ANE access is not multiplexed — concurrent CoreML models corrupt each other's output silently.

### Core ML Encoder Configuration

- whisper.cpp must be compiled with `WHISPER_USE_COREML=ON` and `WHISPER_COREML_ALLOW_FALLBACK=ON`
- All build configs must define `WHISPER_USE_COREML=1` and link `-lwhisper.coreml -framework CoreML`
- Flag: any build config change that removes these flags

### WhisperBridge Shutdown Race

**P1**: `WhisperBridge.recoverContext()` must have its own `guard !isShuttingDown else { return }` at the top of the method body, not just in its callers. Pattern: `recoverContext()` implementation without a shutdown guard. If `prepareForShutdown()` fires while `recoverContext()` is scheduled on the queue, the recovery must not re-initialize `ctx` post-shutdown (which would leak the new context).

### Non-Multilingual Model Bypass

`whisper_is_multilingual()` must be checked before routing — English-only models must bypass the language router entirely. Pattern: any language routing or detection path that doesn't check `whisper_is_multilingual(ctx)` before attempting detection. English-only models cannot route.

### Thread Count

Whisper thread count must use P-cores only on Apple Silicon:
```swift
sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0)
return max(2, count - 2)  // Reserve 2 for audio/UI
```
Intel cap: 8 threads max. Flag: any hardcoded thread count or use of `ProcessInfo.processInfo.activeProcessorCount` without P-core filtering.

### Flash Attention

`flash_attn = true` only on Apple Silicon (`isAppleSilicon`). Pattern: `cparams.flash_attn = true` without ARM architecture guard.

### GPU Fallback on Metal Failure

If `whisper_init_from_file_with_params` returns nil with `use_gpu = true`, must retry with `use_gpu = false`. Pattern: any new bridge initialization that doesn't implement this fallback. Metal initialization failures must not crash the app.

### whisper_free Paired with Init

Every `whisper_init_from_file_with_params(...)` call must have a corresponding `whisper_free(ctx)` in `deinit` or cleanup. Pattern: new `WhisperBridge` code paths that initialize `ctx` without guaranteed cleanup. Use the `ctxLock` with a 2-second timeout in `deinit`.

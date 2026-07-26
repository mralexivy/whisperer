# Agent 12 — LLM Post-Processing & Nemotron Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file in `Transcription/LLM/`, `Transcription/FluidAudio/NemotronBridge.swift`, `Transcription/FluidAudio/FluidAudioBridge.swift`
- Reference: `CLAUDE.md` Critical Rules, `ARCHITECTURE.md`

## Output
Write to `.claude/review-state/findings/agent-12.md`
Return: `Agent 12 (LLM & Nemotron): X P0, Y P1, Z P2`

## Preamble

Run when `changed-files.txt` contains files from `Transcription/LLM/` or `Transcription/FluidAudio/NemotronBridge.swift`. Read `docs/knowledge/transcription/rules.md` if it exists.

## Focus Checklist

### LLM Warmup Not During Active Recording

**P0**: `LLMPostProcessor.warmup()`, `primeAfterWarmup()`, or any `container.perform(...)` / MLX inference call must NOT be initiated while `AppState.shared.state == .recording`. Loading or priming a Metal/MLX model during recording causes GPU contention with Whisper and HUD animation freeze. Pattern: any `warmupTask = Task { ... container.perform(...) }` that does not begin with `guard AppState.shared.state == .idle else { ... }`.

### Metal JIT Priming with Representative Input

**BUG-G01 (P1)**: The Metal JIT priming dry run (`primeDryRun()`) must use representative input length (≥ 50 tokens). Short dummy inputs produce a JIT-compiled kernel that doesn't cover production token sequence lengths, causing a ~3400ms spike on the first real recording. Pattern: any `primeDryRun()` call that constructs an artificially short prompt (< 10 words or < 50 tokens).

Verify: `primeAfterWarmup()` is called AFTER warmup completes (`isWarmedUp == true`), not during.

### ChunkLLMCoordinator.reset() Race

**P1**: After `ChunkLLMCoordinator.reset()` cancels `pendingTask`, any in-flight continuation past `await corrector(chunk)` must call `Task.checkCancellation()` before appending to `correctedChunks`. Pattern:

```swift
let result = await corrector(chunk)
// MISSING: try Task.checkCancellation()
correctedChunks.append(result)  // Appends to cleared array after reset
```

Fix: every `await corrector(chunk)` return site must immediately check `Task.checkCancellation()` before any state mutation.

### Prompt Delimiter Stripping

**BUG-T07 (P1)**: All structural delimiter patterns from the system/user prompt template must be stripped from the model's output. Pattern: `[INPUT]`, `[/INPUT]`, `<think>`, `</think>`, `[TRANSCRIPTION]`, `[/TRANSCRIPTION]`, and any other template delimiters not stripped from `LLMPostProcessor.process()` output. Flag: delimiter strip regex compiled inside `process()` on every call — must be `private static let delimiterRegex = try! NSRegularExpression(...)` (compiled once).

### Qwen3 Think Tags

**BUG-L05 (P1)**: Any Qwen3 model inference must either:
1. Pass `additionalContext: ["enable_thinking": false]` to disable thinking, OR
2. Strip `<think>...</think>` from the output before returning

Pattern: any Qwen3 inference path without both thinking disabled AND a strip regex. The strip regex must be a `private static let` (compiled once, not per-call). Test: injecting `<think>internal thought</think>Final answer` — output must be `Final answer`.

### Token Budget for Non-Latin Scripts

**BUG-T11 (P1)**: Token budget calculation must account for script complexity:
- Latin/ASCII: ~4 chars/token → `maxTokens = inputCharCount / 4`
- Non-Latin (Hebrew, Arabic, CJK, Devanagari, Cyrillic): ~1-2 chars/token → `maxTokens = inputCharCount / 2` or `/ 1`

Pattern: any `maxTokens = charCount / 4` without script detection. Use `ScriptAnalyzer` to determine the dominant script, then scale accordingly. Flag: any fixed `/ 4` divisor applied to non-Latin text.

### Translation Output Length Guard

**BUG-L01 (P1)**: Output-length char-count guard must be disabled for translation mode (`targetLanguage != nil`) and for non-Latin transcription. Translation output length may differ significantly from input length. Pattern: `if output.count > input.count * 1.5 { return fallback }` applied without checking `targetLanguage == nil`.

### KV Cache Key Includes Instructions

**BUG-L02 (P1)**: KV cache must be keyed by the full system+user instructions string, not as a single optional tuple. When language mode or processing mode changes, the instructions string changes — a single `cachedPromptKV` entry would serve the wrong cache. Pattern: `cachedPromptKV: ([[MLXArray]], [[MLXArray]])?` (unkeyed). Fix: `cachedPromptKV: [String: ([[MLXArray]], [[MLXArray]])]` keyed by instructions hash.

### KV Cache Invalidation Race

**BUG-C02 (P1)**: KV cache nil→rebuild race. Pattern:
```swift
cachedPromptKV = nil        // other task reads nil, starts parallel build
cachedPromptKV = buildNew() // first builder assigns
// second builder assigns different object → cache incoherence
```
Fix: build into a local constant first, then assign atomically. Never nil the cache before the replacement is ready.

### KV Cache Type Consistency

**BUG-C05 (P1)**: KV cache quantization must match between warmup and inference passes. Pattern: `warmup()` using `kvBits: nil` (simple cache) while `process()` uses `kvBits: 8` (quantized). Incompatible cache types cause a runtime crash or silent cache miss. Verify both paths use identical `kvBits` setting.

### MTP Tensor Order

**BUG-T10 (P2)**: Multi-Token Prediction (MTP) tensor concatenation order must match the weight matrix shape. Pattern: `MLX.concatenated([a, b])` where the expected order per the weight matrix is `[b, a]`. Any MTP speculative path must have a comment documenting the expected input shape and the source of that shape specification.

### Memory Cache Management

**BUG-G04 (P1)**: `Memory.clearCache()` must NOT be called unconditionally after every inference. Unconditional clear defeats the MLX buffer pool and causes re-allocation on every inference call. Pattern: `Memory.clearCache()` not gated on `Memory.cacheMemory > Memory.cacheLimit`.

**BUG-G05 (P1)**: `Memory.cacheLimit` must be scaled to the model's parameter count:
- < 1B parameters: 128MB
- 1B–5B parameters: 256MB
- > 5B parameters: 512MB

Pattern: any fixed `cacheLimit` not scaled by model size.

### Chat Template Usage

**BUG-L04 (P2)**: System/user prompt construction must use `applyChatTemplate()` to validate the messages array format matches the model's expected format. Pattern: any prompt construction that concatenates strings directly without using the template API. Different chat models have different expected formats; direct string concatenation silently produces wrong format.

### NemotronBridge Actor Isolation

**P1**: `NemotronBridge` is declared as a Swift actor. Every call site must use `await`. Pattern: any call to `NemotronBridge` methods without `await`, or any cast that bypasses actor isolation.

### Nemotron Callback Thread Safety

**P1**: The streaming callback from `StreamingNemotronMultilingualAsrManager` may arrive on any thread (C++ callback thread). Writes to `previewAccumulatedText`, `lastPreviewedSampleIndex`, or any shared state must go through the same synchronization mechanism (SafeLock or actor) as the non-Nemotron preview path. Pattern: any Nemotron callback closure that writes to these properties without holding the appropriate lock.

### ANE Serialization (Nemotron + Whisper)

**BUG-C06 (P0)**: If both Nemotron (FluidAudio) and Whisper are using CoreML/ANE, their inference must be serialized. Pattern: any code path that starts a `FluidAudioBridge.processAudio()` call while `WhisperBridge` is mid-transcription with CoreML encoder. Verify that the routing logic prevents concurrent ANE usage by multiple backends.

### Task.checkCancellation() in Inference Loops

**P2**: Long-running inference loops must periodically check `Task.checkCancellation()`. Pattern: any `while !isAborted` inference loop that runs for multiple seconds without a cancellation check point. Missing checks delay cancellation until the loop completes.

### LLMPostProcessor @MainActor Inference

**P1**: `LLMPostProcessor` is marked `@MainActor`. Any direct `container.perform(...)` call runs on the main thread. This blocks the UI during inference. Pattern: `container.perform(...)` inside `@MainActor` without `Task.detached`. Must be: `Task.detached { await container.perform(...) }`.

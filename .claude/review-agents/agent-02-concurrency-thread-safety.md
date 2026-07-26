# Agent 2 — Concurrency & Thread Safety Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file
- Reference: `CLAUDE.md` Critical Rules, `AGENTS.md` Critical Rules, `ARCHITECTURE.md` §1 (SafeLock), §12 (stopAsync), Common Pitfalls

## Output
Write to `.claude/review-state/findings/agent-02.md`
Return: `Agent 2 (Concurrency & Thread Safety): X P0, Y P1, Z P2`

## Preamble

Read `docs/knowledge/concurrency/rules.md` if it exists. Check all `Check:` patterns against the diff first.

## Focus Checklist

### Swift Actors vs SafeLock

- **Hard fail (P0)**: Any Swift `actor` wrapping whisper.cpp or other blocking C code. Swift actors suspend on `await`, not block. Use `SafeLock.withLock(timeout:)`. Citation: `CLAUDE.md` "SafeLock (timeout-based NSLock) for whisper.cpp thread safety — not Swift actors"
- `@MainActor` isolation: only on `AppState`, `@MainActor`-annotated ViewModels, and UI-bound services. Never on `AudioRecorder`, `WhisperBridge`, `StreamingTranscriber`, `LanguageRouter`, `ModelPool`, `TextInjector`.

### Task Inheritance Bug

- **BUG-C01 (P1)**: `Task { }` inside an `@MainActor`-isolated class inherits the main actor. Any `Task { }` that performs GPU work (`container.perform`), CPU-heavy work (whisper.cpp), or disk I/O (model loading, safetensors) inside an `@MainActor` class must be `Task.detached { [weak self] in ... }`. Flag: `Task {` not followed by `detached` inside any class annotated `@MainActor` when the body contains `container.perform`, `whisper_full`, `loadPromptCache`, `Stream.gpu`, or `Memory.clearCache`.
- After any `await` inside a `Task.detached` that accesses `@MainActor`-isolated state, use `await MainActor.run { }` for that access.

### Invalidate-Rebuild-Replace Pattern

- **BUG-C02 (P0)**: "Invalidate → nil → rebuild" on a shared property where concurrent readers see `nil` mid-build. Pattern: `self.x = nil` then `self.x = buildNew()` on a property read concurrently. Fix: build into a local variable `let new = buildNew()`, then `self.x = new`. Flag any assignment `self.x = nil` immediately followed by async work that re-assigns `self.x`, without the value being re-checked in between.

### GPU State Lifecycle

- **BUG-C03 (P0)**: `Stream.gpu.synchronize()` or `Memory.clearCache()` called while inference is in flight — GPU UAF. Any `unloadModel()` or GPU cleanup function must drain in-flight work first: `while isProcessing { try? await Task.sleep(nanoseconds: 20_000_000) }` before any `Stream.gpu` call.
- **BUG-C04 (P1)**: `Stream.gpu.synchronize()` on `@MainActor` or any actor that drives UI — blocks the UI. Must be wrapped in `Task.detached { Stream.gpu.synchronize() }` and awaited.

### Audio Engine Recovery Races

- **BUG-A09 (P1)**: Multiple concurrent `recoverAudioEngine()` invocations from different event sources (silence detection, config change notification, device-alive listener). Every recovery entry point must begin with `guard !isRecovering else { return }`. `isRecovering` must be set to `true` atomically at entry and reset to `false` in ALL exit paths (success, cancellation, and every error branch).
- All `AVAudioEngine` operations (`installTap`, `removeTap`, `engine.start()`, `engine.stop()`) must be wrapped in `ObjCTry()` — these throw `NSException` which Swift `do/catch` cannot intercept.
- **BUG-A10 (P0)**: Recovery task accesses `engine.inputNode` while `stopRecording()` runs `cleanupEngineState()` — SIGSEGV use-after-free. Pattern: `stopRecording()` calls `cleanupEngineState()` without first cancelling `recoveryTask`. Fix: cancel `recoveryTask` before `cleanupEngineState()`. Inside the recovery task: check `Task.isCancelled` after every `await` suspension, and re-validate engine non-nil before accessing it.
- **BUG-A12 (P0)**: `AVAudioEngine` must be owned exclusively by `AudioEngineLifecycle` actor. Any code path outside the actor that holds a reference to `engine`, accesses `inputNode`, or calls `installTap`/`removeTap` breaks actor isolation.

### ANE Contention

- **BUG-C06 (P0)**: Fire-and-forget stop/finish of one CoreML model before another CoreML model starts — ANE contention corrupts encoder output (BUG: Cyrillic tokens for English speech). Pattern: `Task { eouManager.finish() }` or `Task { model.reset() }` (not awaited) before any `startSession()`, `process()`, or `transcribeAsync()` call on another CoreML/ANE model. ANY ANE model stop must be awaited before another ANE model start.

### StreamingTranscriber Unprotected State (P0 for new properties)

`StreamingTranscriber` is a plain class with no actor isolation. The following properties are accessed from multiple threads (VAD task, whisper completion callback, preview task) without locks. **Any new mutable property added to `StreamingTranscriber` that is not explicitly guarded by one of the three existing SafeLocks (`processingLock`, `allSamplesLock`, `transcriptionLock`) is P0.**

Check for new `var` declarations in `StreamingTranscriber` that are:
- Accessed in `Task.detached` bodies
- Accessed in `WhisperBridge.transcribeAsync` completion callbacks (which run on the whisper serial queue)
- Accessed in `runLivePreviewPass()` or any preview timer callback

If found without a lock, flag P0.

### ModelPool.warmBackends

`ModelPool.warmBackends: [ModelProfile: TranscriptionBackend]` must never be mutated from multiple concurrent Tasks without serialization. Currently only `inFlightLoads` is guarded by `inFlightLock`; `warmBackends` itself has no synchronization. **Any new code path that reads or writes `warmBackends` from a `Task`, `Task.detached`, or background queue must go through a lock. Flag P0 if a new write path is added without one.**

### SafeLock in Async Context

- **P1**: `SafeLock.withLock(timeout:)` uses a busy-spin (`Thread.sleep`). Calling it from inside a Swift `Task` (not a dedicated `DispatchQueue` serial queue) blocks a cooperative thread pool thread for the full timeout. Flag any `safelock.withLock` inside an `async` function that is not called from a dedicated `DispatchQueue`. Note the busy-spin risk in a comment; prefer `withLockAsync` where available.
- `withLock` with timeout > 10s called from a time-sensitive path (audio callback, UI update): flag P1.

### Sendable Conformance

- Any new `@unchecked Sendable` requires a justification comment explaining why the type is safe to cross actor boundaries despite compiler warnings.
- Flag `@unchecked Sendable` without comment.

### Task Cancellation

- `try Task.checkCancellation()` in long-running loops inside `Task.detached`
- `for await` on `AsyncStream` terminates on producer cancel — verify producers call `continuation.finish()` on stop
- Actor reentrancy: re-check state invariants after every `await` inside an actor method

### Audio Render Thread

- Zero allocations, zero locks, zero ObjC messaging, zero Swift `async` in the `AVAudioEngine` tap callback (the `installTap` block)
- `autoreleasepool { }` around any ObjC-touching code in the tap callback
- Only lock-free ring buffers or atomics permitted in the tap hot path

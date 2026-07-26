# Agent 1 — Memory & Lifecycle Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file listed in `changed-files.txt`
- Reference: `CLAUDE.md` Critical Rules, `AGENTS.md` Critical Rules, `ARCHITECTURE.md` Component Ownership

## Output
Write findings to `.claude/review-state/findings/agent-01.md`
Return one line: `Agent 1 (Memory & Lifecycle): X P0, Y P1, Z P2`

## Preamble — Load Before Reviewing

Read `docs/knowledge/memory/rules.md` if it exists. For each `Check:` pattern, grep the diff for matches and flag them first before running the checklist below.

## Focus Checklist

### Retain Cycles & Weak Self

- `[weak self]` mandatory in every `Task.detached { }`, stored callbacks (`onStreamingSamples`, `onTranscription`, `onAmplitudeUpdate`, `onDeviceRecovery`), Combine `.sink { }`, and `NotificationCenter` closure observers
- Block-form `NotificationCenter` observers: `addObserver(forName:object:queue:using:)` must be removed in `deinit` or `viewDidDisappear`. Store the return token.
- `NSStatusItem`, `NSMenuItem` targets: verify no strong reference cycle through the target-action pattern
- `NemotronBridge` partial callback: if the outer `[weak self]` closure contains an inner `DispatchQueue.main.async { ... }`, verify the inner block also captures `self` weakly or uses `guard let self` before the dispatch. Inner strong capture on a non-optional `self` after `guard let self` is a latent retain cycle (BUG: strong capture in inner dispatch).

### Model & Context Lifecycle

- Every `whisper_init_from_file_with_params` paired with `whisper_free` in `deinit` — including the cold-load path and `recoverContext()`. If recovery creates a new context, the old one must be freed first.
- `SileroVAD` context cleanup: `deinit` must call the C-level destroy function.
- **BUG-M01**: Wrapper struct owning `MLModel` refs that survives after `cleanup()` — calling a cleanup method on a struct's properties does NOT deallocate the struct. The struct itself must be set to `nil` (declared as `var`, not `let`) to release its ARC references. Flag: any `prepareForShutdown()` or `deinit` that calls `struct.cleanup()` but does not nil the struct variable.
- **BUG-M02**: Async model with pending callbacks released without draining — `obj = nil` when `obj` has outstanding async callbacks is a lifecycle bug. Pattern: `eouManager = nil` without prior `await eouManager.reset()`. Must await/drain before nil.
- **BUG-M03**: In-flight load task not cancelled before `releaseCurrentBridge()` — the task completes after release and re-assigns the property, resurrecting a released bridge. Pattern: `releaseCurrentBridge()` or `releaseCurrentBackend()` without first cancelling `whisperLoadTask`, `parakeetLoadTask`, `speechAnalyzerLoadTask`, `nemotronLoadTask`, or any similar load task. ALL active load tasks must be cancelled at the top of every release/switch function.
- **BUG-C08**: Old bridge not released before new one loads — peak memory = old + new. Pattern: `preloadModel()` or `selectBackend()` without calling `releaseCurrentBridge()` first. Cancel tasks, release, then load.
- **BUG-C09**: `CtcModels.downloadAndLoad()` called per vocabulary configuration change — reloads ~100MB MLModel every time. Must use a static cache (`cachedCtcModels`) reused across calls. `releaseCachedModels()` only on shutdown.

### Carbon Hotkey Teardown

- `RegisterEventHotKey` must be paired with `UnregisterEventHotKey` in teardown
- `RemoveEventHandler` must be called for the registered handler
- `Unmanaged.passUnretained(self)` pointer must remain valid while the handler is registered — verify `GlobalKeyListener` stays alive until teardown
- Flag if teardown only calls `UnregisterEventHotKey` but omits `RemoveEventHandler` (memory leak + potential crash on stale callbacks)

### Recording Cap

- 5-minute cap (4,800,000 samples at 16kHz mono Float32 ≈ 19MB) must remain intact in `AudioRecorder`. Flag any change to `maxRecordingSamples` or the cap enforcement block.

### ModelPool Lifecycle

- `releaseAll()` must nil all warm backends and call `whisper_free` on their contexts
- `evictStandby()` must not evict the fallback backend — only standby (non-fallback) backends
- Preload tasks in `preloadStandby()` must be stored and cancellable; verify they are cancelled in `releaseAll()`

### ChunkLLMCoordinator / LLMPostProcessor

- `ChunkLLMCoordinator.pendingTask` chain: when `reset()` is called and a task is already past `guard let self` but inside `await corrector()`, the task will complete and call `self.correctedChunks.append()` on the reset-cleared array. Verify `try Task.checkCancellation()` is called AFTER `await corrector()` returns, before appending the result. Flag if missing (P1).
- `LLMPostProcessor.unloadModel()`: must be `async` and drain `isProcessing` before `Stream.gpu.synchronize()` — synchronous GPU fence while inference in flight = GPU UAF (BUG-C03). Pattern: `unloadModel()` that is not `async` or does not contain `while isProcessing { await Task.sleep }`.

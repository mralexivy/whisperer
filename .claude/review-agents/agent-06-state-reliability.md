# Agent 6 — State & Reliability Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file
- Reference: `CLAUDE.md` Critical Rules, `ARCHITECTURE.md` §8 (Tail-Only Final Pass), §11 (stopRecording timeout), §12 (stopAsync), Common Pitfalls §7–12

## Output
Write to `.claude/review-state/findings/agent-06.md`
Return: `Agent 6 (State & Reliability): X P0, Y P1, Z P2`

## Preamble

Read `docs/knowledge/state/rules.md` if it exists. Check all `Check:` patterns first.

## Focus Checklist

### stopAsync() Invariant

- **P0**: Any call to `transcriber.stop()` or `streamingTranscriber?.stop()` that is NOT `stopAsync()`. The synchronous `stop()` reads `lastProcessedSampleIndex` before in-flight chunk completion handlers update it, causing overlapping tail transcription and duplicated text output. Pattern: grep for `transcriber\.stop\(\)` and `streamingTranscriber\?\.stop\(\)` — any match without `Async` is P0.
- This applies to ALL recording stop paths: `stopRecording()`, `stopInAppRecording()`, and any new recording stop function.

### Counter Thresholds

- **BUG-A08 (P1)**: `==` comparison on a monotonically increasing counter — if a guard prevents the trigger while the counter advances past the threshold, the `==` condition is permanently missed. Pattern: `if consecutiveSilentCallbacks == threshold`. Must be `>= threshold`. Check ALL counter-based thresholds in audio recovery, silence detection, and chunk processing loops.

### Recovery Mutual Exclusion

- **BUG-A09 (P1)**: Audio engine recovery called concurrently from multiple event sources (silence detection, config change notification, device-alive listener). Every recovery entry point MUST begin with `guard !isRecovering else { return }`. `isRecovering` must be set to `true` atomically at entry and reset to `false` in ALL exit paths including every error branch and the cancellation path.
- Recovery attempt counter must only be reset when non-silent audio is confirmed after recovery (RMS > threshold for at least one callback) — **BUG-A14 (P1)**: resetting on any callback, even silent ones, prevents the recovery loop from completing.

### Engine Teardown Safety

- **BUG-A10 (P0)**: `stopRecording()` must cancel `recoveryTask` before calling `cleanupEngineState()`. Pattern: `cleanupEngineState()` or `engine?.stop()` called without `recoveryTask?.cancel()` first. The recovery task may be accessing `engine.inputNode` concurrently.
- After `audioRecorder?.stopRecording()` returns, the main stop Task must check `guard case .stopping = state` — if the safety timeout already fired (`state == .idle`), the task must bail out without proceeding to transcription.

### Queue Buildup Prevention

- **BUG-A11 (P1)**: Serial `lifecycleQueue` (or any serial `DispatchQueue`) that receives blocking configure tasks with no timeout and no bypass. Pattern: `lifecycleQueue.async { buildGraph() }` where `buildGraph` can block indefinitely (e.g., `inputNode` blocking in CoreAudio). Fix: each new `configure()` call must create a fresh queue, replacing the old one. Add a 15-second timeout watchdog for `recorderState` stuck in `.starting`.

### HUD Escape Hatches

- **BUG-U08 (P1)**: `isProcessing` flag stuck `true` forever after Whisper encode failure. Pattern: any `isProcessing` or `isTranscribingChunk` flag without an absolute maximum wait time. The stop watchdog must have a 20-second absolute timeout that calls `forceIdleFromWatchdog()` even if `isProcessing` is still true. Verify this timeout exists and is reachable.
- Two consecutive Whisper encode failures (e.g., Metal error -6) must trigger `recoverContext()` — verify `consecutiveFailures >= 2` check exists and calls recovery.

### WhisperBridge Recovery Context Safety

- **New bug (P1)**: `WhisperBridge.recoverContext()` is scheduled on the background queue via `queue.async { bridge.recoverContext() }`. The recovery method re-initializes `ctx` under `ctxLock`. If `prepareForShutdown()` has already set `isShuttingDown = true` and drained the queue (queue.sync {}), the recovery block should not run. BUT: `isShuttingDown` is checked in `transcribe()`, not inside `recoverContext()` itself. Verify that `recoverContext()` has its own `guard !isShuttingDown` at entry. If missing: flag P1 — the recovery may re-initialize `ctx` after shutdown, leaking the new context.

### CoreData Concurrency

- `HistoryManager` and `DictionaryManager` CoreData writes must use `performBackgroundTask` — never write on the main thread. Flag: any `viewContext.save()` or `backgroundContext.save()` not inside `performBackgroundTask`.
- `UserDefaults` complex values: must use `Codable` — not raw `[String: Any]` dictionaries.

### 5-Second Safety Timeout

- `stopRecording()` 5-second safety Task: if `AVAudioEngine.stop()` hangs (bad audio device), the Task must force `state = .idle` and clear `streamingTranscriber` and `liveTranscription`. Verify: (1) the Task is started in parallel with `stopRecording()`, (2) it checks `state == .stopping` before forcing idle, (3) the main stop path checks for timeout after `audioRecorder?.stopRecording()` returns.

### Graceful Degradation

- VAD is optional — code must always check `vad != nil` before calling VAD methods. Flag any unconditional VAD call.
- Missing model: surfaced as user-facing `errorMessage` on `AppState`, not a crash.
- Corrupted state must trigger a reset path, not a `fatalError` or `preconditionFailure`.

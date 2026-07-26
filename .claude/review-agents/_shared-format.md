# Whisperer Review Agent — Shared Finding Format

Every agent uses this schema exactly. No free-form findings outside these blocks.

## Finding Schema

```
- file:line — [P0|P1|P2] <one-line title>
  Rule: <CLAUDE.md / AGENTS.md / ARCHITECTURE.md / whisper-cpp-integration.md / docs/knowledge/<domain>/rules.md citation>
  Current: <problematic code snippet, ≤5 lines>
  Fix: <exact change or concrete instruction>
  Verify: <grep, build command, or smoke test>
  Learn: <domain — one of: audio, transcription, concurrency, memory, ui, app-store, state>
```

## Severity Definitions

All definitions are traceable to real shipped bugs documented in git history.

### P0 — Block (never skip, never defer)
- Data races on shared mutable state (BUG-C02: KV cache nil mid-build, BUG-A10: recovery task vs engine teardown SIGSEGV)
- Banned App Store APIs: `CGEventTap`, `IOHIDManager`, global `keyDown`/`keyUp` (BUG-AS01)
- `useGPU: true` on preview/detector bridge — Metal contention with main model and SwiftUI
- ModelPool warm-check comparing full `ModelProfile` instead of `model + backend` only — 1.6s GPU freeze on same .bin with different language
- AX call without `AXUIElementSetMessagingTimeout` 100ms on both app element and focused element
- `transcriber.stop()` instead of `stopAsync()` — race causes text duplication
- `makeKey()` or `makeKeyAndOrderFront()` on `OverlayPanel` — steals focus from target app
- Plaintext credentials anywhere
- `previewAccumulatedText` shrinking mid-recording — breaks `SmoothTextUpdater.hasPrefix` invariant
- LLM warmup (`container.perform`, `primeDryRun`) running while `AppState.state == .recording` — GPU contention with Whisper Metal (BUG-C03: UAF on GPU unload during inference)
- AX direct-write (`AXUIElementSetAttributeValue(kAXSelectedTextAttribute)`) as sole injection path without clipboard fallback — silently fails in Chrome/Electron (BUG-T01)
- Concurrent CoreML/ANE model inference without awaiting prior model's stop (BUG-C06: Cyrillic tokens from ANE contention)

### P1 — Fix
- Missing `[weak self]` in `Task.detached`, stored callbacks (`onStreamingSamples`, `onTranscription`, `onAmplitudeUpdate`), Combine `.sink`, `NotificationCenter` closure observers
- `Task {}` inside `@MainActor` class for GPU/CPU-heavy work — inherits main actor (BUG-C01: LLM load stalled UI)
- Any new mutable property in `StreamingTranscriber` not behind one of the three existing SafeLocks (`processingLock`, `allSamplesLock`, `transcriptionLock`)
- `ModelPool.warmBackends` dict mutations from multiple Tasks without serialization
- New `TranscriptionBackend` with no-op `requestAbort()` when running CoreML/ANE inference — last chunk lost on stop (BUG-T08)
- Audio/energy check missing before `transcribeAsync()` or `FluidAudioBridge.process()` — hallucinations on silence (BUG-A02, BUG-A13)
- `==` instead of `>=` on monotonically increasing threshold counter — trigger permanently misses (BUG-A08: silence recovery disabled)
- No `isRecovering` guard on audio engine recovery entry points — SIGABRT from concurrent recovery (BUG-A09)
- Recovery task not cancelled before `cleanupEngineState()` — SIGSEGV (BUG-A10)
- `changeCount` guard missing from clipboard restore — overwrites user's clipboard (BUG-T04)
- CoreAudio HAL call on `@MainActor` — blocks UI 50–200ms (BUG-S04)
- `whisper_full()` tail transcription on `@MainActor` — must use `withCheckedContinuation` on background (BUG-S05)
- `SafeLock.withLock` inside Swift `async` function without using `withLockAsync` — busy-spin blocks cooperative thread pool
- `ObjCTry()` missing on `installTap`, `removeTap`, `engine.start()`, `engine.stop()` — `NSException` uncatchable in Swift (BUG-A09)
- In-flight load task not cancelled before `releaseCurrentBridge()` — resurrects released bridge (BUG-M03)

### P2 — Fix if low-risk
- Magic numbers — use existing constants from `AudioRecorder`, `StreamingTranscriber`, `LanguageRouter`
- Wrong logging subsystem (e.g., `.audio` subsystem in a transcription file)
- Missing `guard !isShuttingDown` at entry of any method that touches whisper.cpp context
- Missing `try Task.checkCancellation()` in long async loops
- Token budget using `charCount / 4` without script detection — truncates Hebrew/Arabic/CJK output (BUG-T11)
- `Memory.clearCache()` called unconditionally after every LLM inference — defeats MLX buffer pool (BUG-G04)
- Layout invalidation triggered per word animation step — debounce ≥ 100ms (BUG-S07)
- `NSFont`/`NSParagraphStyle` created inside `updateNSView()` per render — cache in coordinator (BUG-S08)

## Output File Format

Write findings to `.claude/review-state/findings/agent-NN.md` using this structure:

```markdown
# Agent N (Name) — <pass number>

## Findings

<findings in schema format, P0 first, then P1, then P2>

## Recommendations Skipped

<anything below P2 threshold, with brief justification>

## Knowledge Rules Applied

<list any docs/knowledge/<domain>/rules.md rules that matched this diff>
```

Return exactly **one line** to the orchestrator:
```
Agent N (Name): X P0, Y P1, Z P2
```

## Scope Discipline

- Read the **full source** of each changed file, not just the diff hunk. Context gaps from hunk-only reading produce false negatives.
- Do NOT re-verify codegraph or grep results with a second read — trust the source.
- In pass 2+: check `pass_number` in `context.json`. Do not re-litigate decisions already committed. Focus on issues introduced by the previous pass.
- Generic macOS advice suppressed when it conflicts with project rules. Project rules in `CLAUDE.md` + `AGENTS.md` always win.

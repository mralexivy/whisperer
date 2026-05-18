# Final Review — Whisperer PR Review & Verification

Eleven specialist agents in parallel, anchored to Whisperer's rules (`CLAUDE.md`, `AGENTS.md`, `ARCHITECTURE.md`, `DESIGN.md`, `docs/references/whisper-cpp-integration.md`, `docs/references/language-routing.md`, `docs/exec-plans/app-store-submission.md`). Optimized for **UX latency** and **Swift threading correctness** — generic macOS advice is suppressed when it conflicts with project rules.

**Constraint priority (every agent):** Correctness → UX latency → Throughput → Developer velocity.

---

## Step 0 — Pre-flight (orchestrator runs inline, before any agent)

Gather ground-truth artifacts so agents review **evidence**, not just code. Output one structured block reused verbatim in every agent prompt.

```bash
BASE=$(git merge-base HEAD main)
echo "## BRANCH BASE"; echo "$BASE"

echo "## PASS DETECTION"
git log --oneline "$BASE"..HEAD | grep -c "Co-Authored-By: Claude" || true
# 0 → Review Pass #1. 1+ → follow-up pass; agents must read commit messages
# before recommending reversals.

echo "## DIFF SCOPE"
git diff --name-only "$BASE"..HEAD \
  | awk -F/ '{print $1"/"$2}' | sort -u
# Buckets: Audio/, Transcription/, TextInjection/, UI/, KeyListener/,
# Permissions/, Store/, Licensing/, History/, Dictionary/, Core/, whisper.cpp/

echo "## RECENT STUCK DUMPS (post-base)"
find ~/Library/Logs/Whisperer/stuck-dumps -type f -newer \
  <(git log -1 --format=%cI "$BASE" | xargs -I{} date -j -f "%Y-%m-%dT%H:%M:%S%z" {} +%Y%m%d%H%M.%S | xargs -I{} touch -t {} /tmp/__base_ts) \
  2>/dev/null | head -5

echo "## LOG TAIL FINDINGS"
tail -n 500 ~/Library/Logs/Whisperer/whisperer.log 2>/dev/null \
  | grep -iE "lock timeout|Metal|audio engine retry|Stuck state dump|kAudioUnitErr|-10877" \
  | tail -20
```

**Diff-scope gating:** skip an agent whose bucket has zero changed lines (pure UI change does not need the whisper.cpp/GPU agent; pure Store/IAP change does not need the audio agent).

**Follow-up pass discipline:** if pass detection ≥1, every agent prompt must include: *"Read commit messages on this branch before recommending reversals. Focus on issues introduced by the previous pass, not re-litigating decisions already made."*

---

## Step 1 — Eleven specialists in one parallel batch

Launch all selected agents in a **single message with multiple Task tool calls**. Each prompt opens with the Pre-flight block plus the **Whisperer Rules** preamble (lift verbatim from `CLAUDE.md` "Critical Rules" + `AGENTS.md` "Critical Rules"). Required output schema per finding:

```
- file:line — [P0|P1|P2] <one-line title>
  Rule violated: <CLAUDE.md / AGENTS.md / ARCHITECTURE.md citation>
  Fix: <concrete change>
  Verify: <command or smoke step>
```

### Agent 1 — Memory & Lifecycle

- `[weak self]` mandatory in `Task.detached { }`, stored callbacks (`onStreamingSamples`, `onTranscription`, `onAmplitudeUpdate`), Combine `.sink`, `NotificationCenter` closure observers. Block-form observers must be removed in `deinit`.
- `autoreleasepool` around audio callbacks (`AGENTS.md`).
- `NSPanel`/`NSWindow` retention via `WindowController`; verify `OverlayPanel` lifecycle.
- `NSStatusItem` strong-stored; `NSMenuItem` target avoiding retain cycles.
- Carbon hotkey: `Unmanaged.passUnretained(self)` pointer must remain valid; `UnregisterEventHotKey` + `RemoveEventHandler` in teardown (`ARCHITECTURE.md` §2).
- ModelPool contexts: every `whisper_init_*` paired with `whisper_free` in `deinit`; SileroVAD context cleanup.
- 5-min recording cap intact (4,800,000 samples ≈ 19MB).

### Agent 2 — Concurrency & Thread Safety (Whisperer-specific)

- **Hard fail:** any Swift `actor` wrapping whisper.cpp / blocking C code. Use `SafeLock.withLock(timeout:)` (`CLAUDE.md`).
- `@MainActor` only on `AppState`, ViewModels, UI-bound services — never on data/audio/transcription services.
- No `DispatchQueue.global()` for AX calls (multi-second contention; `AGENTS.md`).
- No `DispatchQueue.main.sync` from main thread.
- Audio render thread: zero allocations, zero locks, zero ObjC messaging, zero Swift `async`. Only lock-free ring buffers / atomics.
- `Task` cancellation: `try Task.checkCancellation()` in long loops; `for await` on `AsyncStream` terminates on producer cancel.
- Actor reentrancy: re-check invariants after every `await`.
- `Sendable` conformance audited; any new `@unchecked Sendable` requires a justification comment.

### Agent 3 — Architecture & Dependency Direction

- UI → AppState → Services. Services never import `SwiftUI`/`AppKit`. Services never reference `AppState`; callbacks only (`onStreamingSamples`, `onTranscription`).
- Domain types stay framework-free.
- Errors as typed enums with `LocalizedError` (`AGENTS.md`); no `String`-based errors.
- `fatalError` / `preconditionFailure` only for programmer errors, never reachable from user input or external data.
- Flags premature protocols (single conformer, no test mock) — codebase has no unit tests, so protocols-for-testability is not a valid justification.

### Agent 4 — Codebase Consistency & DRY

- Naming patterns from `AGENTS.md` (Services / Managers / Views / Windows / Errors / Routing).
- Reuse existing helpers before adding: `ModelPool.previewBridge`, `WhispererColors`/`MBColors`/`OnboardingColors`, `Logger`, `SafeLock`, `HistoryManager`, `ScriptAnalyzer`, `AudioDeviceManager.shared`.
- File placement aligned with `Whisperer/` folder layout (Audio/, Transcription/, TextInjection/, etc.).
- Comment-WHY-not-WHAT (`AGENTS.md`).
- No magic numbers — use the existing constants on `AudioRecorder`, `StreamingTranscriber`, `LanguageRouter`.

### Agent 5 — macOS Platform & Performance

- `OverlayPanel` uses `.orderFront(nil)`, **never** `.makeKey*` (must not steal focus; `ARCHITECTURE.md` §6).
- Every AX call preceded by `AXUIElementSetMessagingTimeout` 100ms (app element + focused element).
- `state = .idle` set **before** `textInjector.insertText(...)` so HUD dismissal runs concurrent with injection.
- Thread count: P-cores only via `sysctlbyname("hw.perflevel0.logicalcpu")` minus 2 reserved.
- `os_signpost` / `OSSignposter` on startup phases, transcription path, text injection.
- SwiftUI: no unnecessary `AnyView`; `@ObservedObject` granularity correct; `.id(recordingSessionID)` on `LiveTranscriptionCard`.
- Avoid `DispatchQueue.global()` without explicit QoS.

### Agent 6 — State & Reliability

- `await transcriber.stopAsync()` everywhere — never `transcriber.stop()` (race causes text duplication; `CLAUDE.md`).
- AudioRecorder one-shot retry with full engine teardown (`cleanupEngineState()`), default-device reset, 200ms wait, retry once.
- `stopRecording()` 5-second safety Task that forces `.idle` if `AVAudioEngine.stop()` hangs; main stop path checks `guard case .stopping = state` after the engine call (`ARCHITECTURE.md` §11).
- `startRecordingWatchdog()` present; `StuckStateDumper.dump(reason:)` reachable.
- Persistence: CoreData writes via `performBackgroundTask`; UserDefaults `Codable` for complex values; no main-thread file writes that could block UI.
- Graceful degradation: VAD optional (`vad != nil`), missing models surfaced as user-facing error, corrupted state triggers reset path not crash.

### Agent 7 — Security, Privacy & Logging

- Hardened runtime on.
- **Zero `print()`** in `Whisperer/` (CI grep below).
- `Logger.{debug,info,warning,error}` with correct subsystem (`.app`, `.audio`, `.transcription`, `.ui`, `.keyListener`, `.textInjection`, `.permissions`, `.model`).
- Sensitive data (user content, transcribed text, file paths) only at `.debug` with `%{private}@`.
- `os_signpost` on transcription, model load, text injection paths.
- Entitlements: every entry in `whisperer.entitlements` / `whisperer-nosandbox.entitlements` justified by code usage; no `com.apple.security.network.server`.
- No plaintext credentials anywhere; receipt validation via `ReceiptValidator` only in Release.

### Agent 8 — Audio Pipeline & Real-Time

- 16kHz mono Float32 via `AVAudioConverter` — flag any deviation.
- `AVAudioEngineConfigurationChange`: 1.5s startup grace observed (`ARCHITECTURE.md` Common Pitfalls §3); changes during AudioMuter operation ignored.
- AudioMuter restores prior volume on stop; no feedback loop on calls.
- Audio tap callback (`installTap`): no `Task`, no locks, no allocations, `autoreleasepool` around the `onStreamingSamples` call.
- 5-minute cap enforced; samples dropped past 4,800,000.
- Device hot-swap: `AudioDeviceManager` recovery path covered; selected-device unavailable falls back to default with warning log.
- VAD/SileroVAD: `useGPU: false` (CPU only — Metal contention rule). `hasSpeech()` probability used before chunk dispatch.
- Reads `Audio/AudioRecorder.swift` end-to-end on any diff.

### Agent 9 — whisper.cpp & GPU/ANE

Anchor every finding to `docs/references/whisper-cpp-integration.md` or `docs/references/language-routing.md`.

- `WhisperBridge.transcribe()` calls guarded by `ctxLock.withLock(timeout: lockTimeout)` (10s Apple Silicon, 60s Intel).
- Mel-then-detect order: `whisper_pcm_to_mel` **before** `whisper_lang_auto_detect`.
- `withCString` lifetime around `wparams.language`, `wparams.initial_prompt` — no dangling pointers.
- Streaming chunks: `single_segment = true`, `no_timestamps = true`, `temperature = 0.0`, `temperature_inc = 0.0` (no fallback ladder; pinned `no_speech_thold/logprob_thold/entropy_thold`).
- Fixed language → `detect_language = false`.
- **P0:** `ModelPool` warm-check compares `model + backend`, **never** the full `ModelProfile` (which includes `language`). Same `.bin` with different language must hit the warm path — loading a duplicate model freezes GPU for 1.6s (`CLAUDE.md`).
- **P0:** Preview bridge stays `useGPU: false`. CoreML encoder still loads unconditionally; this is correct.
- **P0:** Never separate contexts for preview vs detection — `ModelPool.previewBridge` serves both via `ctxLock`.
- `whisper_full_lang_id()` treated as weak evidence only (decoder state, not classifier).
- Tail-only final pass on stop; thread count from `optimalThreadCount` (P-cores − 2).
- Core ML: `WHISPER_USE_COREML=1` defined in all three configs; `.mlmodelc` next to `.bin` for ANE; silent Metal fallback otherwise.

### Agent 10 — HUD/UX Latency

User-visible budget is the spec. Receives the Pre-flight stuck-dump list — any dump post-`BASE` is treated as a **P0** regression introduced by this branch.

- `state = .idle` **before** `textInjector.insertText` (HUD dismissal concurrent with injection).
- `OverlayPanel.adjustFrameForContent` grows upward for bottom positions, downward for top.
- `SmoothTextUpdater.hasPrefix` invariant: preview text monotonic / append-only. Any code path that shrinks `previewAccumulatedText` mid-recording is a P0.
- RTL path: `TranscriptionTextView` (NSTextField via NSViewRepresentable). Forbid SwiftUI `Text` for transcription rendering — six approaches were proven broken (`DESIGN.md`, `ARCHITECTURE.md`).
- `.id(recordingSessionID)` resets `LiveTranscriptionCard` between recordings.
- Preview gated on `routeDecision != nil` or 5s timeout.
- `startRecordingWatchdog()` registered for every recording; `StuckStateDumper` reachable.
- Word-by-word animation skipped when `isRTL`.
- Audio cues fire on start/stop; `SoundPlayer` not blocking.

If a recent stuck dump is attached, agent must name which two of {`AppState.state`, `AudioRecorder.recorderState`, `audioEngine.isRunning`} disagreed and the most likely line responsible.

### Agent 11 — App Store Binary Auditor

Runs the **AppStore config** build and inspects the binary directly. Maps strictly to `docs/exec-plans/app-store-submission.md`.

```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer \
  -configuration AppStore -destination "platform=macOS" \
  ARCHS=arm64 CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements \
  ENABLE_APP_SANDBOX=YES 2>&1 | tee tmp/build-appstore.log

APP=$(find build -name whisperer.app -path "*AppStore*" | head -1)
/usr/bin/strings "$APP/Contents/MacOS/whisperer" | grep -iE \
  "AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive"
# Required: zero matches
```

- Every AX / `CGEvent.post` reference wrapped in `#if !APP_STORE`.
- `whisperer.entitlements` keys justified by code; no `com.apple.security.network.server`.
- `Info.plist`: `ITSAppUsesNonExemptEncryption = NO`, no `NSAppleEventsUsageDescription`, no `NSServices`.
- Directive permission language banned (Guideline 5.1.1(iv)): no "Grant *", no "Set Up Later".

---

## Step 2 — Conflict resolution (deterministic table)

| Conflict | Winner | Why |
|---|---|---|
| Concurrency: "use Swift actor" vs whisper.cpp/GPU: "SafeLock" | whisper.cpp/GPU | blocking C; `CLAUDE.md` |
| Architecture: "extract protocol" vs Consistency: "single conformer" | Consistency | no unit tests → no testability justification |
| Memory: `[weak self]` vs Concurrency: `[unowned self]` | Memory | safer default |
| HUD/UX: "skip animation" vs Consistency: "keep typewriter" | HUD/UX, RTL only | language-conditional |
| Platform: `os_log` formatter vs Security: `%{private}@` | Both — apply together | not a real conflict |
| App Store Binary: "remove string" vs Consistency: "keep helper" | App Store Binary | ship-blocker |
| State/Reliability: "add retry" vs Architecture: "keep simple" | State/Reliability for I/O | reliability over simplicity |
| Concurrency: "dispatch AX to background" vs Platform: "inline on caller" | Platform | queue contention causes multi-second delays |

**P0 (no skip allowed):** memory leaks, data races on shared mutable state, banned APIs (`CGEventTap`/`IOHIDManager`/global `keyDown`/`keyUp`/`IOHIDCheckAccess`/`IOHIDRequestAccess`), banned binary strings in AppStore config, plaintext credentials, missing `await stopAsync()`, ModelPool warm-check on full `ModelProfile`, preview bridge with `useGPU: true`, separate contexts for preview vs detection, AX call without 100ms timeout, `state = .idle` not before `insertText`.

---

## Step 3 — Apply fixes

- One commit per logical fix, never bundled.
- Commit format: `[final-review] <fix> (agent N)`.
- TodoWrite tracks each fix; mark completed as each lands.
- On follow-up passes, only fix what changed since the previous pass — convergence is the goal.

---

## Step 4 — Config-aware verification

Three configs build in parallel (`CLAUDE.md` lists Debug/Release; `AppStore` is the third per memory):

```bash
mkdir -p tmp
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug    -destination "platform=macOS" 2>&1 | tee tmp/build-debug.log    &
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Release  -destination "platform=macOS" 2>&1 | tee tmp/build-release.log  &
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration AppStore -destination "platform=macOS" 2>&1 | tee tmp/build-appstore.log &
wait
```

Sequential gates (each must pass):

```bash
# Warnings — zero tolerated
for f in tmp/build-*.log; do echo "$f: $(grep -c 'warning:' "$f")"; done

# No print() in production Swift
grep -rn 'print(' Whisperer/ --include='*.swift' | grep -v '// debug' || echo "OK: no print()"

# Banned input-monitoring APIs (App Store 2.4.5)
grep -rnE 'CGEventTap|IOHIDManager|addGlobalMonitorForEvents.*\.keyDown|addGlobalMonitorForEvents.*\.keyUp|IOHIDCheckAccess|IOHIDRequestAccess' Whisperer/ || echo "OK: no banned APIs"

# Synchronous transcriber.stop() (race → text duplication)
grep -rnE 'transcriber\.stop\(\)|streamingTranscriber\?\.stop\(\)' Whisperer/ \
  | grep -v 'stopAsync' && echo "FAIL: use stopAsync()" || echo "OK: stopAsync only"

# App Store binary scan
APP=$(find build -name whisperer.app -path '*AppStore*' | head -1)
[ -n "$APP" ] && /usr/bin/strings "$APP/Contents/MacOS/whisperer" \
  | grep -iE 'AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive' \
  && echo "FAIL: banned strings in binary" || echo "OK: binary clean"
```

**No unit tests exist (`CLAUDE.md`).** Do not invent test runs. State this plainly in the summary.

---

## Step 5 — UX/Perf smoke (per-PR, generated from diff scope)

Orchestrator picks the relevant items below based on which buckets the diff touched. Run only what's relevant; mark unverified items honestly.

- Time-to-first-preview-word ≤ 2s after key-down (Transcription/, Audio/).
- Time-to-text-injected ≤ 200ms after key-up, excluding tail (TextInjection/, Core/AppState).
- HUD dismisses concurrent with text appearing (Core/AppState ordering).
- HUD stuck recovery: `sudo killall coreaudiod` during recording → watchdog dumps within 15s, HUD returns to `.idle` (Audio/, Core/).
- Live preview text never shrinks mid-recording (Transcription/).
- RTL: dictate Hebrew → paragraph starts at right margin (UI/LiveTranscriptionCard, Transcription/).
- Language switch: English then Russian (or any two warm models) → second recording uses warm fallback, no GPU stall (Transcription/LanguageRouter/, ModelPool).
- Recording > 5 min cap behavior (Audio/AudioRecorder).
- Onboarding first-launch flow if `OnboardingView`/`OnboardingWindow` changed.

---

## Step 6 — Commit, push, summarize

```bash
git push -u origin HEAD
```

### Summary template

**Review Pass:** #N (state previous-pass scope if follow-up)

**Diff scope:** which buckets changed; which agents ran; which skipped and why.

**P0 fixes applied:** every memory/concurrency/security/banned-API fix, file:line cited.

**P1/P2 fixes applied:** grouped by agent.

**Skipped recommendations:** each with justification. P0 skips require extra written justification.

**UX/Perf outcomes:**
- Build warnings: `tmp/build-debug.log` / `tmp/build-release.log` / `tmp/build-appstore.log` deltas.
- `print()` count: before/after.
- Banned-API grep: clean / failed.
- Binary scan: clean / failed (list strings).
- Stuck dumps post-`BASE`: count + outcome.
- Manual smoke items run vs skipped.

**Unable to verify:** explicitly list (no unit tests; no automated Instruments; anything else).

**Pass-convergence verdict:**
- If any P0 was fixed → recommend another `/final-review` pass.
- If only stylistic tweaks → recommend merge.
- Be honest: "Fixed 2 retain cycles and a ModelPool warm-check regression — recommend one more pass" or "Naming nits only — ready to merge".

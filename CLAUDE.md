# CLAUDE.md

Whisperer is a native macOS menu bar app for offline voice-to-text transcription powered by whisper.cpp with Apple Silicon Metal GPU acceleration. Hold a key, speak, release — text appears wherever you're typing.

## Build

```bash
# Debug
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"

# Release
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS"

# Clean build
xcodebuild clean build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"
```

No linter.

## Tests

XCTest suite in `WhispererTests/` (76 files). The target uses a synchronized file group, so a new
`.swift` file there is picked up with no `pbxproj` edit.

**Never run the whole suite** — some suites load real models and take 18+ minutes. Always scope it:

```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" -only-testing:WhispererTests/<SuiteName>
```

Known slow suites (opt in deliberately): `PolishBenchmarkTests`, `PolishCorpusDumpTests`,
`PolishChunkCorpusDumpTests`, `MeetingPolishTests`.

Deallocating a `@MainActor` pure-Swift class inside a synchronous test method aborts the test host
(`pointer being freed was not allocated` in `swift_task_deinitOnExecutorImpl`). The project sets
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which synthesizes an isolated `deinit`. Keep such
test-built objects alive for the process, or make the class `nonisolated`.

## Key Paths

- Source: `Whisperer/` (Audio/, Core/, Dictionary/, History/, KeyListener/, Licensing/, Permissions/, Store/, TextInjection/, Transcription/, UI/)
- Xcode project: `Whisperer.xcodeproj`
- whisper.cpp: `whisper.cpp/` (vendored, not a submodule)
- Bundle ID: `com.ivy.whisperer`

## Critical Rules

IMPORTANT — these prevent real bugs and App Store rejections:

- **NEVER** use `CGEventTap`, `IOHIDManager`, or global `keyDown`/`keyUp` monitors — instant App Store rejection (Guideline 2.4.5)
- `Logger.shared` for all logging — **no `print()` statements**
- `[weak self]` in all `Task.detached` closures and stored callbacks
- `SafeLock` (timeout-based NSLock) for whisper.cpp thread safety — **not** Swift actors
- Always `await transcriber.stopAsync()`, never synchronous `stop()` — race condition causes text duplication
- `AppState` is `@MainActor` singleton — all state flows through `AppState.shared`
- Never dispatch AX calls to `DispatchQueue.global()` — causes multi-second delays from queue contention
- **ModelProfile warm check must compare model binary** (`model` + `backend`), NOT full profile (which includes `language`). Same `.bin` file with different language = same backend. Loading a duplicate model during recording causes 1.6s GPU freeze.
- **Preview/detector bridge is CPU-only** (`useGPU: false`). The shared tiny model in `ModelPool.previewBridge` handles both live preview and language detection. Must stay CPU-only — GPU causes Metal contention with the main model and SwiftUI rendering, freezing HUD animations.
- **Never create separate whisper contexts for preview and detection** — they share one tiny model context, serialized via `ctxLock`. Two contexts waste ~77MB and double GPU contention.
- **RTL text in SwiftUI**: `Text` view does NOT support paragraph base writing direction. Use `NSTextField` via `NSViewRepresentable` with `NSParagraphStyle.baseWritingDirection = .rightToLeft`. Attempts with `layoutDirection`, `locale`, `multilineTextAlignment`, and Unicode isolates all failed.
- **No Core ML / ANE on the whisper.cpp path** (other backends are unaffected — see below). The whisper encoder runs on Metal, always. The library was rebuilt `WHISPER_COREML=OFF` on 2026-08-15 and the Xcode flags removed on 2026-08-16 (`620b12a`), because the fixed-shape `MLMultiArray` Core ML builds from the mel tensor is incompatible with `audio_ctx`, which the eager streaming path needs to size the encoder to the window. Verified across all three configs: no `WHISPER_USE_COREML`, no `-lwhisper.coreml`, and the linked `whisper.cpp/build-static/src/libwhisper.a` exports zero Core ML symbols on both slices. `whisper_print_system_info` prints `COREML = 0`.
  - `CoreML.framework` **is** still linked via `OTHER_LDFLAGS` in all three configs — for WhisperKit, Parakeet/FluidAudio and MLX, which are genuine Core ML/ANE consumers. Its presence is not evidence that whisper.cpp uses Core ML. Likewise `build-coreml/`, `build-static-backup/libwhisper.coreml.a` and `libwhisper.a.bak-nocoreml` are leftovers, not what ships: to check, resolve `LIBRARY_SEARCH_PATHS` and `nm` the archive it names.
  - Do not reason about ANE encode when reading whisper timings.
  - Consequence for abort latency: `wparams.abort_callback` is polled per decoder token (~1.6 ms) but **only once per encoder pass**, because the `ggml_backend_sched_t` graph-compute overload (`whisper.cpp/src/whisper.cpp:190-207`) installs no abort callback. Abort granularity is therefore one 30s window (~670 ms encode), not instant.

## Debugging Stuck States

When the user reports the HUD is stuck (e.g., "Listening… forever", "HUD won't dismiss", "recording stuck", "can't stop recording", same issue again):

1. **First check `~/Library/Logs/Whisperer/` for `stuck-*.dump` files**. Debug builds auto-dump full state when the audio-progress watchdog trips (no audio buffers for 15s while `state == .recording`). Each file is a self-contained snapshot: AppState, AudioRecorder, audio engine, all NSWindows, thread sample, recent log tail.
2. **Use the `stuck-dump-analyze` skill** (`.claude/skills/stuck-dump-analyze/`) to parse the latest dump and produce a root-cause report.
3. **Do not propose fixes from logs alone** — read the dump first. The dump definitively tells you whether `AppState.state`, `AudioRecorder.recorderState`, and `audioEngine.isRunning` agree, which thread (if any) is blocked, and what preceded the freeze.
4. The watchdog lives in `AppState.startRecordingWatchdog()` and dumps via `StuckStateDumper.dump(reason:)`. Trigger artificially with `sudo killall coreaudiod` while recording — within ~15s a dump is written and the HUD recovers to `.idle`.

## Documentation

**Read these with the Read tool when the task calls for it — do NOT use `@` imports here.**
An `@` prefix loads the file into every session at launch; these total ~2,400 lines and are
only relevant to a fraction of tasks. The Critical Rules above are the always-on subset.

| Read when | File |
|---|---|
| Writing/editing any Swift — naming, error handling, logging, memory | `AGENTS.md` |
| Touching audio capture, the state machine, meetings, MCP, or storage | `ARCHITECTURE.md` |
| Touching any SwiftUI/AppKit view, color, or font | `DESIGN.md` |
| Deciding what a feature should do or how it should feel | `PRODUCT_SENSE.md` |
| Picking up planned work or logging tech debt | `PLANS.md` |
| Editing `WhisperBridge` or anything calling whisper.cpp C APIs | `docs/references/whisper-cpp-integration.md` |
| Editing `LanguageRouter`, `ModelPool`, `ModelRouter`, `ScriptAnalyzer` | `docs/references/language-routing.md` |
| Preparing a submission or touching `#if APP_STORE` paths | `docs/exec-plans/app-store-submission.md` |

`ARCHITECTURE.md` is 900+ lines — jump to the relevant `##` section rather than reading it whole.

## Slash Commands

- `/final-review` — 7 parallel review agents (Memory, Concurrency, Architecture, Consistency, Platform, State/Reliability, Security) then reconcile and apply fixes
- `/conventions-check` — Coding standards scan (print statements, force unwraps, weak self, banned APIs)

## Skills

Each skill is a folder in `.claude/skills/` with a `SKILL.md` (YAML frontmatter for auto-triggering) and optional `references/`. Claude loads them automatically based on trigger phrases — they are not slash commands.

- **design-check** — Design system compliance. Triggers on UI code changes.
- **app-store-check** — Guideline 2.4.5 compliance scan. Triggers on KeyListener/TextInjector/Permissions changes.
- **submission-prep** — Full App Store submission workflow with templates. Triggers on "prepare submission", "build for release".

## Knowledge System

Before starting a task, review existing rules and hypotheses for the relevant domain.
Apply rules by default. Check if any hypothesis can be tested with the current work.

At the end of each task, extract insights into domain folders under `docs/knowledge/`:

```
docs/knowledge/
    INDEX.md          (routes to each domain folder)
    audio/
        knowledge.md  (facts and confirmed patterns)
        hypotheses.md (need more data)
        rules.md      (confirmed — apply by default)
    transcription/
        ...
```

- When a hypothesis gets confirmed 3+ times, promote it to a rule.
- When a rule gets contradicted by new data, demote it back to a hypothesis.
- Domain folders are created on demand as insights emerge (e.g., `audio/`, `transcription/`, `ui/`, `app-store/`).
- Maintain `docs/knowledge/INDEX.md` as the entry point routing to each domain folder.

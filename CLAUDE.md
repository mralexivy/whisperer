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

No unit tests. No linter.

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
- **Preview/detector bridge is CPU-only** (`useGPU: false`). The shared tiny model in `ModelPool.previewBridge` handles both live preview and language detection. Must stay CPU-only — GPU causes Metal contention with the main model and SwiftUI rendering, freezing HUD animations. CoreML encoder still uses ANE regardless of `useGPU` flag.
- **Never create separate whisper contexts for preview and detection** — they share one tiny model context, serialized via `ctxLock`. Two contexts waste ~77MB and double GPU contention.
- **RTL text in SwiftUI**: `Text` view does NOT support paragraph base writing direction. Use `NSTextField` via `NSViewRepresentable` with `NSParagraphStyle.baseWritingDirection = .rightToLeft`. Attempts with `layoutDirection`, `locale`, `multilineTextAlignment`, and Unicode isolates all failed.
- **Core ML**: whisper.cpp is compiled with `WHISPER_USE_COREML=ON` and `WHISPER_COREML_ALLOW_FALLBACK=ON`. CoreML encoder loads unconditionally (not gated by `use_gpu`), uses `MLComputeUnitsAll`. Models with `.mlmodelc` next to `.bin` use ANE encoder. Models without fall back to Metal silently.

## Documentation

Read these on demand — don't load all at once:

- Coding conventions, naming patterns, Swift idioms: @AGENTS.md
- System architecture, state machine, design decisions: @ARCHITECTURE.md
- UI design system (colors, typography, components, anti-patterns): @DESIGN.md
- Product vision, UX principles, target users: @PRODUCT_SENSE.md
- Active plans and tech debt: @PLANS.md
- whisper.cpp C interop reference: @docs/references/whisper-cpp-integration.md
- Language routing architecture and whisper.cpp detection API: @docs/references/language-routing.md
- App Store submission checklist: @docs/exec-plans/app-store-submission.md

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

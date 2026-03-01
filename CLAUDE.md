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

## Documentation

Read these on demand — don't load all at once:

- Coding conventions, naming patterns, Swift idioms: @AGENTS.md
- System architecture, state machine, design decisions: @ARCHITECTURE.md
- UI design system (colors, typography, components, anti-patterns): @DESIGN.md
- Product vision, UX principles, target users: @PRODUCT_SENSE.md
- Active plans and tech debt: @PLANS.md
- whisper.cpp C interop reference: @docs/references/whisper-cpp-integration.md
- App Store submission checklist: @docs/exec-plans/app-store-submission.md

## Slash Commands

- `/final-review` — 7 parallel review agents (Memory, Concurrency, Architecture, Consistency, Platform, State/Reliability, Security) then reconcile and apply fixes
- `/conventions-check` — Coding standards scan (print statements, force unwraps, weak self, banned APIs)

## Skills

Each skill is a folder in `.claude/skills/` with a `SKILL.md` (YAML frontmatter for auto-triggering) and optional `references/`. Claude loads them automatically based on trigger phrases — they are not slash commands.

- **design-check** — Design system compliance. Triggers on UI code changes.
- **app-store-check** — Guideline 2.4.5 compliance scan. Triggers on KeyListener/TextInjector/Permissions changes.
- **submission-prep** — Full App Store submission workflow with templates. Triggers on "prepare submission", "build for release".

# Agent 3 — Architecture & Dependency Direction Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file
- Reference: `CLAUDE.md`, `AGENTS.md`, `ARCHITECTURE.md` (Dependency Direction, Component Ownership)

## Output
Write to `.claude/review-state/findings/agent-03.md`
Return: `Agent 3 (Architecture & Deps): X P0, Y P1, Z P2`

## Preamble

Read `docs/knowledge/transcription/rules.md` if it exists. Check all `Check:` patterns first.

## Focus Checklist

### Dependency Direction

Strictly top-down:
```
UI Layer (SwiftUI Views)
    ↓ reads @Published, calls methods
AppState (@MainActor singleton)
    ↓ holds references, calls methods
Services (AudioRecorder, WhisperBridge, TextInjector, etc.)
    ↓ uses
Infrastructure (Logger, SafeLock, CrashHandler)
```

- **P0**: Any Service importing `SwiftUI` or `AppKit` (except `TextInjector` which inherently needs AppKit for AX)
- **P1**: Any Service holding a reference to `AppState` — services communicate back via closures (`onStreamingSamples`, `onTranscription`), never by importing AppState
- **P1**: Any View directly calling a Service method (must go through AppState)
- **P1**: Infrastructure depending on Services

### Pipeline Bypass Gates

- **BUG-T06 (P1)**: Two correction stages in the same transcription pipeline without a bypass gate — `DictionaryManager.correctText()` corrupts LLM input when LLM post-processing is enabled. Pattern: any new correction/transformation stage added to `StreamingTranscriber.stop()` or `stopAsync()` that does not check `aiModeEnabled` or `skipCorrections`. Every rule-based correction stage must be bypassable when a downstream ML model handles the same responsibility. Check all `correctText()` call sites in `StreamingTranscriber`.

### Build Configuration Flag

- **BUG-AS04 (P1)**: `#if ENABLE_APP_SANDBOX` is a build setting, not a Swift compile flag — it does NOT work as a `#if` guard in Swift source. The canonical flag is `#if APP_STORE`. Grep for `#if ENABLE_APP_SANDBOX` in any Swift file — every occurrence is a bug. The feature it was supposed to gate is always compiled in.

### Language & Routing State

- **BUG-LR01 (P1)**: Reading `selectedLanguage` (the user's configured preference) instead of `transcriber.effectiveLanguage` (the router's post-detection result) for history saves or display. In multilingual routing mode, the effective language may differ from the configured primary. Any code path that persists "which language was used" must use `StreamingTranscriber.effectiveLanguage` (`routeDecision?.lang ?? language`), not `AppState.selectedLanguage`.

### Error Handling Architecture

- Errors as typed enums with `LocalizedError` — no `String`-based errors, no `NSError` without meaningful domain/code
- `fatalError` / `preconditionFailure` only for programmer errors, never reachable from user input or external data. Flag `fatalError` in any path that could be triggered by: model file not found, malformed audio, network error, permission denied.

### Protocol Justification

- Protocols with a single conformer and no test mock: flag as premature abstraction (P2). No unit tests exist in this codebase, so protocols-for-testability have zero payoff. Exception: `TranscriptionBackend` protocol is justified by multiple conformers.

### Domain Type Purity

- Domain types (RouteDecision, ModelProfile, AudioDevice, TranscriptionResult) must not import `SwiftUI`, `AppKit`, or `Foundation.URLSession`. They should be pure Swift structs/enums.
- Flag any `import SwiftUI` or `import AppKit` in files under `Transcription/`, `Audio/Core/`, `Dictionary/`, `TextInjection/`, `KeyListener/`.

### File Placement

- New files must land in the correct `Whisperer/` subdirectory per `ARCHITECTURE.md`:
  - Audio capture/device: `Audio/`
  - Transcription/backends: `Transcription/`
  - LLM processing: `Transcription/LLM/`
  - Language routing: `Transcription/LanguageRouter/`
  - FluidAudio bridge: `Transcription/FluidAudio/`
  - AppKit/SwiftUI overlay: `UI/`
  - Text injection: `TextInjection/`
  - History/CoreData: `History/`
  - Dictionary: `Dictionary/`
  - Common infrastructure: `Audio/Core/`
  
  Flag any Swift file placed at the wrong level (e.g., a new backend bridge in `UI/` or a view in `Transcription/`).

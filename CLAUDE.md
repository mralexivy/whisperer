# CLAUDE.md

This file provides guidance to Claude Code when working with Whisperer.

## Project Overview

Whisperer is a native macOS menu bar app for offline voice-to-text transcription. Users hold a key, speak, and release — transcribed text is injected into the focused text field. Powered by whisper.cpp with Apple Silicon Metal GPU acceleration. Entirely offline, no network required for transcription.

## Build Commands

```bash
# Build (Release)
xcodebuild build -project Whisperer/whisperer/whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS"

# Build (Debug)
xcodebuild build -project Whisperer/whisperer/whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"

# Clean build
xcodebuild clean build -project Whisperer/whisperer/whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"
```

There are no unit tests in this project. No linter is configured.

## Key Paths

- **Source code**: `Whisperer/whisperer/whisperer/` (Audio/, Core/, Dictionary/, History/, KeyListener/, Licensing/, Permissions/, Store/, TextInjection/, Transcription/, UI/)
- **Xcode project**: `Whisperer/whisperer/whisperer.xcodeproj`
- **whisper.cpp**: `whisper.cpp/` (vendored C++ library, not a git submodule)
- **Bundle ID**: `com.ivy.whisperer`

## When Working On...

- **UI/Design** → Load skills: `design-colors`, `design-typography`, `design-layout`, `design-components`
- **Audio/Transcription** → Load skills: `whisper-integration`, `architecture-decisions`
- **New code/Refactoring** → Load skill: `coding-conventions`
- **State/Lifecycle/Threading** → Load skill: `architecture-decisions`
- **App Store prep** → Load skill: `app-store-submission`

## Critical Rules (Always Apply)

1. `AppState` is `@MainActor` — all UI state updates go through `AppState.shared`
2. `SafeLock` (timeout-based NSLock) for whisper.cpp thread safety, not Swift actors
3. `WhispererColors` only — no system semantic colors in workspace views
4. `Logger.shared` — no `print()` statements
5. 5-minute max recording limit prevents unbounded memory growth (~19MB)
6. `[weak self]` in all `Task.detached` closures and stored callbacks
7. Audio pipeline: Microphone → AudioRecorder → StreamingTranscriber → WhisperBridge → CorrectionEngine → TextInjector

## Custom Slash Commands

- `/final-review` — Launches 7 parallel review agents (Memory, Concurrency, Architecture, Consistency, Platform, State/Reliability, Security) then reconciles and applies fixes
- `/design-check` — Quick design system compliance check on changed UI files
- `/conventions-check` — Coding conventions scan (print statements, force unwraps, weak self)

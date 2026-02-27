# CLAUDE.md

This file provides guidance to Claude Code when working with Whisperer.

## Project Overview

Whisperer is a native macOS menu bar app for offline voice-to-text transcription. Users hold a key, speak, and release — transcribed text is injected into the focused text field. Powered by whisper.cpp with Apple Silicon Metal GPU acceleration. Entirely offline, no network required for transcription.

## Build Commands

```bash
# Build (Release)
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS"

# Build (Debug)
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"

# Clean build
xcodebuild clean build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS"
```

There are no unit tests in this project. No linter is configured.

## Key Paths

- **Source code**: `Whisperer/` (Audio/, Core/, Dictionary/, History/, KeyListener/, Licensing/, Permissions/, Store/, TextInjection/, Transcription/, UI/)
- **Xcode project**: `Whisperer.xcodeproj`
- **whisper.cpp**: `whisper.cpp/` (vendored C++ library, not a git submodule)
- **Bundle ID**: `com.ivy.whisperer`
- **App icon assets**: `Whisperer/Assets.xcassets/AppIcon.appiconset/` (dark navy + gradient waveform)

## Documentation Map

- **AGENTS.md** — Critical rules, coding conventions, naming patterns, Swift idioms
- **ARCHITECTURE.md** — System design, state machine, audio pipeline, component ownership
- **DESIGN.md** — Unified dark navy theme, blue-purple accents, colorful icons, typography, layout patterns, components
- **PRODUCT_SENSE.md** — Product vision, UX principles, target users
- **PLANS.md** — Planning process, active plans, tech debt
- **docs/references/** — Deep technical references (whisper.cpp C interop)
- **docs/exec-plans/** — Execution plans, App Store submission checklist

## Custom Slash Commands

- `/final-review` — Launches 7 parallel review agents (Memory, Concurrency, Architecture, Consistency, Platform, State/Reliability, Security) then reconciles and applies fixes
- `/conventions-check` — Coding conventions scan (print statements, force unwraps, weak self, App Store banned APIs)

## Skills (`.claude/skills/`)

Reference knowledge that Claude should read and apply when working on relevant tasks. These are NOT slash commands — Claude uses them automatically as context.

- **design-check** — Design system compliance rules (colors, typography, components). Read this before creating or modifying any UI code.
- **app-store-check** — App Store Guideline 2.4.5 compliance rules (banned APIs, approved APIs, framing). Read this before touching KeyListener, TextInjector, or Permissions code.
- **submission-prep** — Pre-submission checklist and reviewer notes template. Read this when preparing a build for App Store submission.

# Planning & Execution

## Active Plans

See [docs/exec-plans/](docs/exec-plans/) for active and completed execution plans.

## Tech Debt

Tracked in [docs/exec-plans/tech-debt.md](docs/exec-plans/tech-debt.md).

## Planning Process

1. Feature proposals start as GitHub issues or discussions
2. Complex features get design docs in [docs/design-docs/](docs/design-docs/)
3. Execution plans go in [docs/exec-plans/](docs/exec-plans/) with clear acceptance criteria
4. Completed plans are marked as such but retained for reference

## Current Focus Areas

- App Store resubmission — awaiting review after comprehensive design restyle and Guideline 2.4.5 compliance
- Pro Pack IAP testing and validation

## Completed

- **Unified dark navy theme restyle** — Replaced the previous green-accent gray-dark design with a unified dark navy palette (#0C0C1A background, #14142B cards, #5B6CF7 blue + #8B5CF6 purple accents) across ALL windows: workspace, menu bar, overlay HUD, and onboarding. Added per-element colorful icons, blue-purple gradient CTAs, colorful metadata pills, and flat window chrome with no system borders. Updated app icon from white/green to dark navy with gradient waveform.

- **Onboarding window** — Added four-page guided first-run experience (OnboardingWindow + OnboardingView): Welcome splash, Permissions setup (Microphone + Accessibility), Model download, Shortcut configuration. Uses the same dark navy theme. Sets `hasCompletedOnboarding` UserDefaults flag. Ensures users are recording-ready when onboarding completes.

- **Menu bar window restyle** — Replaced system colors with MBColors dark navy palette, added MenuBarWindowConfigurator NSViewRepresentable for flat window chrome, per-tab colorful icons (Status=blue, Models=orange, Settings=purple), accent gradient header icon, settingsCard helper with colorful icon pattern.

- **Overlay HUD restyle** — Changed from adaptive light/dark to always-dark navy. Blue accent throughout (recording indicator, waveform bars, mic button, transcribing dots, live transcription card).

- **App Store Guideline 2.4.5 compliance** — Removed CGEventTap, IOHIDManager, global keyDown/keyUp monitors. Replaced with flagsChanged + Carbon hotkeys. Removed Input Monitoring permission. See [docs/exec-plans/app-store-submission.md](docs/exec-plans/app-store-submission.md).

- **Text injection latency fix** — Removed background dispatch that caused 2.4s+ delays from queue contention. Added AX messaging timeouts (100ms).

- **Audio engine crash protection** — Added universal retry logic with engine teardown and format validation for transient device errors (error 1852797029).

- **Transcription speed optimization** — Disabled temperature fallback ladder (prevents 2-6x retry latency), tail-only final pass (10-15x faster stop), single-segment mode for streaming chunks, P-core-aware thread count on Apple Silicon, explicit `detect_language=false`, lightweight VAD `hasSpeech()` check.

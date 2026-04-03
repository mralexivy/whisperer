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

- **Menu bar window restyle** — Replaced system colors with MBColors dark navy palette, added MenuBarWindowConfigurator NSViewRepresentable for flat window chrome, per-tab colorful icons (Status=blue, Models=orange, Settings=red), accent gradient header icon, settingsCard helper with colorful icon pattern.

- **Overlay HUD restyle** — Changed from adaptive light/dark to always-dark navy. Blue accent throughout (recording indicator, waveform bars, mic button, transcribing dots, live transcription card).

- **App Store Guideline 2.4.5 compliance** — Removed CGEventTap, IOHIDManager, global keyDown/keyUp monitors. Replaced with flagsChanged + Carbon hotkeys. Removed Input Monitoring permission. See [docs/exec-plans/app-store-submission.md](docs/exec-plans/app-store-submission.md).

- **Text injection latency fix** — Removed background dispatch that caused 2.4s+ delays from queue contention. Added AX messaging timeouts (100ms).

- **Audio engine crash protection** — Added universal retry logic with engine teardown and format validation for transient device errors (error 1852797029).

- **Transcription speed optimization** — Disabled temperature fallback ladder (prevents 2-6x retry latency), tail-only final pass (10-15x faster stop), single-segment mode for streaming chunks, P-core-aware thread count on Apple Silicon, explicit `detect_language=false`, lightweight VAD `hasSpeech()` check.

- **Text duplication fix** — Fixed race condition where `transcriber.stop()` read stale `lastProcessedSampleIndex` while an in-flight chunk was still being transcribed, causing the tail to overlap with already-processed audio and producing duplicated text output. Changed both `stopRecording()` and `stopInAppRecording()` to use `await transcriber.stopAsync()` which waits for in-flight chunks to complete before the final pass.

- **HUD stuck prevention** — Added 5-second safety timeout in `stopRecording()`. If `audioRecorder.stopRecording()` hangs (e.g., `AVAudioEngine.stop()` blocking on a bad audio device), the timeout forces state to `.idle` and dismisses the overlay HUD. The main stop Task checks if the timeout already fired before proceeding with transcription.

- **Language detection improvements** — VAD-filtered detection windows (strip silence before `whisper_lang_auto_detect`), confidence-gated fast-path (1.5s voiced audio with 0.30 margin requirement), starvation guard (retry budget only consumed on actual detection attempts), weak per-chunk reinforcement from `whisper_full_lang_id()` (half-weight decaying signal), script-family analysis refactor (12+ Unicode script ranges mapped to language candidates via allowed shortlist, CJK disambiguation). See [docs/references/language-routing.md](docs/references/language-routing.md).

- **Language routing system** — Full multilingual routing: WhisperBridge.detectLanguage() (shared CPU-only tiny model) → LanguageRouter (shortlist + state machine) → ModelRouter → ModelPool (warm/cold backend selection). Preview and detection share one context to avoid GPU contention. Core ML ANE acceleration for both tiny bridge and main model. See [docs/references/language-routing.md](docs/references/language-routing.md).

- **Core ML ANE acceleration** — Rebuilt whisper.cpp with `WHISPER_COREML=ON`. Pre-converted Core ML encoders downloaded from HuggingFace. Main model 19% faster on ANE (588ms vs 731ms). Both models use ANE encoder, decoders on GPU. Fallback to Metal when `.mlmodelc` absent.

- **Live transcription rewrite** — Replaced Parakeet EOU (English-only, Neural Engine) with append-only preview using tiny Whisper model (multilingual). Preview runs every 1s, transcribes only new audio with overlap dedup. Text only grows (monotonic) for smooth word-by-word animation. Detection-gated (waits for language routing before starting). Chunk handoff clears preview on finalization.

- **RTL live transcription** — Content-based RTL detection from Unicode scalar analysis. NSTextField via NSViewRepresentable for guaranteed paragraph base writing direction (SwiftUI Text doesn't support it). RTL scrollbar on left edge. Word animation skipped for RTL. State isolation via `.id(recordingSessionID)`.

- **Live transcription minimal scrollbar** — Custom track+thumb scrollbar (2.5pt wide, accent blue thumb, subtle white track). Auto-shows when content overflows, auto-hides after 2s. Thumb tracks scroll position. Left-side for RTL, right-side for LTR.

- **Live transcription expand/collapse** — Toggle button in card header (rightmost, after badges) to maximize text area from 72pt to up to 340pt. OverlayPanel dynamically resizes via `adjustFrameForContent()` using `NSHostingView.fittingSize`. Grows upward for bottom positions, downward for top. State resets per recording via `.id(recordingSessionID)`. Button dims when content fits in minimized view.

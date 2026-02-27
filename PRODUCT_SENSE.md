# Whisperer Product Sense

## Vision

Whisperer is invisible transcription. Hold a key, speak, release — your words appear wherever you're typing. No app switching, no copy-pasting, no cloud services. The tool disappears; only your words remain.

## Core Value Proposition

1. **100% Offline** — All transcription happens locally on your Mac using whisper.cpp with Metal GPU acceleration. No data leaves your device, ever. This isn't a privacy toggle — it's the architecture.

2. **Works Everywhere** — Text appears in the focused field of any app: Safari, VS Code, Slack, Notes, Terminal. Users don't need to think about compatibility.

3. **Instant** — The model stays pre-loaded in memory. Recording starts immediately on keypress. Streaming transcription shows words as you speak. The final pass re-transcribes for accuracy.

## UX Principles

### Premium Dark Aesthetic
- Unified dark navy theme across all windows — workspace, menu bar, overlay, onboarding
- Blue-purple gradient accents with per-element colorful icons
- Always-dark appearance — no light mode. Deep navy (#0C0C1A), not gray dark mode
- Flat window chrome with no visible system borders or shadows
- App icon matches the theme: navy background with gradient waveform

### Guided First-Run Experience
- Four-page onboarding window on first launch: Welcome, Permissions, Model Download, Shortcut Setup
- Permissions and model download happen during onboarding — not after
- User is recording-ready when onboarding completes

### Invisible Until Needed
- Menu bar app with no dock icon (`.accessory` activation policy)
- Non-activating overlay panel — never steals focus from the user's current app
- Hold-to-record as default — the most natural, least-thought interaction model

### Instant Feedback
- Live waveform visualization confirms the mic is hearing you
- Streaming transcription shows words appearing in real-time (2-second chunks)
- Distinct audio cues (Tink/Pop) confirm recording start/stop
- Pulsing dot indicator for recording state

### Fail Gracefully
- Accessibility API for text injection with clipboard fallback — works even when AX doesn't
- Clipboard content restored after paste fallback — nothing lost
- VAD is optional — the app works without it
- Audio device recovery — handles mic disconnection gracefully

## Feature Philosophy

### Reliability Over Features
The 5-minute recording limit exists because unbounded memory is a crash risk. The SafeLock timeout exists because deadlocks are worse than dropped transcriptions. The model stays in memory because a 3-second loading delay breaks the "instant" promise.

Every architectural decision optimizes for: will this work reliably, every time, without thinking?

### Accuracy Over Speed (When It Matters)
Streaming transcription is fast but approximate — it's for the live preview UX. The final-pass re-transcription processes the complete recording with full context, producing significantly more accurate output. Users see fast feedback, but get accurate results.

### Smart Defaults
- Large V3 Turbo Q5 as default model — best balance of speed, size, and accuracy
- Fn key as default trigger — dedicated key that doesn't conflict with normal typing
- System audio muting during recording — prevents feedback loops on calls
- Hold-to-record mode — intuitive for most users (toggle mode available)

## Target Users

- **Knowledge workers** — Quick voice notes, drafting emails, meeting follow-ups
- **Accessibility** — Users who find typing difficult or painful
- **Multilingual professionals** — 100+ language support, explicit language selection for best accuracy
- **Privacy-conscious users** — No cloud dependency, no data collection ("Data Not Collected")

## What Makes Whisperer Different

| vs. Cloud Services | vs. Other Offline Tools |
|--------------------|-----------------------|
| No internet needed | Native macOS integration (menu bar, overlay, text injection) |
| No subscription | Hold-to-record UX (not file-based transcription) |
| No data leaves device | Streaming preview + final-pass accuracy |
| No latency to servers | Apple Silicon Metal GPU acceleration |
| Works in airplane mode | Dictionary & spell correction built in |

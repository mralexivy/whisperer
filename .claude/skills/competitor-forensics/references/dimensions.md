# Analysis Dimensions

Nine dimensions for Phase 2 agents. Each agent gets ONE dimension. Read your section, read the evidence files, confirm our behavior with codegraph, then write findings to `$RUN/20-<dimension-slug>.md`.

Every finding must be tagged AHEAD, GAP, or BEHIND (from the competitor's perspective vs us):
- `AHEAD` — they beat us on this axis
- `GAP` — we have no equivalent feature at all
- `BEHIND` — we are stronger here (record it so we don't regress)

---

## Dimension 1 — Capture & Hotkey Model

**What to analyze:** How does the competitor capture audio? What trigger model do they use (hold-to-record, push-to-talk, always-on VAD, toggle)? What's the UI/UX around starting and stopping? How fast does recording begin after the hotkey fires?

**Evidence signals to look for:**
- `AVAudioEngine` vs `AudioQueue` vs `AVCaptureSession` — affects latency
- Sample rate handling (native vs fixed 16kHz)
- VAD (voice activity detection) — silent-trim, auto-stop
- Push-to-talk vs tap-to-toggle vs always-on
- Hotkey registration mechanism (global shortcut, Accessibility, menu bar button)
- Waveform / audio level visualization approach
- "Press and hold vs click" UI choice and its tradeoffs

**Our anchor (read these to confirm our behavior before judging):**
- `Whisperer/Audio/AudioRecorder.swift` — our capture pipeline
- `Whisperer/KeyListener/` — our hotkey model (no CGEventTap, no IOHIDManager)
- `AppState.swift` state machine (`.idle → .recording → .transcribing → .idle`)
- `docs/PRODUCT_SENSE.md` — why we chose hold-to-record

**Judgment axes:** trigger-to-audio latency, flexibility (multiple trigger modes), reliability (edge cases: mic unavailable, background noise), feedback quality.

---

## Dimension 2 — ASR Stack: Models, Backends, Streaming

**What to analyze:** Which ASR engine? Which models (size, quantization, language coverage)? How is streaming implemented — what's the chunk size and overlap? What language detection approach? What's the quality–latency tradeoff?

**Evidence signals to look for:**
- Model files (`.gguf`, `.mlmodelc`, `.bin`, `.safetensors`) — name + size reveals model family and quant
- Backends: `whisper.cpp` Metal, `WhisperKit` Core ML/ANE, `mlx_whisper`, `faster-whisper`, cloud API
- Streaming chunk size and overlap strategy
- Language detection mechanism (per-pass encoder, separate detector, Apple Speech)
- How they handle multilingual content or language switching
- Parallel / pooled model instances for low-latency repeat requests
- Model warm-up strategy
- Error recovery on bad audio (silence, noise, codec artifacts)

**Our anchor:**
- `Whisperer/Transcription/` — our bridge hierarchy
- `docs/references/whisper-cpp-integration.md` — Metal-only path, no CoreML on whisper
- `docs/references/language-routing.md` — agreement ratchet, language pinning
- CLAUDE.md Critical Rules: "No Core ML / ANE on the whisper.cpp path", "ModelProfile warm check must compare model binary"

**Judgment axes:** WER on common accents, language auto-detect accuracy, tail decode latency (time from release-to-type), memory footprint, cold-start time.

---

## Dimension 3 — Text Delivery & OS Integration

**What to analyze:** How does text get from transcription into the user's cursor? What's the injection mechanism? What's the compatibility story across apps?

**Evidence signals to look for:**
- Injection method: `AXUIElement insertText`, `CGEventPost` keystrokes, `NSPasteboard` + Cmd+V, macOS Services, Input Method
- Accessibility entitlement presence/absence
- Sandbox status (governs which injection paths are available)
- Per-app compatibility overrides (some apps need special paths)
- How they handle apps that resist paste (terminal, password fields)
- "Smart paste" — does it replace selected text?
- RTL support
- Injection latency (from transcription complete to text appearing)

**Our anchor:**
- `Whisperer/TextInjection/` — our injection stack
- CLAUDE.md: "NEVER use CGEventTap, IOHIDManager, or global keyDown/keyUp monitors — instant App Store rejection"
- `#if !APP_STORE` Accessibility / CGEvent paths that exist in Dev builds but are removed in App Store build
- RTL approach: NSTextField via NSViewRepresentable (SwiftUI Text doesn't support paragraph base direction)

**Judgment axes:** compatibility breadth, injection latency, App Store compliance risk, RTL/multilingual correctness.

---

## Dimension 4 — Post-Processing: LLM, Formatting, Dictionary, Learning

**What to analyze:** What happens to raw ASR output before delivery? Punctuation? Capitalization? Custom vocabulary? LLM reformatting? Does the app learn from corrections?

**Evidence signals to look for:**
- Punctuation / capitalization model: rule-based, mmBERT-style sequence model, LLM prompt
- Custom dictionary / vocabulary boost: how entries are stored and applied
- LLM post-processing: cloud (OpenAI/Anthropic) or local (MLX, Ollama, Core ML)
- User correction learning: does it learn from edits made after paste?
- Per-app style profiles (e.g. no trailing period in messaging apps)
- Prompt templates or system prompts visible in `strings` or JS bundles
- Paragraph detection

**Our anchor:**
- `Whisperer/Dictionary/` — suggestion engine, correction card, learning gates
- `Whisperer/Transcription/LLM/` — mmBERT, NemotronBridge, FastPolish
- `docs/knowledge/polishing/` — rules and hypotheses about post-processing
- `docs/exec-plans/correction-learning.md`
- Commits: `cf45f56` Wispr-style silent post-paste learning, `69ac29d` correction card

**Judgment axes:** formatting quality on raw dictation, custom word accuracy, learning speed, privacy (does correction data leave device?), LLM quality vs latency tradeoff.

---

## Dimension 5 — Meetings: Diarization, Notes, Summarization

**What to analyze:** Does the competitor have a meeting mode? How does it capture system audio + mic? How is speaker diarization done? What does the meeting summary look like?

**Evidence signals to look for:**
- `kAudioDeviceTransportTypeVirtual` or `BlackHole` / `SoundFlower` for system audio tap
- Screen capture permission for meeting detection
- Speaker diarization library (`pyannote`, `WhisperX`, Core ML speaker embeddings, cloud API)
- Meeting source detection (Zoom, Slack, Google Meet — process name or window title scanning)
- Summary templates and prompts (visible in strings or JS)
- Retranscribe / re-process option
- Export formats: Markdown, JSON, calendar integration
- Meeting library / history management

**Our anchor:**
- Meeting pipeline: `Whisperer/Transcription/` meeting engines, `93bee25` post-meeting job queue
- `docs/knowledge/meetings/` — meeting domain knowledge
- Commits `bb6bd63` (source app icon), `c192623` (processing banner), `6e56d67` (speaker filter)
- `MeetingManager`, `MeetingNotes`, `SpeakerProfile` in the codebase

**Judgment axes:** diarization accuracy (speaker separation), latency from meeting end to summary, export quality, source app detection breadth, retranscribe UX.

---

## Dimension 6 — Interaction UX: HUD, Feedback, Error Recovery, Onboarding

**What to analyze:** What does the user see and feel? How is in-progress state communicated? How do errors surface? How does the app recover gracefully from failure?

**Evidence signals to look for:**
- Recording HUD: waveform, timer, visual feedback style
- Processing indicator (does the user know transcription is in progress?)
- Error states: microphone denied, model not loaded, transcription failed — how shown?
- Retry / recovery UX
- Permission onboarding flow (step by step? Single page?)
- First-run experience and model download UX
- Keyboard shortcut discoverability
- Settings discoverability and information architecture

**Our anchor:**
- `Whisperer/UI/` — all HUD and view code
- `docs/PRODUCT_SENSE.md` — our UX philosophy
- CLAUDE.md Critical Rules on permissions: "NEVER use 'Grant [Permission]' on buttons — use 'Continue' or 'Next'" (App Store 5.1.1(iv))
- HealthManager / watchdog / stuck-dump system for our reliability layer

**Judgment axes:** clarity of state (user always knows what's happening), error recovery UX, time-to-first-transcription on fresh install, permission flow conversion.

---

## Dimension 7 — Visual Craft: Layout, Motion, Typography, Density

**What to analyze:** What does it look like? Is the visual design premium? Does motion feel intentional? Is it consistent? Does it look native or Electron-cheap?

**Evidence signals to look for:**
- Native AppKit/SwiftUI vs Electron/Tauri (determines what's even possible)
- Screenshot and video analysis: color system, typography choices, icon style
- Animation quality: HUD appear/dismiss, waveform, processing state
- Dark mode support and adaptation
- Menu bar icon design and states
- Density: does the UI earn its screen real estate?
- Typography: custom font vs SF Pro, sizing hierarchy
- Status/error visual language

**Our anchor:**
- `docs/DESIGN.md` — our design system: colors, typography, spacing, component patterns
- `Whisperer/UI/` — actual implementations
- CLAUDE.md: RTL NSTextField pattern, SwiftUI limitations

**Judgment axes:** premium feel (would a designer use it as a portfolio piece?), native vs web-app feel, motion quality, first impression.

---

## Dimension 8 — Resource Utilization: Memory, GPU/ANE, Thermals, Idle Cost

**What to analyze:** How much does this thing cost when idle? Recording? Transcribing? Does it cause fan spin? How much RAM does it use?

**Evidence signals to look for:**
- From strings / repo: any mention of memory limits, model eviction, lazy load, background pooling
- From App Support / prefs: model cache settings
- From public reviews: user complaints about battery drain, fan noise, memory
- Framework analysis: Core ML (ANE - low power) vs Metal (GPU - higher power)
- Model sizes: a 1.5GB model loaded at launch vs on demand is a huge difference
- Any mention of `NSProcessInfo.processInfo.isLowPowerModeEnabled` adaptation

**Our anchor:**
- `docs/knowledge/benchmarking/` — our measured numbers
- CLAUDE.md: "ModelProfile warm check must compare model binary (model + backend), NOT full profile"
- `SafeLock`, `ModelPool` for our thread-safe pooling
- No CoreML on whisper path (Metal-only; ANE consumers: WhisperKit, FluidAudio, MLX)

**Judgment axes:** idle RAM MB, peak RAM during transcription, idle CPU %, thermal fingerprint (fan spin on sustained use), cold-start time to first transcription.

---

## Dimension 9 — Packaging: Pricing, Permissions, Privacy, Distribution

**What to analyze:** How do they price and distribute? What's their privacy story? How do they handle permissions? What does their App Store presence look like?

**Evidence signals to look for:**
- Distribution: Mac App Store, direct download, or both
- Pricing model: one-time, subscription, freemium + IAP
- Free tier limits (if any)
- Privacy policy: what data leaves the device?
- Permission request flow: which permissions, in what order, how asked
- Sandbox status and entitlements (signals what they can/can't do)
- App Store category, rating, review count, last update
- Marketing copy: how do they describe offline vs online capability?

**Our anchor:**
- `docs/exec-plans/app-store-submission.md`
- Memory rules: NEVER frame as accessibility/disability tool; it's a productivity tool
- App Store rejection history: 4x Guideline 2.4.5, 1x Guideline 5.1.1(iv)
- Build configurations: Debug / Release (no sandbox) / AppStore (sandboxed, APP_STORE flag)
- Current version: 1.1 (6)

**Judgment axes:** pricing clarity and perceived value, privacy differentiation (offline = privacy win — are they claiming it?), permission UX (do they ask at the right time?), App Store compliance risk of their approach.

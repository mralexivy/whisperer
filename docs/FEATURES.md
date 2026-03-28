# Whisperer — Complete Feature Reference

**Native macOS menu bar app for offline voice-to-text transcription.**
Hold a key, speak, release — text appears wherever you're typing.

---

## Table of Contents

1. [Core Transcription](#1-core-transcription)
2. [Transcription Backends](#2-transcription-backends)
3. [Live Preview Engine](#3-live-preview-engine)
4. [Audio System](#4-audio-system)
5. [Text Delivery](#5-text-delivery)
6. [Keyboard Shortcuts & Recording Modes](#6-keyboard-shortcuts--recording-modes)
7. [AI Post-Processing (LLM)](#7-ai-post-processing-llm)
8. [Text Processing Pipeline](#8-text-processing-pipeline)
9. [Dictionary & Spell Correction](#9-dictionary--spell-correction)
10. [Prompt Words](#10-prompt-words)
11. [Transcription History (Workspace)](#11-transcription-history-workspace)
12. [File Transcription](#12-file-transcription)
13. [Usage Statistics](#13-usage-statistics)
14. [Transcription Picker](#14-transcription-picker)
15. [User Interface](#15-user-interface)
16. [Onboarding](#16-onboarding)
17. [Pro Pack (IAP)](#17-pro-pack-iap)
18. [System Integration](#18-system-integration)
19. [Diagnostics & Reliability](#19-diagnostics--reliability)
20. [App Store Dual-Build Architecture](#20-app-store-dual-build-architecture)

---

## 1. Core Transcription

### What It Does
Real-time speech-to-text transcription, 100% offline. All processing happens locally using Apple Silicon Metal GPU acceleration. No data leaves the device.

### How It Works
- Audio captured at system sample rate (typically 48kHz stereo), converted to 16kHz mono Float32 via `AVAudioConverter`
- Streaming transcription processes 2-second audio chunks with 0.5-second overlap during recording
- On key release, a **tail-only final pass** transcribes only the unprocessed audio after the last chunk (not the entire recording)
- Dictionary corrections applied to the combined streaming + tail output
- Final text injected into the focused text field of any app

### Technical Tricks
- **Tail-only final pass**: Only unprocessed audio after the last chunk is re-transcribed on stop, reducing final-pass latency by 10-15x compared to full re-transcription
- **Context carrying**: Last 100 characters of previous chunk passed as `initial_prompt` to the next chunk for better word continuity at boundaries
- **Deterministic greedy decoding**: `temperature=0.0`, `temperature_inc=0.0` — disables whisper.cpp's fallback ladder that retries decoding up to 6 times at increasing temperatures. Makes per-chunk latency predictable
- **P-core thread pinning**: On Apple Silicon, queries `hw.perflevel0.logicalcpu` to use only performance cores minus 2 (reserved for audio/UI). Efficiency cores cause straggler effects where P-cores wait for E-cores
- **GPU warm-up on model load**: A silent 1-second transcription runs after model load to compile Metal shaders, so the first real transcription has no shader compilation stall
- **stopAsync() over stop()**: Always uses `await transcriber.stopAsync()` which polls `isProcessing` until in-flight chunks complete. The synchronous `stop()` races with in-flight chunk completion handlers, reading stale `lastProcessedSampleIndex` and producing duplicated text
- **Silent recording detection**: VAD `hasSpeech()` check on each chunk — if no speech detected, the chunk is skipped entirely (no wasted GPU cycles)
- **Hallucination prevention**: Silent recordings (no speech detected by VAD) return empty string instead of being sent to whisper, which would hallucinate phantom transcription output

---

## 2. Transcription Backends

### Three Engines
Whisperer supports three transcription backends via a unified `TranscriptionBackend` protocol:

| Backend | Engine | Hardware | Languages | Notes |
|---------|--------|----------|-----------|-------|
| **Whisper** | whisper.cpp (vendored C library) | Metal GPU | 99+ languages | Default. Best accuracy and language coverage |
| **Parakeet** | FluidAudio (CoreML) | Apple Neural Engine | 25 languages (v3), English-only (v2) | Fastest on Apple Silicon. CTC vocabulary boosting |
| **Apple Speech** | SpeechAnalyzer (macOS 26+) | System ML | System languages | Native Apple framework. Requires Tahoe+ |

### Whisper Models

| Model | Size | Speed | Notes |
|-------|------|-------|-------|
| Tiny | 75 MB | Fastest | Quick, lower accuracy |
| Base | 142 MB | Fast | Good for simple dictation |
| Small | 466 MB | Medium | Balanced |
| Medium | 1.5 GB | Slow | High accuracy |
| Large V3 | 2.9 GB | Slowest | Maximum accuracy |
| Large V3 Turbo | 1.5 GB | Fast | 8x faster than Large V3 |
| **Large V3 Turbo Q5** | 547 MB | Fast | **Default** — best balance of speed, size, accuracy |
| Large V3 Q5 | 1.1 GB | Medium | Quantized, smaller file |
| Distil Large V3 | 756 MB | Very Fast | 6x faster than Large V3 |
| Distil Small (EN) | 166 MB | Very Fast | English only |

### Technical Tricks
- **Pre-loaded model**: Model stays in memory after first load (~500MB-1.5GB). Instant recording start with zero loading delay
- **Hot-swapping**: Change models without app restart — old bridge is released, new one loaded
- **Memory safety check**: Before loading, queries available system memory and warns if insufficient for the selected model
- **GPU fallback**: If Metal initialization fails, automatically retries with CPU-only mode
- **SafeLock threading**: whisper.cpp is not thread-safe. `SafeLock` (timeout-based NSLock) serializes access with 10s timeout on Apple Silicon, 60s on Intel. Prevents deadlocks while protecting against concurrent access
- **C string lifetime management**: All C strings passed to `whisper_full` are kept alive with nested `withCString` closures to prevent dangling pointer crashes
- **Parakeet dual-manager warm-up**: Both streaming and final-pass CoreML managers are warmed up during model load to prevent ANE compilation stalls during first recording
- **CTC vocabulary boosting** (Parakeet only): Dictionary entries and prompt words are compiled into CTC vocabulary models that bias Parakeet's decoder toward specific words at the acoustic level

---

## 3. Live Preview Engine

### What It Does
Shows transcribed text appearing in real-time during recording, before the final pass completes.

### How It Works
Two-tier system:
1. **EOU (End-of-Utterance) engine** (primary): Dedicated Parakeet EOU streaming model runs on Neural Engine, processing 320ms audio windows. Produces word-level partial transcripts with ~300ms latency
2. **StreamingTranscriber** (fallback): Uses the main transcription backend to process 2-second chunks. Used when EOU model is not available

### Technical Tricks
- **Neural Engine isolation**: EOU runs on ANE while the main transcription engine uses Metal GPU — no resource contention
- **Audio sample buffering**: Batches 5120 samples (320ms) before dispatching to reduce Task/actor overhead — ~4 audio callbacks per batch instead of dispatching every callback individually
- **Typewriter animation**: Text appears progressively in the UI via `TypewriterAnimator`, creating a natural "words appearing" effect
- **Keyword highlighting**: Dictionary corrections shown with color gradient highlighting in the live preview
- **Toggle setting**: Live preview can be disabled entirely to save resources (`liveTranscriptionEnabled`)

---

## 4. Audio System

### Recording
- **AVAudioEngine** capture with format conversion to 16kHz mono Float32
- **Real-time amplitude monitoring** for waveform visualization (20-bar display)
- **Configurable microphone selection** — choose from available input devices or use system default
- **5-minute recording limit** — hard cap at 4,800,000 samples (~19MB) prevents unbounded memory growth

### Audio Feedback
- **Start/stop sounds** — configurable sound effects (Tink/Pop default) with preview on change
- **System audio muting** — optionally mutes other audio during recording to prevent feedback loops
- Muting happens 300ms AFTER engine start to let the audio HAL stabilize (muting before causes HAL reconfiguration that unmutes ~1s into recording)

### Voice Activity Detection (VAD)
- **Silero VAD** — neural network speech detection (~2MB ONNX model)
- CPU-only processing to avoid GPU contention with Whisper
- Provides lightweight `hasSpeech()` probability check per chunk
- Optional — app works fine without it

### Device Recovery & Self-Healing
- **Continuous audio flow watchdog**: Detects when audio stops flowing mid-recording (mic disconnect, sleep/wake). Triggers recovery after 3 seconds of silence
- **Silence detection**: Counts consecutive silent audio callbacks. After ~1.5s of dead silence, triggers auto-recovery
- **Auto-recovery pipeline**: Tears down engine completely via `cleanupEngineState()`, resets to default device, waits 200ms, retries. Up to 5 recovery attempts
- **Device-alive monitoring**: CoreAudio property listener detects when recording device dies (e.g., monitor unplugged, AirPods disconnect). Fires immediately, unlike `AVAudioEngineConfigurationChange` which may be delayed
- **Sleep/wake recovery**: Handles stale audio device IDs after wake by detecting and recovering from dead devices
- **Format mismatch fix**: Uses `outputFormat` instead of `inputFormat` for the audio tap to avoid format mismatch crashes
- **Startup grace period**: 1.5-second window after recording start where `AVAudioEngineConfigurationChange` notifications are ignored (muting system audio triggers these)
- **Recording generation tracking**: Each `startRecording()` increments a generation counter. Stale retry tasks from previous recordings detect the mismatch and bail out

---

## 5. Text Delivery

### Two Modes (controlled by build configuration)

**Direct Distribution Build:**
1. **Accessibility API injection** (primary) — `AXUIElementSetAttributeValue` directly inserts text into focused field
2. **Clipboard + simulated Cmd+V** (fallback) — `CGEvent.post(tap: .cgAnnotatedSessionEventTap)` pastes, then restores previous clipboard content
3. **Clipboard-only** (if Accessibility denied) — copies to clipboard, shows notification for manual paste

**App Store Build:**
- **Clipboard-only** — always copies to clipboard. Animated green checkmark toast shows "Copied to Clipboard" with Cmd+V hint

### Technical Tricks
- **AX messaging timeout**: 100ms timeout set via `AXUIElementSetMessagingTimeout` on both app element and focused element. Prevents indefinite blocking if target app is hung
- **No background dispatch**: AX calls run inline on the calling thread. Dispatching to `DispatchQueue.global()` caused 2.4s+ delays from GCD queue contention
- **HUD dismissal before text injection**: State set to `.idle` BEFORE calling `insertText()` so the overlay fade-out animation runs concurrently with text injection
- **Clipboard restore timing**: 100ms delay after simulated paste before restoring previous clipboard content
- **Target app capture**: Frontmost app is captured BEFORE the recording overlay appears (it would steal focus otherwise)
- **Trailing space option**: Optional setting to append a trailing space after injected text so cursor is ready for the next word

---

## 6. Keyboard Shortcuts & Recording Modes

### Key Detection (App Store Compliant)
- **Fn key**: `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` detects Fn via `event.keyCode == 63`. Monitors modifier state changes, NOT keystrokes
- **Custom shortcuts**: Carbon `RegisterEventHotKey` for key+modifier combinations (e.g., Cmd+Shift+Space). Standard macOS hotkey mechanism
- **Combo detection**: Fn+key combos (like Fn+F1) cancel recording instead of processing audio — prevents accidental triggers

### Recording Modes
- **Hold-to-record** (default) — hold key to record, release to transcribe. Most natural interaction
- **Toggle mode** — press to start, press again to stop
- **Hands-free mode** (Fn+L) — starts recording with mic muted. Press Fn+L again to unmute and record until next Fn press. Shows toast notification

### Shortcut Configuration
- Custom key + modifier combinations via `ShortcutRecorderView`
- Fn key calibration — learns your keyboard's specific Fn key behavior
- Separate shortcut for rewrite mode (Option+Shift+Tab default)

### Technical Tricks
- **Fn release polling fallback**: A `DispatchSourceTimer` polls modifier flags as a safety net for Globe/Fn key edge cases where the release event might not fire
- **Carbon hotkey cleanup**: Proper `UnregisterEventHotKey` and `RemoveEventHandler` in teardown. `Unmanaged.passUnretained(self)` pointer must remain valid while handler is registered
- **Fn+L hands-free fix**: Carbon hotkey for "L" is registered only during Fn hold-to-record to prevent inserting "l" into focused text fields when Fn isn't held

---

## 7. AI Post-Processing (LLM)

### What It Does
On-device LLM processes transcribed text after whisper output. Rewrites, translates, formats, summarizes — all offline.

### Built-in AI Modes

| Mode | Purpose | Temperature |
|------|---------|-------------|
| **Rewrite** | Clean up transcribed speech into professional written text | 0.3 |
| **Translate** | Translate to target language | 0.1 |
| **Format** | Apply Markdown formatting (headers, bullets) | 0.2 |
| **Summarize** | Condense into key points | 0.3 |
| **Grammar** | Fix grammar/punctuation without changing meaning | 0.1 |
| **List Format** | Detect and format spoken lists | 0.1 |
| **Coding** | Rewrite as technical documentation or code comments | 0.2 |
| **Email** | Format as professional email with greeting/sign-off | 0.3 |
| **Creative** | Enhance with vivid, engaging language | 0.5 |
| **Custom** | User-defined system prompt | 0.3 |

### Rewrite Mode (Direct Distribution only)
- Triggered by rewrite shortcut (Option+Shift+Tab)
- Reads clipboard text, processes through active AI mode, replaces with result
- No recording needed — rewrites existing text

### AI Enhancement History
- Before/after stored in CoreData for each transcription
- Undo support — revert to original transcription

### Technical Tricks
- **LLM model hot-swap**: 500ms delay between unload and load to let ARC release GPU buffers
- **Memory logging**: Logs process memory before and after LLM load/unload to track resource usage
- **Context-aware corrections**: AI modes fix words that are clearly wrong based on surrounding context (e.g., "improved" → "approved" when context is about approval)
- **Graceful fallback**: If LLM processing fails, returns original transcription text unchanged
- **Skip empty content**: AI post-processing is skipped for text with no letter characters (silence/hallucination artifacts)

---

## 8. Text Processing Pipeline

Full pipeline applied to transcribed text before delivery:

```
Whisper/Parakeet/Apple Speech output
    |
    v
Dictionary corrections (SymSpell + phonetic + exact match)
    |
    v
Filler word removal (optional: "um", "uh", "erm", "er", "ah", "hmm")
    |
    v
List formatting (optional: deterministic engine + optional LLM fallback)
    |
    v
AI post-processing (optional: active AI mode applied)
    |
    v
Trailing space (optional)
    |
    v
Text injection into focused field
```

### List Formatting Engine
Deterministic (non-AI) list detector that converts spoken enumerations to proper formatted lists:

- Detects multiple marker types: spoken ordinals ("first", "second"), cardinals ("one", "two"), digits, "number X" phrases, bullet triggers ("bullet point", "dash")
- 5 detection strategies tried in order: prefixed groups, number-anchored runs, boundary markers, ordinal sequences, sequential digits
- Strips preamble fillers ("sorry", "okay", "hold on") before lists
- Strips trailing commentary ("and that's it", "done", "yeah")
- Extensive false-positive prevention with 60+ blocked preceding words ("have two", "about three" not treated as list markers)
- Optional LLM fallback when deterministic engine finds nothing

### Filler Word Removal
Word-boundary matching removes "um", "uh", "erm", "er", "ah", "hmm". Preserves words containing fillers as substrings (e.g., "umbrella" is not affected).

---

## 9. Dictionary & Spell Correction

### Correction Engine
Three-tier matching system applied to every transcription:

1. **Exact lookup** — O(1) HashMap for single-word corrections
2. **Phrase lookup** — Multi-word phrase matching
3. **SymSpell fuzzy matching** — Edit distance-based (configurable 0-3 distance, default 2). Uses prefix-based indexing for high performance
4. **Phonetic matching** — Catches homophones and similar-sounding words (e.g., "their"/"there"/"they're")

### Dictionary Packs
- Premium bundled correction databases
- Per-pack enable/disable
- Version tracking with automatic updates

### Custom Entries
- User-defined corrections with incorrect → correct form mapping
- Categories for organization
- Per-entry enable/disable toggle
- Usage tracking (counts how often each correction is applied)
- Import/export as JSON

### Technical Tricks
- **Spell validator gate**: SymSpell fuzzy matches are validated against a spell checker — valid English words are not "corrected" by fuzzy matching
- **Word boundary checks**: Corrections only apply at word boundaries, preventing partial-word replacements
- **Highlighted corrections**: In live preview, corrected words are shown with gradient color highlighting. Clicking shows the original word
- **Thread-safe rebuild**: Dictionary rebuilds are thread-safe and trigger reconfiguration of CTC vocabulary boosting on Parakeet

---

## 10. Prompt Words

### What It Does
Biases transcription toward specific vocabulary — proper nouns, technical terms, brand names that Whisper might otherwise mishear.

### How It Works
- **Whisper backend**: Words joined as comma-separated string and passed as `initial_prompt`. Whisper treats this as "previous context" and biases recognition toward these words
- **Parakeet backend**: Words compiled into CTC vocabulary models that boost probability at the acoustic decoder level

### Technical Tricks
- **Token limit enforcement**: Hard limit of 224 tokens (~4 chars/token) — whisper.cpp model architecture constraint
- **Approximate token counting**: `ceil(totalChars / 4)` including separators
- **Case-insensitive deduplication**: Prevents adding duplicate words
- **ABC sorting** in UI for easy scanning
- **Clear-all confirmation** to prevent accidental deletion
- **Auto-reconfigure on change**: Dictionary rebuilds and prompt word changes trigger live reconfiguration of vocabulary boosting

---

## 11. Transcription History (Workspace)

### Workspace Window
Custom `HStack(spacing: 0)` layout with collapsible sidebar (220pt). Window: 1100x750 default, 700x700 min. Fullscreen support with Ctrl+Cmd+F shortcut.

### History Features
- **CoreData persistence** — all transcriptions saved locally with full metadata
- **Full-text search** across transcription text and notes
- **Filter tabs**: All, Pinned, Flagged (colorful capsule tabs)
- **Pin/Flag** — mark important transcriptions
- **Edit** — modify transcription text inline
- **Notes** — add context or annotations
- **Audio playback** — listen to original recordings with variable speed (persisted preference)
- **"Show in Finder"** — reveal audio file in Finder
- **Waveform visualization** — generated from saved audio data
- **Re-transcribe** — re-process audio with different settings, inline language picker
- **Copy and Clear** — combined into single button in menu bar view
- **AI enhancement history** — before/after text with undo

### Metadata per Recording
- Duration, word count, words-per-minute
- Language used (detected or selected)
- Model used for transcription
- Target app name (where text was inserted)
- Dictionary corrections applied
- Colorful metadata pills: WPM (orange), Words (blue), Language (red)

### Technical Tricks
- **Date section headers** — transcriptions grouped by Today, Yesterday, Last 7 Days, Last 30 Days, Older
- **Sidebar stat card** — gradient card showing total recordings, words, duration, average WPM with per-stat colors
- **Detail panel resize fix** — fixed flickering during panel resize
- **Tahoe compositing fix** — removed `clipShape` modifiers that caused text compositing bugs on macOS Tahoe

---

## 12. File Transcription

### What It Does
Transcribe audio/video files from disk using the loaded model. Drag-and-drop or file picker interface.

### How It Works
- Uses the pre-loaded transcription backend (same model as live recording)
- Processes the entire file through the backend
- Results displayed in workspace with copy support

---

## 13. Usage Statistics

### Dashboard Cards
- **Total recordings** count
- **Total words** transcribed
- **Total recording duration**
- **Average words per minute**

### Charts & Visualizations
- **Daily activity chart** — bar chart with Words/Time/Sessions metric selector
- **App usage card** — which apps received transcribed text
- **Languages card** — language distribution
- **Peak hours card** — heatmap of recording activity by hour
- **Period selector** — Week, Month, Year views
- **Weekly grouping** for year view with better label formatting

---

## 14. Transcription Picker

### What It Does
Quick-access overlay showing recent transcriptions for clipboard copy. Activated with Option+V.

### How It Works
- Floating overlay panel appears showing last N transcriptions
- Cycle through items with repeated Option+V presses
- Confirm selection to copy to clipboard
- Shows "Copied" feedback overlay

---

## 15. User Interface

### Menu Bar App
- **Accessory mode** — no dock icon, lives in menu bar only
- **3-tab layout**: Status (waveform icon, blue), Models (CPU icon, orange), Settings (gear icon, red)
- **Status display**: Ready, Listening, Transcribing with animated indicators
- **Model badge**: Shows loaded model name and status
- **Dynamic greetings**: Time-of-day based greeting
- **Daily quotes**: Rotating inspirational quotes about voice and capture
- **Flat dark window chrome** via `MenuBarWindowConfigurator` NSViewRepresentable

### Recording Overlay (HUD)
- **NSPanel** — borderless, non-activating (`nonactivatingPanel`), no shadow, `canJoinAllSpaces`
- **Never steals focus** — uses `.orderFront()`, never `.makeKeyAndOrderFront()`
- Navy capsule background (#14142B) with blue accent elements
- **Recording indicator**: Blue pulsing circle (44x44) with animated dot
- **Waveform visualization**: 20 animated bars showing real-time audio amplitude
- **Live transcription card**: Speech bubble with typewriter animation
- **Processing state**: 4 animated gradient bars (blue to purple)
- **Target app icon**: Shows the app where text will be inserted
- **Multi-screen support**: Positions correctly on non-primary screens
- **Model loading toast**: "Loading model..." shown when recording pressed before model ready
- **Clipboard toast**: Animated green checkmark with "Copied to Clipboard" and Cmd+V keycap

### Unified Dark Navy Theme
- Always-dark appearance across all windows — no light mode
- Background layering: sidebar (#0A0A18) → main (#0C0C1A) → cards (#14142B) → elevated (#1C1C3A)
- Blue-purple gradient accents (#5B6CF7 → #8B5CF6)
- Per-element colorful icons in tinted rounded rectangles
- SF Rounded for titles and stat values, default for body text
- Flat window chrome — transparent titlebar, navy background, no shadow, no system border

---

## 16. Onboarding

### Four-Page Guided Setup
1. **Welcome** — Full-width splash with app icon (120x120), gradient hero title (40pt), animated feature pills
2. **Permissions** — Microphone permission request (informational, not directive)
3. **System-Wide Dictation** — Enable global keyboard shortcut
4. **Features** — Feature overview and model download

### Technical Tricks
- **Borderless floating window**: 860x540, `NSWindow` with `level = .floating`, `hasShadow = true`, corner radius 20
- **Two-column layout** (pages 1-3): Left content + right decorative panel (340pt) with concentric circles and radial gradients
- **App Store compliance**: No "Grant" buttons. No "Set Up Later" skip buttons. All text is informational, not directive
- **Sets `hasCompletedOnboarding`** in UserDefaults — shown only on first launch
- **User is recording-ready** when onboarding completes

---

## 17. Pro Pack (IAP)

### StoreKit 2 Integration
- Product ID: `com.ivy.whisperer.propack`
- Non-consumable in-app purchase
- Purchase UI with gradient CTA button
- Restore Purchases support

### Receipt Validation
- App Store receipt validated on launch
- Exits with code 173 on failure (triggers receipt refresh)
- Only runs in Release builds

---

## 18. System Integration

### Permissions
- **Microphone** — required for recording (`NSMicrophoneUsageDescription`)
- **Accessibility** — optional, for direct text injection (Direct Distribution only; completely removed from App Store binary)
- **System-wide dictation** — opt-in toggle (default OFF) for global keyboard shortcut

### Launch at Login
- Configurable via Settings

### Audio Device Management
- `AudioDeviceManager` singleton monitors system audio devices
- Detects device add/remove/change events
- Remembers user's preferred device across sessions (`preferredDeviceUID`)
- Falls back to system default when preferred device unavailable

### Graceful Shutdown
- Ordered resource release: streaming transcriber → live preview engine → VAD → transcription bridge → LLM → CTC models
- `prepareForShutdown()` on all bridges prevents new work during teardown
- `whisper_free()` called under SafeLock with 2s timeout
- Queue drain (`queue.sync {}`) ensures in-flight operations complete

---

## 19. Diagnostics & Reliability

### Logging
- **Structured logging** via `Logger` static methods (debug/info/warning/error/critical)
- **Subsystems**: `.app`, `.audio`, `.transcription`, `.ui`, `.keyListener`, `.textInjection`, `.permissions`, `.model`
- **Daily log rotation** — new log file each day
- **No `print()` statements** — all output through Logger

### Crash Handling
- `CrashHandler` installed at launch
- **Crash log detection** — notifies if previous crash occurred
- **Auto-expire indicator** — crash notification dismissed after 24 hours
- Log files at `~/Library/Logs/Whisperer/`

### Queue Health Monitoring
- `QueueHealthMonitor` detects hung operations on monitored dispatch queues
- WhisperBridge registers its transcription queue for monitoring

### State Watchdogs
Three independent watchdogs prevent the UI from getting stuck:

1. **Startup watchdog** (4s) — forces idle if audio engine fails to start
2. **Recording watchdog** (repeating 10s) — catches stuck `.recording` state after 5.5 minutes
3. **Stop watchdog** (activity-aware) — forces idle after 5s of zero transcription/LLM activity OR 20s absolute timeout

All use `DispatchSourceTimer` on the main RunLoop — independent of Swift's cooperative thread pool. Even if all cooperative threads are exhausted, these fire.

### Memory Management
- `[weak self]` in all `Task.detached` closures and stored callbacks
- `autoreleasepool` for audio callbacks
- NotificationCenter observers removed in `deinit`
- System memory check before model load
- Memory usage logged at key lifecycle points

---

## 20. App Store Dual-Build Architecture

### Three Build Configurations

| Config | `APP_STORE` flag | Sandbox | Purpose |
|--------|-----------------|---------|---------|
| **Debug** | No | No | Development |
| **Release** | No | No | Local distribution (`/local` command) |
| **AppStore** | Yes | Yes | App Store submission (`/release` command) |

### What's Removed in App Store Build (`#if !APP_STORE`)
- All Accessibility APIs (`AXIsProcessTrusted`, `AXUIElement*`, `CGEvent.post`)
- Auto-paste toggle and UI
- `TextSelectionService` (entire file)
- Rewrite mode (sidebar, overlay, shortcut callbacks)
- AI Post-Processing settings in menu bar
- Command Mode (sidebar + related files)
- Feedback (workspace sidebar)
- All "assistive" framing strings

### What's Added in App Store Build
- **Clipboard toast** — animated green checkmark with "Copied to Clipboard" and Cmd+V keycap hint
- **Clipboard-only `insertText()`** — always copies to clipboard + posts notification

### Compliance
- **Guideline 2.4.5**: Zero AX code in App Store binary. Verified with `/usr/bin/strings` binary scan
- **Guideline 5.1.1(iv)**: No directive permission language ("Grant", "Set Up Later"). All text informational
- **Export compliance**: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only)
- **Privacy**: "Data Not Collected" — 100% offline, no telemetry
- **Sandbox entitlements**: audio-input, network.client (model downloads), files.user-selected.read-write
- **arm64 only**: FluidAudio dependency fails on x86_64 (Float16 issue)

---

## Settings Reference

| Setting | Default | Storage |
|---------|---------|---------|
| Transcription language | English | UserDefaults |
| Whisper model | Large V3 Turbo Q5 | UserDefaults |
| Transcription backend | whisper.cpp | UserDefaults |
| Recording mode | Hold-to-record | UserDefaults |
| Keyboard shortcut | Fn key | UserDefaults |
| Mute other audio | ON | UserDefaults |
| Live transcription preview | ON | UserDefaults |
| Save recordings | ON | UserDefaults |
| Dictionary enabled | ON | UserDefaults |
| Fuzzy matching sensitivity | 2 | UserDefaults |
| Phonetic matching | ON | UserDefaults |
| Prompt words enabled | ON | UserDefaults |
| Filler word removal | OFF | UserDefaults |
| List formatting | OFF | UserDefaults |
| List formatting AI | OFF | UserDefaults |
| AI post-processing | OFF | UserDefaults |
| Append trailing space | OFF | UserDefaults |
| System-wide dictation | OFF | UserDefaults |
| Auto-paste (non-App Store) | OFF | UserDefaults |
| Launch at login | OFF | UserDefaults |
| Sound feedback | Default | UserDefaults |
| Playback speed | 1.0x | UserDefaults |

---

## Data Storage

| Data | Storage | Location |
|------|---------|----------|
| Transcription history | CoreData | `WhispererHistory.xcdatamodeld` |
| Dictionary entries | CoreData | `DictionaryEntryEntity` |
| User preferences | UserDefaults | Standard |
| Audio recordings | File system | `~/Library/Application Support/Whisperer/Recordings/` |
| Whisper models | File system | `~/Library/Application Support/Whisperer/` |
| Parakeet models | File system | `~/Library/Application Support/FluidAudio/Models/` |
| Logs | File system | `~/Library/Logs/Whisperer/` |

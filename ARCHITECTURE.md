# Whisperer Architecture

## Entry Point & State Machine

**WhispererApp.swift** — `@main` SwiftUI app using `MenuBarExtra` (no dock icon, `.accessory` activation policy). Uses `@NSApplicationDelegateAdaptor` for `AppDelegate` which initializes all components. Also contains `MBColors` (menu bar color palette), `MenuBarWindowConfigurator` (NSViewRepresentable for flat window chrome), and all menu bar tab views.

**AppState.swift** — `@MainActor` singleton (`AppState.shared`) managing the recording state machine:

```
idle → recording(startTime) → stopping → transcribing(audioPath) → inserting(text) → idle
                                                                                  ↗
                                          downloadingModel(progress) ─────────────
```

**Why singleton?** Menu bar apps need centralized coordination. Multiple recording sources (Fn key, UI button) must sync through one truth source.

## Audio Pipeline

```
Microphone → AudioRecorder → StreamingTranscriber → WhisperBridge → CorrectionEngine → TextInjector
                 ↓                    ↓
            Waveform UI          Live Preview
```

- **AudioRecorder** — `AVAudioEngine` capture, converts to 16kHz mono Float32. Streams samples via `onStreamingSamples` callback, and in parallel encodes them to Ogg Opus on `sessionWriteQueue` (see [Audio Storage](#audio-storage--one-format-and-something-that-deletes)).
- **StreamingTranscriber** — Buffers audio, processes 2s chunks with 0.5s overlap (single-segment mode for speed). Context carrying + deduplication. Tail-only final pass on stop (only transcribes unprocessed audio after the last chunk, not the entire recording).
- **WhisperBridge** — Swift wrapper around whisper.cpp C library. Manages `whisper_context` lifecycle, Metal GPU acceleration. Thread-safe with SafeLock. Uses deterministic greedy decoding (temperature=0, no fallback ladder) and performance-core-aware thread count.
- **SileroVAD** — Optional Silero voice activity detection (~2MB model, CPU-only to avoid GPU contention). Provides both full segment detection and lightweight `hasSpeech()` probability check.

## Language Routing Pipeline

When multiple languages are configured, audio goes through a detection pipeline before transcription:

```
Audio → VAD filter → WhisperBridge.detectLanguage (shared tiny model, CPU)
                         ↓ probabilities
                    LanguageRouter (shortlist filter + state machine)
                         ↓ language decision
                    ModelRouter → ModelPool (warm/cold backend selection)
                         ↓ TranscriptionBackend
                    StreamingTranscriber (transcribe with fixed language)
```

- **Language detection** — Shared `previewBridge` (tiny model, CPU-only) in ModelPool. Uses `whisper_pcm_to_mel()` → `whisper_lang_auto_detect()` via `WhisperBridge.detectLanguage()`. Same context handles both live preview and detection, serialized via `ctxLock`. whisper.cpp has no built-in shortlist — filtering happens in LanguageRouter.
- **LanguageRouter** — State machine (undecided → locked → suspectedSwitch). Filters probabilities to allowed languages, applies composite scoring (probability + script hints + priors), requires confidence threshold to lock. Confidence-gated fast path for short detection windows.
- **ScriptAnalyzer** — Unicode script-family detection (Latin, Cyrillic, Hebrew, Arabic, CJK, etc.) from transcript text. Maps scripts to candidate languages filtered by the allowed shortlist. Heuristic support only — script ≠ language.
- **ModelPool** — Manages preview/detector bridge, fallback, and target whisper_context instances. Warm backends serve instantly; cold targets use fallback while loading async.

For full details, see [docs/references/language-routing.md](docs/references/language-routing.md).

## Live Transcription

Live text appears during recording via two sources:

1. **Preview pass** (tiny model, separate context) — runs every 1s, transcribes newest audio since last pass, appends to `previewAccumulatedText`. Provides text before VAD chunks finalize.
2. **Chunk `onNewSegment`** (main model) — fires word-by-word during VAD chunk transcription. Provides fine-grained live text when chunks are being processed.

### Preview Architecture (append-only)
- **`previewBridge`** — Shared `WhisperBridge` instance (tiny model, CPU-only) in `ModelPool`. Also handles language detection. Runs on its own serial queue. CPU-only = zero GPU contention with main model and UI rendering.
- **Append-only** — Each preview pass transcribes only NEW audio (with 0.5s overlap for boundary quality). Deduplicates overlap words, then appends. Text never shrinks. `SmoothTextUpdater.hasPrefix` always succeeds → smooth word-by-word animation.
- **`previewPassID`** — Monotonic ordering prevents out-of-order callbacks from corrupting accumulated text.
- **Detection-gated** — Preview waits for `routeDecision != nil` (or 5s timeout) before starting. Prevents wrong-language preview.
- **Chunk handoff** — When VAD chunk finalizes, `previewAccumulatedText` is cleared and `lastPreviewedSampleIndex` resets. Main model's high-quality text replaces preview.

### Display
- `completedChunkTexts.joined(" ") + " " + previewAccumulatedText` — stable chunks + live tail
- `SmoothTextUpdater` animates words 60ms apart (LTR) or shows immediately (RTL)
- `TranscriptionTextView` (NSTextField via NSViewRepresentable) renders text for guaranteed RTL paragraph direction
- `.id(recordingSessionID)` on LiveTranscriptionCard forces full SwiftUI state reset between recordings (including expand/collapse state)

## Meeting Notes System

### Overview

Meeting Notes is a separate recording mode layered on top of the existing whisper pipeline. Key distinction from standard dictation: chunks go to `MeetingManager` (CoreData) instead of `HistoryManager`, and text injection is suppressed.

### Component Chain

```
MeetingEngines.shared (preparation layer — downloads + warms all four engines)
    ↓ MeetingPrepView shown when needsPreparation (readiness-driven, not a "seen it" flag)

MeetingDetector (hardware events + fallback poll, watches mic/camera/known apps)
    ↓ AppState.showMeetingNotification(app:)
MeetingNotificationCard (toast) → user taps "Start Recording"
    ↓ MeetingSession.startRecording(title:) → AppState.startMeetingRecording(session:)
    ↓ startInAppRecording() (isInAppMode=true, text injection suppressed)
    ↓ StreamingTranscriber.onChunkCompleted routed to MeetingSession.onNewChunk()
    ↓ [segment flush rules: 30s audio-time cap, 1.2s silence gap, 2.5s idle, or on stop]
MeetingManager.appendSegment() → CoreData (segmentsJSON blob)
    ↓ MeetingSession.stopRecording() → moves audio file Sessions/ → Meetings/
    ↓ MeetingManager.finalizeSession()
    ↓ MeetingTranscriptRefiner (cleanup — re-transcribes with Whisperer V3 for accuracy)
    ↓ MeetingAIService.generateTitle()
    ↓ MeetingAIService.generateOverview()
    ↓
Meeting Studio UI (MeetingStudioView, 3-column)
```

### Meeting Engine Set

`@MainActor final class MeetingEngines: ObservableObject` (singleton at `MeetingEngines.shared`) owns
the download and warm lifecycle for the four model engines meeting features depend on:

| Engine | Role | Model | Residency |
|---|---|---|---|
| `.speech` | Live transcription (ASR) | Nemotron (~1.5 GB) | Resident for the duration of a meeting — it IS the live pipeline |
| `.cleanup` | Post-stop re-transcription | Whisperer V3 / `largeTurboQ5` (~547 MB) | Load per pass, free in `defer` |
| `.intelligence` | Title, overview, Ask AI | Qwen3.5-4B MTP (~3.2 GB) | Load per pass via `borrowLLM()`, 60s idle unload |
| `.speakers` | Speaker diarization | Sortformer (~330 MB) | Delegated entirely to `MeetingDiarizerService` |

**Readiness state** — `readiness: [MeetingEngine: EngineReadiness]` is a single published snapshot.
`EngineReadiness` is: `.ready`, `.needsDownload(String)`, `.downloading(Double)`, `.preparing`,
`.unavailable(String)`. `needsPreparation: Bool` is true when any engine is not `.ready`.
`overallProgress: Double` is weighted by `downloadBytes` so the bar tracks actual download work.

**`prefetch()`** — idempotent. Called on every app launch (if meetings exist) and on detection events.
Starts a background `Task.detached` per non-ready engine; guards against double-submission with
`engineTasks[engine]`.

**`borrowLLM()` / `releaseLLM()`** — refcounted access to the intelligence model. `borrowLLM()` loads
inside a `ModelWorkQueue` slot; `releaseLLM()` schedules an unload after 60 seconds of idle time.
Multiple callers (`MeetingAIService.ask`, `generateTitle`, `generateOverview`) share one instance.

### Meeting Onboarding

`MeetingPrepView` is a full-window onboarding screen shown in `MeetingStudioView` when
`engines.needsPreparation && !continueAnyway`. It displays a sonar animation with a `sparkles`
icon, one row per engine with its state indicator (download progress, preparing spinner, or ready
checkmark), a weighted progress rail, and a gated CTA that becomes active only when all engines are
ready. The screen is **readiness-driven, not flag-driven** — it reappears whenever a model is
deleted, ensuring the UI accurately reflects what is on disk rather than what the user last saw.

### Storage

| What | Where | Format |
|---|---|---|
| Meeting metadata, segments, AI summary | CoreData `MeetingEntity` | JSON blobs in string columns |
| Audio (intermediate) | `~/Library/Application Support/Whisperer/Sessions/<uuid>.opus` | Ogg Opus, written live by the recorder |
| Audio (final, after stop) | `…/Meetings/<uuid>.opus` | same file, moved by `MeetingSession.stopRecording` — no transcode |
| Chat history | `…/Meetings/<uuid>-chat.json` | JSON array of `MeetingChatMessage` |

### MeetingDetector

`@MainActor final class MeetingDetector` (singleton). Watches hardware signals (mic + camera) and running apps to detect meetings. Two-stage debounce: 800ms hardware callback → 500ms confirmation → `AppState.showMeetingNotification`. Also runs a 5-second fallback poll to catch browser meetings and Bluetooth mic quirks.

**Detection mechanism:**
- `CameraUsageMonitor` — CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` property listener.
- `MicrophoneUsageMonitor` — CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on all input devices.
- Native app providers: Zoom, Teams, Webex, FaceTime (by bundle ID).
- Browser detection (not in App Store build — `#if !APP_STORE`): reads window titles via AX API for Chrome, Safari, Arc, Firefox, Edge, Brave, Opera, Slack; matches Meet, Hangouts, Teams web, Zoom web, Webex, Whereby, Around, Slack Huddle patterns.

**Confidence scoring:** mic+camera=0.60, camera-only=0.35, mic-only=0.30; bonuses for running (+0.15), frontmost (+0.15), recently activated (+0.10), browser window match (+0.30); penalty for known non-meeting apps (−0.60). Threshold: 0.45.

**Suppression guards:**
- Per-app refire cooldown: 30 minutes.
- Suppressed while Whisperer itself is recording (`AppState.state != .idle`).
- `meetingDetectionEnabled` UserDefaults key (defaults true).
- User dismissing toast → `suppressedUntilHardwareIdle`; clears when hardware goes idle or the app quits.

### MeetingSession

`@MainActor ObservableObject`. Holds all ephemeral live-recording state. Lives in `MeetingStudioView` as a `@StateObject`; `AppState` references it via `activeMeetingSession`.

**Published state:** `meetingID`, `segments`, `notes`, `isRecording`, `elapsedSeconds`, `livePreviewText` (gray tail from `onPreviewTail`), `currentSegmentText`, `currentSegmentStartTimestamp`.

**Segment flushing rules** — all boundaries are placed on the **audio clock** (`TranscriptChunk.start`/`.end` = `samplesReceived / sampleRate`), never on wall-clock or `elapsedSeconds`, so transcript cards line up with the recorded `.opus` during playback scrubbing:

- **Silence-based**: a chunk whose `start` is ≥ `silenceSplitGap` (1.2s) after the previous chunk's `end` closes the current segment at that previous `end`. For VAD-segmented backends the chunk span is the exact voiced range, so this gap is genuine silence.
- **Time-based**: `end - currentSegmentStartTimestamp` ≥ `maxSegmentDuration` (30s) → flush.
- **Idle-based**: 2.5s after the last chunk with none arriving, flush at `lastChunkEndTimestamp`. The gap rule above only fires when the *next* chunk lands, so this is what closes a card during a long pause. **Only on the whisper VAD-chunk path** (`accumulate(idleFlushTracksSpeech: true)`) — see below.
- **Stop-based**: `stopRecording()` flushes remaining text (including `livePreviewText`) as the final segment.
- **Post-hoc split**: `flushCurrentSegment()` runs the text through `MeetingSession.splitByDuration()`, which subdivides any span longer than 30s at sentence boundaries (word boundaries when unpunctuated), assigning each piece start/end proportionally to its character share.

**Arrival time is not speech time.** The idle rule assumes a gap in chunk *arrival* means the speaker stopped. That holds for whisper.cpp, which emits one chunk per voiced VAD segment, and is false for the Nemotron + Sortformer path: `MeetingSpeakerCoordinator` withholds text until Sortformer's finalized timeline covers it, and `DiarizerTimeline.updateSegments` only finalizes a turn when the turn *closes*. During an unbroken monologue the timeline stalls and text is released in bursts at every micro-breath — so the idle timer fired between bursts and chopped a 48s continuous recording into seven 2–9s cards with no audio-time gap between them. `onAttributedText` therefore passes `idleFlushTracksSpeech: false` and the card stays open until a real audio-clock gap, the 30s cap, or a speaker change closes it. Nothing is at risk while it is open: the live bubble renders `currentSegmentText` and every `accumulate` writes it to `MeetingPendingStore`.

The split step is not redundant with the cap: chunk cadence is a property of the backend, not of the speech. whisper.cpp emits one chunk per voiced VAD segment, WhisperKit commits roughly every 6s, and **Nemotron returns the entire session as a single chunk at stop**. Arrival-driven rules alone leave that last case as one unreadable card.

`onNewChunk(text:start:end:)` clamps to `max(0, start)` / `max(chunkStart, end)` — an out-of-order span would otherwise produce a card that runs backwards. When it fires with `isRecording == false` (the tail delivered while `stopInAppRecording()`'s Task is still running), it drains immediately via `drainTailChunk()`, deduping against the last committed segment with `VADSegmenter.deduplicateOverlap` since `stopRecording()` already committed the overlapping `livePreviewText`.

**`chunkGeneration`** — integer incremented at every `startRecording()` call. The `onChunkCompleted` closure captures it and rejects any chunk whose generation doesn't match, preventing stale chunks from a previous session from leaking into the new one.

**Audio file lifecycle:** `stopRecording()` moves the session audio file from `Whisperer/Sessions/<filename>` to `Whisperer/Meetings/<filename>` so `MeetingRecord.resolvedAudioURL` finds it, then calls `MeetingManager.finalizeSession()`.

**AI trigger:** After stop, a detached Task calls `MeetingAIService.shared.generateTitle(segments:meetingID:currentTitle:)` then `generateOverview(segments:meetingID:)` (both skipped if the transcript is empty). `currentTitle` is read from `MeetingManager.shared.meetings` rather than the value passed to `startRecording()`, so a rename made during the recording is respected.

### Chunk Routing in AppState

`StreamingTranscriber.onChunkCompleted` delivers a `TranscriptChunk { text, start, end, recordedDuration }`. All five emit sites (whisper.cpp VAD chunk, WhisperKit eager commit, `transcribeTail()`, Nemotron single-blob, `appendTailTranscription()`) supply a real audio-time span derived from sample indices — `recordedDuration` alone is not enough to segment on.

```swift
// onChunkCompleted closure captures session + generation at wiring time
if let meetingSession = activeMeetingSession ?? capturedMeetingSession {
    guard meetingSession.chunkGeneration == capturedGeneration else { return }
    meetingSession.onNewChunk(text: chunk.text, start: chunk.start, end: chunk.end)
    return
}
// else: normal history path — HistoryManager.appendChunk(totalDuration: chunk.recordedDuration)
```

`activeMeetingSession` is nilled inside `stopInAppRecording()`'s async Task **after** `transcriber.stopAsync()` completes, so the tail chunk routes to the meeting session before teardown. The `capturedMeetingSession` safety net covers the window between nil-assignment and tail delivery.

`isMeetingStopInFlight` flag prevents the tail chunk from being treated as a normal history chunk during the async stop.

### Ask AI

`MeetingAIService.ask(question:meetingID:)` answers questions using the **whole transcript** as the LLM
system prompt, with the KV cache pre-filled once per meeting (`reuseWarmCache: true`). The entire
transcript is formatted as `"[Ns] Speaker: text"` per segment so the model has timestamps to cite.
After generation, `parseCitations(from:segments:)` extracts `[Ns]` patterns from the response and maps
them to `RAGChunk` values with `startTimestamp` + `endTimestamp`, which `AskAIPane` renders as source
citation chips (tap → scroll to timestamp). Chat history is persisted per meeting as
`<uuid>-chat.json` by `MeetingChatStore`. No external index or embedding model is involved — the
whole transcript fits the LLM context and the KV cache makes repeated questions in the same meeting
fast.

### AI Title Generation

`MeetingAIService.generateTitle(segments:meetingID:currentTitle:)` names a recording from its content. Runs **before** `generateOverview()` on both paths (`MeetingSession.stopRecording()` and the Overview tab's regenerate button) — it is a ~32-token generation, so the library row picks up a real name in a couple of seconds instead of waiting out the summary pass.

- **Guarded by `isAutoGeneratedTitle()`** — only replaces titles the app produced: `Note <date>` / `Meeting <date>` prefixes, or a bare provider display name from `MeetingDetector` (Zoom, Microsoft Teams, Google Meet, …). Anything the user typed is left alone.
- **Input is head+tail** (first 1600 + last 500 chars). The opening states the subject, the close usually states the conclusion; the middle rarely changes what to call it.
- **`sanitizeTitle()`** takes the first non-empty line and strips the decorations small on-device models add (a `TITLE:` label, quotes, markdown, trailing punctuation), caps at 70 chars, and rejects output that is itself auto-title-shaped.
- On success: `MeetingManager.updateTitle()` (updates CoreData + `MeetingListItem`) then posts `.meetingTitleDidGenerate`. `MeetingDetailView` caches the title in `@State editableTitle` and only re-reads it on meeting-ID change, so it **needs** that notification to refresh the header field.

### AI Overview Generation

`MeetingAIService.generateOverview(segments:meetingID:)` takes segments (not a flat string) and builds a **timestamped transcript** — `[95s] Speaker 1: text` per line. Without those markers the model has no timestamps to cite and fabricates the seconds fields in TOPIC/DECISION/OPEN.

Two prompts, chosen by word count:

| Kind | Trigger | Prompt | outputTokensHint | timeout |
|---|---|---|---|---|
| Note | < 60 words | `notePrompt` — OVERVIEW line only, 2-3 sentences | 200 | 30s |
| Full | ≥ 60 words | `overviewPrompt` — 250-350 word OVERVIEW + conditional labels | 1200 | 120s |

Both use temperature=0.15, repetitionPenalty=1.15, maxTokensCap=2048. Raw output is parsed by `MeetingOverviewParser.parse()`.

**Prompt design notes** — the earlier "OVERVIEW: one paragraph (2-4 sentences)" instruction produced summaries that named a topic without saying what was said about it, and the "if this is a real meeting with multiple speakers" branch made the model invent decisions and action items for lectures and solo notes. The current prompt instead: (a) spends most of its length on OVERVIEW, demanding 250-350 words across 2-4 paragraphs with the specifics kept (names, numbers, definitions, examples) and banning "The speaker discusses…" openers; (b) states that DECISION / OPEN / NEXT / ACTION apply to real discussions and that omitting them is the correct answer for a monologue. Speaker count is not used to classify the recording; the prompt makes the model decide from content instead. That was originally forced — before Sortformer landed, every segment was `Speaker 1` — but it stays deliberate now that diarization exists: a lecture with an audience question and a two-person meeting both report two speakers, so the count still does not separate a monologue from a discussion.

**`MeetingOverviewParser`** uses a custom line/pipe-delimited format (not JSON) — intentionally more robust against on-device LLM syntax errors and truncated output:
```
OVERVIEW: <text, may span multiple paragraphs>
TOPIC: <text> | <seconds>
DECISION: <label> | <text> | <seconds>
OPEN: <question> | <seconds>
NEXT: <text or "none">
ACTION: <verb phrase> | <owner name> | <due date or "none">
```

The `OVERVIEW:` label appears once; every following line belongs to it until the next known label. Blank lines are kept as paragraph breaks and consecutive non-blank lines are joined with a space (`joinParagraphs`) — the model hard-wraps mid-sentence, so a raw newline join would leave ragged text in the card.

`MeetingAISummary` has a lenient `init(from decoder:)` — all fields fall back to empty/nil on decode failure so partial summaries from truncated output are still usable.

### Key Actors

- **`MeetingEngines`** (@MainActor ObservableObject singleton) — downloads, warms, and vends the four meeting model engines (speech/Nemotron, cleanup/WhisperBridge, intelligence/LLM, speakers/Sortformer). Publishes `readiness: [MeetingEngine: EngineReadiness]` and `overallProgress: Double`. `prefetch()` is idempotent. `borrowLLM()` / `releaseLLM()` handle refcounted LLM access with a 60-second idle-unload window.
- **`MeetingChatStore`** (actor) — reads/writes `<uuid>-chat.json`. Each `append()` loads, appends, and writes atomically. Cleared by `MeetingManager.deleteMeeting`.
- **`MeetingAIService`** (actor) — whole-transcript + KV-cache LLM calls. `ask()` uses the full transcript as a system prompt (cached once per meeting), parses `[Ns]` citation patterns via `parseCitations(from:segments:)`. `generateTitle` and `generateOverview` are one-shot and do not cache.
- **`MeetingSession`** (@MainActor ObservableObject) — ephemeral live state (segments, notes, elapsed timer). Writes to CoreData via `MeetingManager` as chunks arrive.
- **`MeetingManager`** (@MainActor ObservableObject singleton) — sole CoreData gateway for `MeetingEntity`. All writes use `HistoryDatabase.shared.newBackgroundContext()`. Crash-recovery via `loadInProgressSessions()`.

### swift-ogg Dependency

- SPM: `https://github.com/element-hq/swift-ogg` (branch `main` — the repo has no release tags). Product linked: `SwiftOGG`.
- Transitively pulls `vector-im/opus-swift` and `vector-im/ogg-swift` as **binary xcframeworks** (~1.3 MB of macOS slices).
- Both are **dynamic and ad-hoc signed** (`TeamIdentifier=not set`), so they must be **Embed & Sign** in the target's Frameworks phase — the same treatment FluidAudio gets — or the archive fails notarization. Verify with `codesign -dv --verbose=4` on the embedded frameworks after archiving: they must show our team ID, not `not set`.
- `OGGEncoder` exposes no `opus_encoder_ctl`, so there is **no bitrate knob** — the encoder runs at libopus's default for 16 kHz mono VoIP (~19 kbps). The lever, if quality ever needs one, is `application: .voip` → `.audio`.
- `OGGEncoder.endstream()` is `internal`, so the last page carries no `e_o_s`. Measured: nothing in AVFoundation, `afinfo`, or `ffprobe` cares.

### Meeting Studio UI

3-column layout in `MeetingStudioView`:

| Column | Width | Component | Contents |
|---|---|---|---|
| Left | 260pt | `MeetingListPanel` | Library rows + live recording card (sonar animation, elapsed timer, stop button) |
| Center | flexible | `MeetingDetailView` | Editable title, metadata, Transcript / Overview tabs |
| Right | 420pt | `MeetingRightPanel` | Recording state: sonar animation; Stopped: `MeetingPlayerCard` + `MeetingAssistantPanel` |

**`MeetingAssistantPanel`** — three-tab bottom section:
- **Ask AI** — RAG Q&A with indexing status pill, thinking animation, source citation chips (tap → scroll to timestamp).
- **Live Notes** — `MeetingNote` items (DECISION / RISK / IDEA) with inline editing; add-note bar during recording.
- **Speakers** — word count and turn count per speaker with proportional bar chart.

**`MeetingTranscriptView`** — groups segments into 5-minute chapter buckets. Shows live bubble during recording (`currentSegmentText` in white + `livePreviewText` in white 0.4 opacity as `AttributedString`). Syncs scroll to playhead position during playback. Receives `.meetingScrollToTimestamp` notification from `AskAIPane`.

**`MeetingPlayerCard`** — wraps `MeetingAudioPlayer` (`AVAudioPlayer` with `enableRate=true`, 50ms timer tick). Renders 70-bar waveform from `WaveformGenerator`, draggable scrubber, speed picker (0.5–2×).

**RTL in transcript:** `MeetingSegmentTextView` (NSViewRepresentable wrapping NSTextField) with `NSMutableParagraphStyle.baseWritingDirection = .rightToLeft`. RTL detection uses >30% RTL-letter ratio from first 150 chars (Hebrew 0x0590–0x05FF, Arabic 0x0600–0x06FF, Syriac 0x0700–0x074F, Arabic Presentation Forms).

**Speaker color palette:** 8 colors by `speakerIndex % 8` — indigo (#5B6CF7), amber, emerald, pink, purple, cyan, red, lime. Used in segment rows, speaker headers, and playback active-segment indicator.

### The Stop Transition

Stopping a recording used to blank the transcript for as long as the AI pass took, then snap it back. Two independent causes, both fixed:

**1. The live→persisted handoff had no overlap.** `MeetingDetailView.transcriptSegments` switched from `session.segments` to `detailVM.displayedSegments` the moment `isRecording` flipped, but `detailVM`'s copy was whatever was fetched when the (then empty) meeting was created. The reload wired to that same flag called `detailVM.load(meetingID:)`, which early-returns when `loadedMeetingID` is unchanged and `meeting != nil` — so nothing actually reloaded, and segments only reappeared when `.meetingOverviewDidGenerate` finally fired `refreshDetail()` tens of seconds later.

The handoff now keeps rendering `session.segments` until `detailVM.allSegments.count >= session.segments.count` (compared against `allSegments`, not the page-capped `displayedSegments`), and `MeetingStudioView` calls `refreshDetail()` — which fetches before assigning and never shrinks the display window — on both `isRecording` and `session.segments.count`. The second trigger catches the tail chunk that lands after `stopRecording()` has already returned.

**2. Nothing showed that work was still happening.** `MeetingProcessingPhase` (`.finalizing` → `.polishing` → `.naming` → `.summarizing`) is published on `MeetingManager.processingPhases[UUID]` and driven from `MeetingSession.stopRecording()`: `.finalizing` is set the instant the LIVE badge goes away, then the detached AI Task advances it around the cleanup (re-transcription) pass / `generateTitle` / `generateOverview` and clears it at the end (including on the empty-transcript early exit — otherwise the indicator would never stop).

`MeetingProcessingBanner` renders it between the tab bar and the tab content: breathing gradient orb, phase label with `.contentTransition(.opacity)`, a progress rail, and four step dots keyed off the phase index. The rail is indeterminate by default — on-device LLM latency is too variable for a percentage to be honest — but takes an optional `progress: Double?` and renders a determinate gradient fill when one is supplied. Only `.polishing` supplies it, because batch count is genuinely known. `MeetingLibraryRow` mirrors the phase as a pulsing dot plus a `shortLabel` pill so the left panel stays in sync.

### Transcript Refine (post-stop Whisper re-transcription)

Meeting chunks never reach the dictation LLM pass — `AppState`'s `onChunkCompleted` closure routes to `MeetingSession.onNewChunk` and returns *before* `chunkLLMCoordinator.enqueue`. Raw ASR errors would otherwise propagate into the AI overview and Ask AI, both built from the same text. `MeetingTranscriptRefiner` (`@MainActor` singleton) cleans the transcript in the window after stop, before naming and summarizing.

**Why a second decode, not an LLM.** This pass used to hand the finished transcript to the on-device MTP model and ask it to fix spelling, punctuation and "obvious mishearings" — asking a language model to guess what the audio said. It can pattern-match a plausible correction; it cannot hear. It also needed a byte-identical system prompt (one warm KV slot), a 256-token cap, batch sizes derived from that cap, a numbered `N| text` protocol with a two-strike fallback, a custom script table for the token estimator, and per-line strict validation to catch the model rewriting lines it was told to leave alone. The audio is still on disk: re-running it through a large Whisper model replaces every guess with a real decode, and Whisper's own punctuation and capitalization come for free.

```
MeetingRefineWindow.plan(segments, maxDuration: 30)   // group cards, never split one
    ↓ per window
SessionStorage.readFloat32Window(audioURL, start-0.5s … end)   // decoded to 16 kHz mono Float32 = whisper's input
    ↓ ModelWorkQueue.shared.run("meeting-refine")
WhisperBridge.transcribeTimestamped → [WhisperTimedSegment]     // no_timestamps = false, t0/t1 in centiseconds
    ↓ shift by lead-in, drop pieces ending before window.start
MeetingRefineWindow.assign → [cardIndex: text]                  // each piece to the card it overlaps most
    ↓ DictionaryManager.correctText → plausibility guard → rawText/text write
MeetingManager.updateSegments (one bulk encode per window)
```

| Constraint | Consequence |
|---|---|
| The transcript is **one** `NSTextView` (`SelectableTranscriptView`); any content-signature change triggers a full `setAttributedString` + relayout and clears an in-progress selection | Text is **never** mutated during the run. Progress is drawn purely from the published `segmentMetrics` geometry (sweep + done-edge overlays), and the refined array is committed **once** at the end via `.meetingSegmentsDidRefine`. |
| Whisper is trained on 30s windows, and its encoder cost is per window, not per card | `plan` greedily groups cards while `end - windowStart <= 30s` and never splits a card. Grouping is both the cheapest shape and the one Whisper is most accurate on — one decode per 30s of audio, not one per card. |
| `ModelWorkQueue` reclaims a slot after a 120s `stallCeiling` | One queue job **per window** (a 1–3s decode), not one per run. Per-window submission also re-checks the meeting gate, so starting a new recording suspends the run at a window boundary. |
| An Ogg Opus file reports **48 kHz** through `AVAudioFile` whatever it was encoded at, so a hardcoded 16 000 in the window arithmetic is silently 3× off | `readFloat32Window` derives `framePosition` from `file.processingFormat.sampleRate` and converts into a 16 kHz Float32 buffer through an explicit `AVAudioConverter`. Refined text landing on the wrong card is this, not the codec. |
| Per-window auto-detect can flip language mid-meeting | Language comes from `AppState.selectedLanguage`; when it is `.auto` it is pinned to `bridge.lastDetectedLanguage` after the first decoded window. |
| `TranscriptPostValidator(.strict)` exists to catch an LLM drifting off a line it was told to preserve | Not reused — a genuine second decode legitimately differs far more. The guard only rejects the two failure modes a decode actually has: an empty result, and a length ratio outside 0.4…2.5 (hallucination spiral or dropped utterance). |
The model is fixed at `MeetingTranscriptRefiner.cleanupModel` (a compile-time constant: `.largeTurboQ5`) and is deliberately independent of the dictation model: this runs after the meeting, off the latency path, so accuracy is the only thing that matters. Its `WhisperBridge` is loaded as its own `"meeting-refine-load"` queue job and released via `prepareForShutdown()` on every exit path. Context carry matches `FileTranscriptionManager`: the last 100 chars of refined text become the next window's `initial_prompt`. A window whose cards were all refined by an earlier run is skipped without a decode (its text still feeds the next window's prompt). Each window is persisted through `MeetingManager.updateSegments` (one bulk encode — `updateSegment` per segment would be quadratic), so a quit mid-run loses at most one window.

Raw text is preserved in `MeetingSegment.rawText` (nil = never refined; `isPolished` derives from it), and is set only when still nil so repeat runs keep the Original toggle showing true live-ASR text. The synthesized `Codable` uses `decodeIfPresent`, so stored `segmentsJSON` blobs keep decoding. A Polished/Original control in the transcript header swaps `text` for `rawText` at render time — view state only, no writes. Meetings recorded before the feature get a "Re-transcribe" action in the same header.

The run is automatic when `meetingPolishEnabled` (default on) and the meeting audio is on disk; otherwise it is silently skipped and the phase sequence stays `.finalizing → .naming → .summarizing`. It is also skipped below 2GB free memory — the same threshold `AppState.prepareMeetingBackend()` uses — since it loads a second multi-GB model alongside the meeting backend.

### Notification Names (meeting-specific)

| Name | Posted by | Observed by |
|---|---|---|
| `.switchToMeetingStudioTab` | `AppState.startMeetingRecording`, `OverlayView`, toast tap | `HistoryWindowView` (tab switch) |
| `.meetingOverviewDidGenerate` | `MeetingAIService.generateOverview` (success) | `MeetingDetailView` (toast), `MeetingOverviewView` (clear skeleton) |
| `.meetingOverviewDidFail` | `MeetingAIService.generateOverview` (failure) | `MeetingOverviewView` (show error) |
| `.meetingTitleDidGenerate` | `MeetingAIService.generateTitle` (success) | `MeetingDetailView` (refresh cached `editableTitle`) |
| `.meetingSegmentsDidRefine` | `MeetingTranscriptRefiner.run` (once per run, incl. cancel) | `MeetingDetailView` (single polished-text commit) |
| `.meetingScrollToTimestamp` | `AskAIPane` source chip tap | `MeetingTranscriptView` (scroll to segment) |

### Scroll-to-Timestamp

Source citation taps in `AskAIPane` post `.meetingScrollToTimestamp` with `chunk.startTimestamp` as `object: Double`. `MeetingTranscriptView` finds the last segment with `timestamp <= seconds + 2` and scrolls to it via `ScrollViewReader.scrollTo(segmentID, anchor: .top)`.

## RTL Support

### Why NSTextField, not SwiftUI Text
SwiftUI `Text` does NOT expose paragraph base writing direction control. Six approaches were tested and failed:
1. `environment(\.layoutDirection, .rightToLeft)` — controls view layout mirroring, not text paragraph direction
2. `multilineTextAlignment(.trailing)` — aligns lines within container, doesn't change where new lines START from
3. `environment(\.locale, Locale("he"))` — doesn't affect paragraph style
4. Unicode RLI/PDI isolates (`\u{2067}`/`\u{2069}`) — SwiftUI Text doesn't pass them to Core Text
5. `frame(maxWidth: .infinity, alignment: .trailing)` — view alignment, not paragraph direction
6. HStack + conditional Spacer — unreliable inside ScrollView

### Working solution: NSViewRepresentable
`TranscriptionTextView` wraps `NSTextField` and sets `NSParagraphStyle.baseWritingDirection = .rightToLeft` directly. AppKit's Core Text rendering respects this unconditionally.

### RTL Detection
- **Language-level**: `TranscriptionLanguage.isRTL` — true for Arabic, Hebrew, Persian, Urdu, Pashto, Sindhi, Yiddish
- **Content-level**: `LiveTranscriptionCard.detectRTL(in:)` — scans first 50 chars for Hebrew/Arabic Unicode ranges. Triggers immediately when RTL text appears, before language detection.
- **Scrollbar**: Appears on left edge for RTL, right edge for LTR

### RTL Animation Policy
Word-by-word typewriter animation is skipped for RTL (shows text immediately). The animation reveals words left-to-right visually, which is wrong for RTL scripts.

## Core ML ANE Acceleration

### Build Configuration
whisper.cpp is compiled with `WHISPER_USE_COREML=ON` and `WHISPER_COREML_ALLOW_FALLBACK=ON` (baked into `libwhisper.a` and `libwhisper.coreml.a`). All 3 Xcode configs (Debug, Release, AppStore) have `WHISPER_USE_COREML=1` preprocessor definition and link `-lwhisper.coreml -framework CoreML`.

### How it works
whisper.cpp automatically looks for `{model-name}-encoder.mlmodelc` next to the `.bin` file. If found, the encoder runs on Apple Neural Engine (ANE). If not found, falls back to Metal GPU silently (`WHISPER_COREML_ALLOW_FALLBACK=ON`).

### Encoder downloads
`ModelDownloader.ensureCoreMLEncoder(for:)` downloads pre-converted encoder zips from HuggingFace and unzips next to the model binary. `WhisperModel.coreMLEncoderDownloadURL` maps models to their encoder URLs.

### Performance impact (M2 Pro, measured)
- Main model (large-v3-turbo-q5) with Core ML encoder: **588ms** alone (vs 731ms GPU-only = 19% faster)
- Both models on ANE: total memory **990MB** (vs 1023MB GPU-only)
- Tiny detector on ANE: **31ms** detection (acceptable)

## MCP Server

Whisperer hosts a local [Model Context Protocol](https://modelcontextprotocol.io) server so AI tools (Claude Desktop, Cursor, etc.) can query meeting notes and transcription history without any cloud relay.

### Architecture

```
AppDelegate.setupComponents()
  └── WhispererMCPServer.shared (Swift actor, Whisperer/MCP/)
        ├── NWListener  →  TCP port 8080 (default, user-configurable)
        │     └── per-connection Task  →  HTTP/1.1 request loop
        │           └── StatefulHTTPServerTransport.handleRequest()
        ├── MDNSHostnameRegistrar  →  registers whisperer.local → 127.0.0.1 via dns_sd
        │     (non-sandboxed builds only; goes through mDNSResponder, no root needed)
        └── Session lifecycle loop (Task): creates Server + Transport,
              awaits Server.waitUntilCompleted(), then recreates for next client

MCP Tools (one JSON-RPC handler each):
  tools/list    → MCPMeetingTools.toolDefinitions + MCPTranscriptionTools.toolDefinitions
  tools/call    → dispatch by name:
    list_meetings         → CoreData fetch of MeetingEntity, sorted by createdAt DESC
    get_meeting           → single MeetingEntity by UUID (segments, AI summary, notes)
    search_transcriptions → CoreData fetch of TranscriptionEntity with NSPredicate text+date filter
    get_transcription     → single TranscriptionEntity by UUID

Settings: SettingsTabView → "MCP Server" settingsCard → MCPSettingsView
AppState:  mcpEnabled (Bool, UserDefaults), mcpPort (Int, UserDefaults), mcpServerRunning (Bool, runtime), mcpBonjourReady (Bool, runtime)
URL:       http://whisperer.local:8080/mcp (non-sandboxed) / http://localhost:8080/mcp (App Store)
```

### Transport Layer

`StatefulHTTPServerTransport` (from `modelcontextprotocol/swift-sdk`) is framework-agnostic — it does not bind to a port itself. `WhispererMCPServer` wraps it with a custom HTTP/1.1 server using `NWListener` (Network.framework):

1. `NWListener` binds to the configured port once and lives for the app session.
2. Each TCP connection spawns a Task that reads HTTP/1.1 requests (headers + body via Content-Length) and writes responses.
3. `GET /mcp` → `HTTPResponse.stream` → headers sent, then SSE chunks forwarded as they arrive from the transport's `AsyncThrowingStream<Data>`.
4. `POST /mcp` → JSON-RPC request forwarded to transport → response written and connection kept alive for next request.
5. `DELETE /mcp` → terminates the session; `server.waitUntilCompleted()` returns; outer loop restarts with a fresh Server + Transport for the next client.

### Tool Data Access

Both tool modules read CoreData directly via `HistoryDatabase.shared.newBackgroundContext()` and `ctx.perform { }`. This avoids hopping to the main actor (and serializing through `MeetingManager`/`HistoryManager`) while keeping CoreData thread safety intact.

### Pitfalls

- **`Server` is a Swift actor** — `withMethodHandler` must be called with `await` from any other actor.
- **`StatefulHTTPServerTransport` is stateful** — one session per instance. On `DELETE` or disconnect, recreate both `Server` and transport for the next connection.
- **`OriginValidator.disabled`** — used instead of `.localhost()` because MCP clients (Claude Desktop, Cursor) connect programmatically without an `Origin` header; the localhost-only validator would reject them. DNS rebinding is not a real threat for a dictation app.
- **NWListener outlives sessions** — only one listener is created; the session loop (Server + Transport) recreates per-client, not per-connection.
- **`MDNSHostnameRegistrar` requires `DNSServiceCreateConnection`** — the `connectionRef` must remain alive while the server is running; `DNSServiceRefDeallocate` in `unregister()` removes the A record. `kDNSServiceFlagsUnique` means if another process already claimed `whisperer.local`, registration fails silently and the UI falls back to `localhost`. Entire class is `#if !APP_STORE`.
- **dns_sd is part of libSystem** — no separate framework to link. `#include <dns_sd.h>` in the bridging header is all that's needed.

## Key Design Decisions

### 1. SafeLock over Swift Actors
**Decision**: `SafeLock` (timeout-based NSLock) for WhisperBridge and StreamingTranscriber, not Swift actors.
**Why**: whisper.cpp is blocking C code. Swift actors suspend on await, not block. SafeLock provides timeout protection to prevent deadlocks. Timeout is 10s on Apple Silicon, 60s on Intel.
**Pitfall**: Never hold SafeLock from main thread if background work might need it.

### 2. Key Detection (App Store Compliant)
**Decision**: `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` for Fn key + Carbon `RegisterEventHotKey` for key+modifier shortcuts.
**Why**: CGEventTap, IOKit HID, and global keyDown/keyUp monitors are rejected by App Store review (Guideline 2.4.5). The current approach uses only approved APIs: flagsChanged monitors modifier state changes (not keystrokes) and Carbon hotkeys are a standard macOS hotkey mechanism used by many approved apps.
**How it works**: Fn key detected via `event.keyCode == 63` in flagsChanged handler. Non-Fn shortcuts (e.g., Cmd+Shift+Space) registered via Carbon `RegisterEventHotKey` which fires pressed/released events for hold-to-record support.
**Pitfall**: Carbon hotkeys require proper cleanup — `UnregisterEventHotKey` and `RemoveEventHandler` in teardown. The `Unmanaged.passUnretained(self)` pointer must remain valid while the handler is registered.

### 3. Five-Minute Recording Limit
**Decision**: Hard cap at 5 minutes (~19MB audio buffer at 16kHz mono Float32).
**Why**: Unbounded audio buffering causes OOM on long sessions. 4,800,000 samples = ~19MB.
**Pitfall**: Don't remove this limit without implementing streaming-to-disk.

### 4. Pre-loaded Whisper Model
**Decision**: Model stays in memory after first load. WhisperBridge is created once and reused.
**Why**: Instant recording start. Loading large-v3-turbo takes 2-5s. Re-loading on every recording would add unacceptable latency.
**Pitfall**: ~1.5GB memory footprint for large models. This is intentional.

### 5. Text Injection: Accessibility API + Clipboard Fallback
**Decision**: Primary is `AXUIElementSetAttributeValue` (assistive text input). Fallback is clipboard + simulated Cmd+V via `CGEvent.post(tap: .cgAnnotatedSessionEventTap)`.
**Why**: Accessibility API is instant and doesn't touch clipboard. But it doesn't work in all apps (Electron apps, some terminals). Clipboard fallback restores previous clipboard content after paste. If Accessibility permission is denied entirely, text is copied to clipboard with a notification for the user to paste manually.
**Performance**: AX messaging timeout set to 100ms via `AXUIElementSetMessagingTimeout` to prevent blocking if the target app is hung. Text injection runs inline on the calling thread (not dispatched to a background queue) to avoid latency from queue contention.
**App Store framing**: Accessibility API usage is framed as assistive text input for dictation — this is its intended purpose and is approved by App Store review. `CGEvent.post` (posting synthetic events) is distinct from `CGEvent.tapCreate` (monitoring events) and does not require Input Monitoring.

### 6. Non-Activating Overlay Panel
**Decision**: `NSPanel` with `[.borderless, .nonactivatingPanel]`, `hasShadow = false`.
**Why**: The recording overlay must NOT steal focus from the app where text will be inserted. `nonactivatingPanel` keeps the previous app as key window.
**Pitfall**: Use `.orderFront()`, NEVER `.makeKey()` or `.makeKeyAndOrderFront()`. The panel shows whenever `state != .idle` via NotificationCenter observer. A 5-second safety timeout in `stopRecording()` prevents the HUD from getting permanently stuck if audio device errors cause `audioRecorder.stopRecording()` to hang. The panel dynamically resizes via `adjustFrameForContent()` when the live transcription card expands/collapses — grows upward for bottom positions, downward for top position.

### 7. Context Carrying for Transcription
**Decision**: Last 100 characters of previous transcription passed as `initial_prompt` to next chunk.
**Why**: Whisper produces better continuity when it knows what came before. Reduces word repetition at chunk boundaries.

### 8. Tail-Only Final Pass
**Decision**: On stop, only transcribe unprocessed audio after the last completed chunk (not the entire recording).
**Why**: Re-transcribing the full recording added seconds of latency after key release. Tail-only processing reduces final-pass latency by 10-15x while streaming chunks already provide good incremental results. Dictionary corrections are applied to the combined streaming + tail output.
**Pitfall**: Always use `await transcriber.stopAsync()`, never `transcriber.stop()`. The synchronous `stop()` races with in-flight chunks — it reads `lastProcessedSampleIndex` before the chunk's completion handler updates it, causing the tail to overlap with already-transcribed audio and producing duplicated text. `stopAsync()` polls `isProcessing` until in-flight chunks complete, then calls `stop()` with consistent state.

### 9. Deterministic Greedy Decoding
**Decision**: `temperature=0.0`, `temperature_inc=0.0` (no fallback ladder), greedy sampling with `best_of=1`.
**Why**: The default `temperature_inc=0.2` causes up to 6 decode retries per chunk at increasing temperatures when entropy/logprob thresholds aren't met. Each retry re-runs the full decoder. Disabling this makes per-chunk latency predictable. VAD already filters silence, so fallback retries add cost without benefit for dictation.

### 10. Performance-Core Thread Count
**Decision**: On Apple Silicon, query `hw.perflevel0.logicalcpu` to use only performance cores (minus 2 reserved for audio/UI). On Intel, cap at 8 threads.
**Why**: Using all cores (including efficiency cores) causes straggler effects where fast P-cores wait for slow E-cores. Reserving cores prevents contention with audio capture, VAD, and UI.

## Windows & UI Chrome

All windows share a unified dark navy theme (`#0C0C1A` background, `#14142B` card surfaces, blue-purple accents).

### Window Configuration Pattern
Every NSWindow is configured for flat dark appearance:
- `window.appearance = NSAppearance(named: .darkAqua)`
- `window.titlebarAppearsTransparent = true` (workspace only — menu bar uses `MenuBarWindowConfigurator`)
- `window.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)`
- `window.hasShadow = false` — flat appearance, no system border
- Content view layer: `cornerRadius = 10`, `masksToBounds = true`, `borderWidth = 0`

### Onboarding Window (OnboardingWindow + OnboardingView)
Borderless NSWindow (860x540) shown on first launch. Four-page guided setup:
1. **Welcome** — App introduction with brand animation
2. **Permissions** — Microphone + Accessibility permission requests
3. **Model Selection** — Download whisper model during setup
4. **Shortcut Setup** — Configure recording trigger key

Sets `hasCompletedOnboarding` in UserDefaults on completion. Launched from `AppDelegate.applicationDidFinishLaunching()` when flag is false.

### Menu Bar Window (MenuBarWindowConfigurator)
`NSViewRepresentable` that accesses the hosting NSWindow from SwiftUI's `MenuBarExtra` and applies the flat dark appearance. Necessary because `MenuBarExtra` doesn't expose its NSPanel directly.

## Component Ownership

```
WhispererApp
  └── AppDelegate
        └── AppState.shared (@MainActor)
              ├── AudioRecorder (owned, optional)
              ├── GlobalKeyListener (owned, optional)
              ├── WhisperRunner (owned, optional)
              ├── WhisperBridge (private, pre-loaded)
              ├── SileroVAD (private, optional)
              ├── StreamingTranscriber (private, created per recording)
              │     ├── VADSegmenter (owned, uses SileroVAD)
              │     ├── LanguageRouter (optional, when routing enabled)
              │     └── ModelRouter (optional, when routing enabled)
              ├── ModelPool (private, optional — when routing enabled)
              │     ├── WhisperBridge (shared preview/detector, CPU-only tiny model)
              │     └── warm backends (fallback + standby)
              ├── TextInjector (owned, optional)
              ├── AudioMuter (owned, optional)
              ├── SoundPlayer (owned, optional)
              └── AudioDeviceManager.shared (shared singleton)
        └── WhispererMCPServer.shared (Swift actor, started by AppDelegate)
              ├── NWListener (TCP server, lives for app session)
              └── StatefulHTTPServerTransport + Server (recreated per MCP client session)
```

**Rule**: AppState holds service references. Services NEVER hold AppState references. Services communicate back via closures (`onStreamingSamples`, `onTranscription`).

## Dependency Direction

```
UI Layer (SwiftUI Views)
    ↓ reads @Published, calls methods
AppState (@MainActor singleton)
    ↓ holds references, calls methods
Services (AudioRecorder, WhisperBridge, TextInjector, etc.)
    ↓ uses
Infrastructure (Logger, SafeLock, CrashHandler)
```

**Never**: Service importing SwiftUI. View directly calling a Service (go through AppState). Infrastructure depending on Services.

## Data Persistence

| Data | Storage | Why |
|------|---------|-----|
| Transcription history | CoreData (`WhispererHistory.xcdatamodeld`) | Complex queries, relationships |
| Dictionary entries | CoreData (`DictionaryEntryEntity`) | Structured data, search |
| User preferences | UserDefaults | Simple key-value (model, language, mute) |
| Audio recordings | File system (`~/Library/Application Support/Whisperer/Recordings/`) | Large binary data |
| Whisper models | File system (`~/Library/Application Support/Whisperer/`) | ~500MB-1.5GB files |
| Logs | File system (`~/Library/Logs/Whisperer/`) | Rotation, crash recovery |

## Audio Storage — one format, and something that deletes

Every recording in the app — dictation, meeting, and imported file — is stored as **Ogg Opus**, 16 kHz mono, `~8.3 MB/hour`. `AudioArchiveFormat` is the single source of truth for the extension, the rate, the writer, and the transcoder; nothing else names a container.

### Written live, not transcoded at stop

`AudioRecorder` holds an `AudioArchiveWriter` (an `OGGEncoder` + `FileHandle` from [swift-ogg](https://github.com/element-hq/swift-ogg)) and encodes on `sessionWriteQueue` as buffers arrive — 0.81% of one core, 14× fewer bytes than the Int16 LPCM it replaced. **The session file already is the archive**, so `StreamingTranscriber.saveRecording` is a `copyItem` and `MeetingSession.moveAudioToMeetingsDirectory` is a `moveItem`. There is no second copy and no transcode step on the latency path.

This was previously the app's largest disk leak: a dictation wrote a 32 KB/s CAF into `Sessions/` **and** a 64 KB/s Float32 WAV into `Recordings/`, and `SessionStorage.deleteSessionFile` had zero call sites — both copies survived for a week until an orphan sweep found the CAF. `AppState.saveRecordingFromTranscriber` now deletes the session file once the copy succeeds (skipped in meeting mode, where `MeetingSession` consumes the same file).

Two consequences of Ogg worth knowing before touching this code:

- **It always reports 48 kHz.** `AVAudioFile.processingFormat.sampleRate` on a 16 kHz-encoded `.opus` is 48 000 — that is how Ogg Opus presents itself to every decoder, not a resample. All sample-index and duration arithmetic must be **rate-relative**, and duration comparisons must be in **seconds**, never frames. `SessionStorage.readFloat32Window` and `WaveformGenerator` both derive position from `processingFormat.sampleRate`.
- **It survives a `kill -9`.** Ogg is page-framed with a CRC per page, so a decoder stops cleanly at the last complete page. Measured: 29.96 s recovered of 30 s written, with no `e_o_s` packet. A periodic `flush()` bounds the loss further.

### AudioRetentionService

`@MainActor final class AudioRetentionService` (singleton) is the only thing in the app that deletes. Before it existed, the `autoDeleteAfterDays` picker was wired to nothing while the Data Management card promised automatic removal.

| | |
|---|---|
| **Schedule** | `start()` from `AppDelegate.setupComponents()` (behind `AudioStartupGate`, so launch is never blocked), then a repeating 6-hour `Task` — a menu bar app stays up for weeks, so once-per-launch cleanup never runs. `runLaunchSweep()` is a **separate** entry point called *after* `loadInProgressSessions` / `recoverCrashedSessions`; the old bare `deleteOrphanedSessions()` call ran before them and could unlink audio a row was still being finalized against. A change to the picker re-sweeps immediately via `UserDefaults.didChangeNotification`. |
| **What it deletes** | Whole records, never just audio: the CoreData row, the recording, and for a meeting its `.wax` index and `<uuid>-chat.json`. A library entry with a dead play button is worse than no entry. Deletion goes through the owning manager (`HistoryManager.deleteTranscriptions(olderThan:)`, `MeetingManager.deleteMeeting`) so there is one delete path per record type. Orphaned `Sessions/` files are swept unconditionally, independent of the retention setting — no record refers to them. |
| **Setting** | `autoDeleteAfterDays` — Never / 7 / 30 / 90 / 365, one setting covering dictation **and** meetings (meetings are hours of audio against a dictation's seconds). Default `0` = Never: an update must never silently delete a library. |
| **Safety gates** | `currentBlocker` returns non-nil while `AppState.state != .idle`, a meeting session is active, or `MeetingTranscriptRefiner` is running — the cycle is skipped, not queued. Re-checked between the transcription and meeting halves, since an hour-long meeting library takes a while. `isInProgress` rows are skipped (crash-recovery candidates, not expired ones). Age comes from `createdAt`, never file mtime, which a refine or transcode pass resets. |

`HistoryManager.deleteTranscription(_:)` also used to drop the row and orphan its audio forever; both it and `deleteAllTranscriptions` now go through one private path resolver.

### AudioLibraryCompactor

Opt-in rewrite of pre-Opus `.wav` / `.caf` library audio, offered as a row in Settings → Audio. **Not automatic** — every reader goes through `AVAudioFile` / `AVAudioPlayer`, so legacy files play and render waveforms exactly as before; this only reclaims disk.

Record-driven, not directory-driven: only files a CoreData row points at are converted, because the conversion is only safe if the row can be repointed. The ordering is the whole design — transcode to a sibling `.compacting.opus` → verify it opens and its duration matches **in seconds** (source reports 16 kHz, output reports 48 kHz) → move to a unique `.opus` → commit the filename through the owning manager → *only then* unlink the original. A failed commit deletes the **new** file and keeps the original, so a row never points at nothing. It shares `AudioRetentionService.currentBlocker` and re-checks it per file, stopping at a file boundary if a recording starts.

## Common Pitfalls

1. **WhisperBridge.transcribe() is blocking** — NEVER call from main thread. Always use `transcribeAsync()` or call from background DispatchQueue.

2. **OverlayPanel focus theft** — Use `.orderFront(nil)`, never `.makeKeyAndOrderFront(nil)`. The panel must not become key window.

3. **Audio engine config changes during muting** — `AudioMuter` changing system audio triggers `AVAudioEngineConfigurationChange` notification. AudioRecorder has a 1.5s startup grace period to ignore these.

4. **CoreData on wrong thread** — `HistoryManager` and `DictionaryManager` must use proper CoreData concurrency (performBackgroundTask for writes).

5. **Retain cycles in Task closures** — `Task { }` captures `self` strongly. Always use `[weak self]` in `Task.detached` and stored closures.

6. **VAD is optional** — The app works without SileroVAD. Never assume `sileroVAD != nil`. Always check: `vadEnabled = vad != nil`.

7. **Model download vs model loading** — `isModelDownloaded()` checks file existence. `isModelLoaded` checks if WhisperBridge has loaded the model into memory. Both must be true before recording.

8. **Clipboard restoration** — TextInjector's clipboard fallback saves and restores previous clipboard content after a 100ms paste delay. If Accessibility permission is denied, text is only copied to clipboard (no simulated paste) and a `TextCopiedToClipboard` notification is posted for the UI.

9. **AX messaging timeout** — Always set `AXUIElementSetMessagingTimeout` (100ms) on both the app element and the focused element before AX calls. A hung target app can otherwise block the entire text injection path indefinitely.

10. **Audio engine retry** — `AudioRecorder.startRecording()` retries once on ANY setup failure (not just device-specific errors). The retry tears down the engine completely via `cleanupEngineState()`, resets to the default device, waits 200ms, and tries again. This handles transient audio unit failures (error 1852797029) that occur when the audio device state changes between recordings.

11. **stopRecording() safety timeout** — A parallel Task sleeps 5 seconds, then checks if state is still `.stopping`. If so, it forces `.idle` (clearing `streamingTranscriber` and `liveTranscription`). The main stop Task checks `guard case .stopping = state` after `audioRecorder?.stopRecording()` returns — if the timeout already fired, it bails out. This prevents the overlay HUD from getting permanently stuck when `AVAudioEngine.stop()` hangs on a bad audio device.

12. **stopAsync() over stop()** — Always use `await transcriber.stopAsync()` in AppState, never `transcriber.stop()`. The synchronous `stop()` reads `lastProcessedSampleIndex` before in-flight chunk completion handlers update it, causing overlapping tail transcription and duplicated text output.

13. **Language detection retry budget** — `detectionAttempts` only increments after sufficient voiced audio is confirmed. If VAD filtering skips detection (too much silence), the attempt is not counted. This prevents exhausting the 3-retry budget on silence-heavy recordings.

14. **whisper_full_lang_id() is weak evidence** — It reflects decoder state, not an independent language classifier. Treat per-chunk language mismatches as weak votes (half-weight vs script mismatches). Never use as a hard mismatch trigger.

15. **Script ≠ language** — ScriptAnalyzer detects script families (Cyrillic, Latin, etc.), not languages. Cyrillic could be Russian, Ukrainian, or Bulgarian. Always intersect with the user's allowed language shortlist before scoring.

## Deep Reference

For whisper.cpp C interop details (context lifecycle, threading, C string lifetime, streaming pipeline, shutdown sequence), see [docs/references/whisper-cpp-integration.md](docs/references/whisper-cpp-integration.md).

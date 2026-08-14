# Meetings — Knowledge

## Meeting stop is a four-model pile-up, and nothing used to coordinate it

*Confirmed by source inspection (2026-08-11) — no instrumented run needed; the call graph guarantees
the overlap.* Four model families are resident and all want the ANE or the GPU:

| Family | Runtime | Owner |
|---|---|---|
| Nemotron ASR | FluidAudio, CoreML/ANE | `NemotronBridge` |
| Sortformer diarizer | FluidAudio, CoreML/ANE | `MeetingSpeakerCoordinator` |
| MiniLM RAG embedder | Wax, CoreML/ANE | `MeetingRAGEngine` |
| Qwen3.5-4B MTP | MLX, Metal | `LLMPostProcessor` |

Within one second of `MeetingSession.stopRecording()`, three of them start at once:

1. `MeetingManager.finalizeSession()` → detached `indexMeeting` — MiniLM on the ANE
2. `Task { generateTitle → generateOverview }` — MLX on Metal, **two different system prompts**
3. `stopInAppRecording()` reaching `.idle` → the old `restoreBackendAfterMeeting()` → a full
   CoreML/ANE teardown and reload of the user's backend

The only coordination that existed was `MeetingDiarizerService.launchGraceSeconds = 15`, a blind
`Task.sleep`. The observable results were `MTP KV warmup … 33683ms`, a ~62 s Nemotron Hebrew →
Nemotron → back cycle, and a 120 s `embedder.embed` timeout — one pile-up, not four bugs.

Now: `ModelWorkQueue` (actor, `Transcription/ModelWorkQueue.swift`) runs one heavy job at a time and
suspends all of them while a meeting records. Its `label waited=Xms ran=Yms` log line is the standing
evidence mechanism — overlaps are visible by construction rather than needing a special build.

## `mtpWarmCache` is a single slot keyed on the whole system prompt

`processMTP` spawns `runMTPWarmup` fire-and-forget on a cache miss, and that warmup contends for the
same `ModelContainer` serial lock as the generation it is supposed to accelerate. It pays a full
prefill of the system prefix (33.7 s measured) to save ~420 ms on the *next* call with a byte-identical
prompt.

The meeting paths never get that next call:
- `generateTitle` and `generateOverview` use different prompts — title warms the slot, overview
  immediately evicts it.
- `ask()` embeds the retrieved transcript *inside* its system prompt, so it is **unique per question**.
  Every single Ask AI query used to kick off a full warmup that could never be reused.

Dictation is the opposite case — same system prompt every utterance — so the cache is worth keeping
there. Hence `reuseWarmCache: Bool = true` on `process(...)`, passed `false` by all three meeting
call sites. A cache *hit* still uses the cache; the flag only suppresses *building* one.

## Transcript polish is the one meeting path that *should* warm the MTP cache

The rule above (`reuseWarmCache: false` for meeting prompts) exists because title / overview / ask
each use a different or per-question prompt. Polishing is the opposite shape and is the reason the
flag has a `true` branch at all in the meeting code: a byte-identical system prompt, run N times
back-to-back over one meeting's batches. Batch 1 pays the prefill, every later batch reuses it.

That only holds if the phase is **contiguous**. Interleaving polish with title or overview
generation evicts the single slot on every switch and turns the win into N full prefills — which is
why `stopRecording()` orders the work `naming → polishing → summarizing` rather than, say, kicking
the overview off in parallel. One warm-up per phase, and `warmupPrompt` is called once as the phase
opens so the prefill overlaps the UI transition instead of the first batch.

MTP also suits this task specifically: cleanup output is a near-copy of the input, which is the
regime where the speculative draft head hits its highest acceptance rate. The `acceptRate` /
`effTokPerCall` fields on the `MTP gen:` log line are the metric to watch when re-tuning batch size.

## A meeting borrows Nemotron; it does not switch the user's backend

`prepareMeetingBackend()` used to store `preMeetingBackendType`, call `selectBackend(.nemotron)`
(teardown + reload + a UserDefaults write), poll up to **90 s**, and reverse the whole thing on stop —
~62 s of pure loading per meeting for anyone whose dictation backend is not Nemotron, with the return
leg landing on top of the post-meeting AI work.

`selectedBackendType` is now never written by the meeting path. Instead `meetingOwnsNemotron` marks the
bridge as borrowed and `effectiveInAppBackend` reports `.nemotron` to the in-app recording path only.
The pieces that had to change together:

- `preloadNemotronModel()` assigns `nemotronBridgeInstance` unconditionally; only the user-visible
  state (`isModelLoaded`, `loadedBackendType`, `preloadLLM()`) stays gated on
  `selectedBackendType == .nemotron`, so the menu bar does not mislabel the user's backend.
- `releaseCurrentBridge()` skips both the Nemotron teardown *and* `nemotronLoadTask?.cancel()` while
  the bridge is meeting-owned — a backend switch mid-meeting would otherwise kill a load in flight.
- `releaseMeetingNemotron()` hands the bridge back through `ModelWorkQueue`, so the ~600 MB survives
  until the title, overview and RAG-index jobs queued ahead of it have drained.
- Below `meetingDualBackendHeadroomGB` (2.0 GB free) the user's bridge is evicted for the duration and
  reloaded afterwards — the old swap behaviour, minus the write to `selectedBackendType`.

Both Nemotron variants resident at once is the deliberate trade: transient RAM instead of 62 s of
teardown and reload.

## Async start guards must cover the whole start, not just the end state

`MeetingSession.startRecording(title:)` used `guard !isRecording` as its only entry guard, but
`isRecording = true` is the *last* line of the method. Between the guard and that assignment sit
`AppState.prepareMeetingBackend()` (polls up to **90 s** while Nemotron loads) and
`MeetingManager.beginSession()` (creates the CoreData row).

Every tap on Start during that window passed the guard and created its own `MeetingEntity`. The
duplicates were never finalized, so the next launch logged:

```
Meeting crash recovery: finalizing 4 interrupted session(s)
```

Evidence for the 1:1 mapping (2026-08-11 session):
- 10:21:01.665–.757 — 4× `Cannot start meeting recording — AppState not idle`
- 10:24:20 (next launch) — `finalizing 4 interrupted session(s)`

Fix: a separate `isStarting` flag set on the first line and cleared in `defer`, plus a re-check of
`isRecording` after the `prepareMeetingBackend()` await.

## `MeetingRAGEngine.index()` is destructive, so it cannot run concurrently with itself

`index()` closes the cached `Memory` handle and `removeItem`s the `.wax` before rebuilding. Two
concurrent builds of the same meeting therefore pull the store out from under each other. Observed
failure shapes:

- 10× `Meeting RAG indexing failed (<uuid>): unavailable` within **45 ms**
- `io("open failed for …<uuid>.wax: No such file or directory")` ×4
- `TimeoutError(operation: "embedder.embed", timeout: 120.0 seconds)` — N builds contending for one
  MiniLM/ANE embedder

Two independent callers spawn `indexMeeting` on detached background tasks:
`MeetingManager.finalizeSession()` and `MeetingAssistantPanel.onAppear`. The panel gates on
`MeetingRAGEngine.isIndexed()`, which is a bare `FileManager.fileExists` check — it stays **false for
the entire duration of a build**, so every re-appearance of the pane spawns another competing build.

Fix lives in the engine (not the callers): `indexingTasks[UUID]` coalesces, `indexedSegmentCounts[UUID]`
lets a joiner distinguish "already covered" from "the running build predates my segments" (matters
because `finalizeSession` may arrive with 25 segments while a 5-segment build is running).

## "Debug session ended with code 9: killed" is not a crash

Xcode SIGKILLs the debuggee on stop. The app's own shutdown path had already logged
`Crash marker removed - clean exit` / `Graceful shutdown complete, terminating`. The ~20
`Previous session crashed!` warnings on 2026-08-10 are the same artifact — a crash marker left behind
because SIGKILL cannot be caught. Do not treat these as real crashes without checking for the clean-exit
lines in the *preceding* session.

## A 1.0 s main-thread stall dump can be plain window creation

`stall-latest.dump` with `Reason: Main thread unresponsive for 1.0s`, all components healthy and
`state: idle`, written 1.27 s after `Creating new HistoryWindow`, is the watchdog catching
window-construction cost — not a hang. Check the Reason field and Component Health before
investigating further.

## Post-stop transcript cleanup: a second decode beats an LLM rewrite

The meeting polish pass originally sent the finished transcript to the on-device MTP model in ≤4-segment
batches and asked it to fix spelling, punctuation and "obvious mishearings". Everything that made that
pass hard came from the model, not from the problem:

| Machinery | Why it existed |
|---|---|
| byte-identical system prompt, one contiguous run | MTP keeps exactly one warm KV-cache slot |
| `maxTokensCap = 256`, batch ≤4 segments / ≤600 chars | the runaway-output guard is only armed at ≤256 |
| numbered `N| text` protocol + two-strike fallback to one line per call | the model stops honouring the shape under load |
| custom script table for `outputTokensHint` | `containsNonLatinScript` omits Cyrillic and Greek |
| `TranscriptPostValidator(.strict)` per line | the model rewrites lines it was told to leave alone |

None of it survives the swap to `WhisperBridge.transcribeTimestamped` over the recorded audio: the
decode is deterministic, has no output protocol to violate, and produces punctuation and capitalization
as a by-product. The replaced code was ~200 lines of prompt/parse/validate machinery; the replacement is
window planning (`MeetingRefineWindow`, pure value logic) plus a read → decode → assign loop.

What it costs: a second multi-GB model load, and wall-clock proportional to audio length rather than to
transcript length. For a meeting with long silences the LLM pass could be faster — the guard against
that is the 2GB free-memory skip and the fact that the pass is entirely off the latency path.

## Whisper timestamps map back to cards by overlap, not by order

`whisper_full_get_segment_t0/_t1` are centiseconds relative to the buffer that was passed in, so the
caller must shift them by the window's lead-in offset before comparing against card timestamps. A decode
of a 30s window returns its own segmentation, which does not line up with the live backend's cards —
`MeetingRefineWindow.assign` gives each decoded piece to the card it overlaps most (ties to the earlier
card) and joins per card, with a nearest-card fallback so a piece that overlaps nothing is attached
rather than dropped. Cards that receive nothing keep their original text.

## "Downloaded" is not "ready" for a Core ML–backed model

A meeting stop froze the whole app for ~40s. The log names it exactly:

```
ModelWorkQueue: meeting-refine-load waited=458ms ran=39903ms
ModelWorkQueue: meeting-refine  waited=1ms ran=1341ms
whisper_init_state: first run on a device may take a while ...
Main thread unresponsive for 2.0s   (×2, 32.0s apart)
```

~96% of the stall was the **load**, not the refine — whisper.cpp compiling
`ggml-large-v3-turbo-encoder.mlmodelc` for the ANE for the first time on that machine. The refine
itself was one window and 1.3s.

The cause was upstream in readiness, not in the refiner. `MeetingEngines.refreshReadiness()` derived
`.cleanup == .ready` from `ModelDownloader.isModelDownloaded(.largeTurboQ5)` — file on disk. But
`prefetch()` skips any engine already `.ready`, so from the second launch onward `runCleanup()` never
ran, and the warm pass whose entire purpose is to pay that compile off the latency path never
happened. The compile therefore landed at meeting end every time, with no progress UI in front of it.

The compiled encoder lives in an OS-managed cache we neither own nor can query, so the only available
signal is a marker of our own: `meetingCleanupWarmSignature` in UserDefaults, keyed by the model
filename so changing `MeetingTranscriptRefiner.cleanupModel` re-warms. It can over-promise if the OS
evicts the cache — cost is exactly one meeting paying the compile again — and it is written **only**
on a successful warm, so a failed warm re-runs next launch instead of silently deferring.

Representing this state needed a new `EngineReadiness` case rather than reuse of an existing one:

| Reuse candidate | Why it breaks |
|---|---|
| `.preparing` | `prefetch()` has `case .ready, .downloading, .preparing: continue` — the engine would be skipped forever |
| `.needsDownload` | `MeetingTranscriptRefiner.blockingReason` would tell the user to download a model already on disk, and the prep footer would add its bytes to "remaining to download" |

Hence `.needsWarmup`: on disk, owes a first-run compile. It falls through `prefetch()`'s `default`,
contributes no download bytes, and `blockingReason`'s `default: return nil` lets a refine proceed on a
cold model rather than refusing to run.

The warm pass itself uses `useGPU: false`. whisper.cpp loads the Core ML encoder unconditionally
regardless of that flag, so this pays the entire compile without standing up a Metal context that
would contend with SwiftUI while the prep screen animates. The refiner's own load asks for the GPU and
still hits the warmed encoder cache.

## Refcounted borrows compose, but only if someone holds the outer one

`MeetingAIService.generateTitle` and `generateOverview` each `acquireLLM()` → `defer releaseLLM()`,
and `MeetingEngines.releaseLLM()` arms a 60s idle unload when the refcount hits zero. Run
back-to-back, the count dips to 0 between them — a slow title generation can let the 3.2 GB model
unload and be reloaded for the overview. One outer `borrowLLM()` spanning both keeps it ≥ 1.

Placement matters: the borrow is taken **after** the cleanup re-transcription, not before. The refiner
loads its own multi-GB Whisper model and skips itself below 2 GB free; holding the LLM resident across
it would work against that check.

## The "silence" between two cards was a hole in the diarizer's timeline

Reported as one sentence split across a `0:31 → 0:33` seven-word card and a continuation:
`"For example, if you train a model"` / `"based on Nike sales data, you can then use…"`. There is
no pause between *model* and *based*.

The sequence:

1. The first card closed on the 30s `maxSegmentDuration` cap, and the close set the next card's
   start to that same `end` — the Rule 18 contiguous-timestamp signature.
2. The next delivery arrived with `start - lastChunkEndTimestamp >= silenceSplitGap` (1.2s), so the
   gap rule fired and committed the 7-word card.

That gap is manufactured, not spoken. `MeetingSpeakerCoordinator.voicedRuns` reports Sortformer's
finalized timeline verbatim — deliberately, its doc comment defers the threshold decision to
`MeetingSession` — and `emit()` apportions an item's words across the runs proportionally by voiced
duration, so a hole between two runs lands the cut wherever the arithmetic puts it, including
mid-sentence. On the audio clock a timeline hole and real silence are the same number.

The same defect shows in already-committed text: a refine window's carried context read
`'…broken down into something called discriminative models. and generalize.'` — a card that ends on
a complete sentence followed by the orphan fragment `and generalize.`

The fix is Rule 36 — arbitrate every break through `closeSegment(endTimestamp:policy:)` and make the
arrival-derived ones prove themselves against the text. Notably the floors alone would not have been
enough: a 7-word card is caught by `minSegmentWords`, but the mid-sentence *cut* is the actual defect,
and only the sentence-boundary test addresses it.

## Two live colours described the pipeline, not the recording

`MeetingTranscriptView` drew `currentSegmentText` at `white.opacity(0.88)` and `livePreviewText` at
`white.opacity(0.4)`. The dim half is real state — it is `MeetingSpeakerCoordinator`'s pending queue,
text Nemotron decoded that Sortformer has not yet attributed, and it can still change. But that is a
distinction between two stages of our pipeline, and the user has no stage to map it onto: both halves
are words they finished saying. Reported as "why some text white some not — all text we see already
been spoken". Rendered as one colour now.

## `kAudioDevicePropertyDeviceIsRunningSomewhere` is a trigger, not attribution

*Confirmed 2026-08-14 from a 3-hour user log (11:20 → 14:22) plus a live read-only probe of this
machine.*

The log showed ~30 identical cycles and never once fired a toast:

```
MicrophoneUsageMonitor: any input active=true
MeetingDetector: hardware changed (camera=false, mic=true) — debouncing
MeetingDetector: resolve returned nil (score below threshold)
```

**That last line was false, and it is what made the bug hard to see.** `score()` is the only emitter
of `"<name> score X < 0.45, skipping"`, and not one such line exists in the whole session — so
`score()` was never called. `resolve()` fell through every strategy without producing a candidate.
Nothing was scored below threshold; nothing was scored at all. A log line that names a *plausible*
cause instead of the *observed* one is worse than no line: it sends every reader down the same wrong
path. The replacement prints the evidence (which bundle IDs are capturing, camera/mic state, whether
AX is reachable) and lets the reader draw the conclusion.

The real cause: the property is **per device**, so it only says "some input is hot". `resolve()` then
*guessed* the provider from running/frontmost apps — impossible for a browser meeting or a Slack
huddle, where there is nothing to guess from.

A probe of `kAudioHardwarePropertyProcessObjectList` returned 36 audio process objects, of which
exactly one had `runningInput=1`: `pid=2444 bundle=com.cisco.Proximity` — the Webex room-pairing
agent, which opens the mic on a timer all day. Under the old design that is byte-identical to a real
meeting. **Every one of the 30 cycles was Cisco Proximity.**

The fix is attribution, not tuning: `kAudioProcessPropertyIsRunningInput` per process object answers
"who". It is read-only public API and needs no TCC grant, unlike process taps — which matters
because it is therefore the only attribution path that can ever exist in the sandboxed App Store
build.

Corollaries worth keeping:
- Capture is reported against **helper** processes (`com.google.Chrome.helper`, Electron helpers), so
  a pid → parent-pid walk to the owning `NSRunningApplication` is mandatory, not a nicety.
- Slack is always running and often frontmost, so "Slack is open" is worthless — but Slack opens the
  mic *only* during a huddle, so "Slack is capturing" is by itself conclusive. Hence
  `requiresAudioCapture` on `MeetingAppDefinition`: some apps must never match on presence alone.
- A browser capturing for two seconds is a voice search, not a meeting. Duration of an *unbroken*
  capture run is the discriminator (15s), which means tracking a first-seen timestamp per bundle ID
  and clearing it the instant capture stops.

## A build setting can silently override the entitlements file you named

*Confirmed 2026-08-14.* The Debug config pointed at `whisperer-nosandbox.entitlements` and still ran
sandboxed, because `ENABLE_APP_SANDBOX = YES` injects `com.apple.security.app-sandbox` regardless of
the file's contents. The filename read as documentation of intent; the build setting was the truth.

The tell was in the log paths — `~/Library/Containers/com.ivy.whisperer/Data/Library/Logs/` rather
than `~/Library/Logs/Whisperer/`. Verify with the artifact, never the filename:

```bash
codesign -d --entitlements - path/to/whisperer.app | grep -A1 app-sandbox
```

The consequence was invisible: a sandboxed process cannot read another app's AX window titles, and
`allWindowTitles` warned only on `.apiDisabled` / `.notImplemented` — not the `.cannotComplete` a
sandbox actually returns. Browser detection was dead in every Debug build for as long as this held,
and no line in the log said so. **When a permission-gated read can fail, warn on every failure
mode, not on the ones you predicted**; the unpredicted one is the one that bites.

## The Google Meet prompt fired on the one title that proves there is no call

*Confirmed 2026-08-14.* User report: the "MEETING DETECTED / Google Meet" toast appeared on
`meet.google.com/home` ("No meetings scheduled for today", camera off, nothing running), and a real
call with the camera on produced nothing. Both halves are the same defect seen from two sides.

`meetingPatterns` matched the string `"Google Meet"` against browser window titles. That is
**exactly** the title of the Meet landing page. An in-call tab is titled `Meet – abc-defg-hij`,
which contains neither `"Google Meet"` nor `"meet.google.com"` (a window title is the page title;
it never contains the URL). So the table matched the one state that proves a call is *not*
happening and missed every state where one is. The Zoom row (`zoom.us/j/`) shows the intent — narrow
to the join path — but no Meet row was ever narrowed, and `zoom.us/j/` cannot match a title either.

Why the score gate did not save it: there are two firing paths, and only one of them scores.
`resolve()` → `score()` correctly rejected a title-only candidate (`browserMeetingWindow` 0.30 with
no hardware = 0.30 < 0.45 threshold). But `fallbackPoll()`'s browser branch calls `fireDirect()`,
which fires with no evidence object and no threshold, and it sat outside the
`if hardware.microphoneActive { … }` block that guards the native branches above it. The poll —
whose job is to *back up* the resolver — was strictly more trigger-happy than the resolver.

The log shows the loop this produced, on a 40-second period:

```
10:14:05 MeetingDetector: fallback detected Google Meet     ← fireDirect, zero hardware
10:14:16 MeetingDetector: suppressed until hardware goes idle  ← user hits Dismiss
10:14:28 CameraUsageMonitor: camera active=true              ← unrelated blip
10:14:36 CameraUsageMonitor: camera active=false
10:14:36 MeetingDetector: hardware idle — suppression cleared  ← lastFiredDate.removeAll()
10:14:45 MeetingDetector: fallback detected Google Meet     ← 30-min cooldown is gone
```

`hardwareWentIdle()` called `lastFiredDate.removeAll()` when clearing suppression, destroying the
30-minute refire guard on every hardware idle transition. "Dismiss" was a ~40-second snooze.

The camera blip at 10:14:28 is also the false *negative*: `isReadyToTrigger()` returns false in
`.suppressedUntilHardwareIdle`, so the genuine camera-on event was swallowed by the state the false
positive had left behind. One bug, presenting as two opposite symptoms.

The fix is a gate that means something rather than a narrower string:
`detectBrowserMeeting()` now requires the matched browser to be in `capturingApps`. A meeting tab
that is not holding the microphone is a landing page, a calendar invite, or this morning's call left
open. The title says *which* service; capture says *whether*. Both call sites inherit it, so the
poll and the resolver finally agree. Belt and braces on top: exact landing-page titles
(`nonCallWindowTitles`) are skipped, and `Meet – ` / `Meet — ` / `Meet - ` were added so a real call
matches at all. Services whose in-call titles we cannot verify are covered by the existing
`sustainedCapturingBrowser` path, which fires "Meeting in <browser>" after 15s of unbroken capture —
generic, but honest, and it needs no guess about anyone's title format.

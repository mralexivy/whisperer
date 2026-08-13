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

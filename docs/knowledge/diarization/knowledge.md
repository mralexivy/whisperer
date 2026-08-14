# Diarization — Facts and Confirmed Patterns

## Nemotron partials are the whole transcript, not a delta

`StreamingNemotronMultilingualAsrManager`'s partial callback fires every ~1120 ms with the
**full accumulated transcript so far**. `StreamingTranscriber.onPreviewTail` forwards it
verbatim, despite the "tail, not full text" comment on the AppState side. Any consumer that
appends what it receives will duplicate the meeting quadratically.

Deriving the delta needs a longest-common-prefix diff — **at word granularity, not character
granularity**. Nemotron routinely re-cases and re-punctuates its last few words as more
context arrives (`hello` → `Hello,`), so a character diff reports the whole tail as rewritten
on nearly every partial.

## The diff needs a floor at what was already emitted

A revision can legitimately rewrite words that are still queued, but never words already
handed downstream. `divergence = max(lcp, emittedWordCount)` is the hard floor. Without it, a
Nemotron tail revision reaches back into committed segments and the transcript rewrites
itself under the user.

## Sortformer's finalized timeline lags the audio by ~1s

`DiarizerTimelineUpdate` carries `finalizedSegments` (committed) and `tentativeSegments`
(may still flip). Attributing text the moment it arrives means labelling it from tentative
data, which flips — visible as segments that change speaker after the fact.

Queueing text until `finalizedUntil` covers its span costs nothing in perceived latency,
because the not-yet-attributed remainder is exactly what the UI already draws as the grey
live tail. The user sees the same words at the same time; they just acquire a speaker
colour ~1s later.

## Two speaker states, not one

- **Tentative** (`liveSpeakerIndex`) — drives the live bubble's label and accent colour only.
- **Committed** (`currentSpeakerIndex`) — the speaker of the text actually attributed, and
  the value a segment flush compares against.

Collapsing them breaks boundary flushing: if a tentative report writes `currentSpeakerIndex`,
the `speakerIndex != currentSpeakerIndex` check in the attribution path never fires and
paragraphs never close at speaker turns.

## Audio-sample clock is the only shared axis

The coordinator is fed the same buffers as the ASR, so `samplesFed / 16000` is the exact
audio position. Nemotron partials *arrive* later than the audio they describe; Sortformer
timestamps are audio time. Counting samples puts both on one axis with no fudge factor.
(Same conclusion as [transcription/rules.md](../transcription/rules.md) rule 2, reached
independently.)

## `SortformerDiarizer.process()` drains one chunk per call

`addAudio` buffers internally; `process()` returns `nil` until a chunk's worth of mel
features exists, and several chunks can be queued after a burst. It must be called in a loop
— bounded, so a misbehaving model can't spin. `try?` on it yields `Result?` nested in
`Optional`, so the double optional needs flattening: `((try? diarizer.process()) ?? nil)`.

## Sortformer's ANE compile is 9.2s, and it lands wherever you first load the model

`SortformerModels.loadFromHuggingFace` ends in a plain `MLModel(contentsOf:configuration:)`.
The bundle on disk is already a `.mlmodelc`, but the first load of the **palettized** variant
still compiles an ANE program — `Compiled model v3/palettized/Sortformer_v2.1.mlmodelc in
9165.36 ms` on an M2 Pro. Deferring the load to `MeetingSpeakerCoordinator.start()` to avoid
holding ~330 MB resident sounds thrifty, but it just relocates 9.2s into the first meeting: in
the observed run the transcript's first partial took 3.4s and then stalled for 4.5s — a whole
dropped 1120 ms chunk cycle — straddling the compile.

Load-then-release at launch is the right shape. It leaves the compile in CoreML's on-disk
cache without keeping the model in memory, and a cache hit makes repeat calls near-free.

## Feed the diarizer in batches, not per capture buffer

`fastV2_1` is `chunkLen: 6`, `subsamplingFactor: 8`, `melStride: 160` → 48 mel frames = **7680
samples = 0.48s of audio per ANE inference**, about two inferences a second. `addAudio()` and
`process()` cheaply no-op in between. So handing the actor every ~85 ms capture buffer buys
nothing and costs ~12 `Task` allocations a second on the audio path. Batching to 0.25s adds
skew an order of magnitude below the diarizer's own ~1s finalization lag.

## `drainPending()` runs per buffer; the tail changes per partial

The two are ~12x apart in frequency. Publishing the pending tail unconditionally from
`drainPending()` means ~12 `@Published` writes a second into `MeetingSession.livePreviewText`,
each re-rendering `MeetingTranscriptView` — an `NSViewRepresentable` wrapping `NSTextField`.
Guarding on "did the string actually change" drops it to the partial rate. Any callback fired
from a per-buffer drain loop needs this check.

## Model loads at launch compete

`MeetingDiarizerService.prefetch()` firing from `AppDelegate.setupComponents()` put an 89s
Sortformer download alongside a 19.4s Nemotron load and a 604 MB LLM load with a 1136 ms warmup
prefill. All three are nominally background; together they made the whole UI sluggish for the
launch window. Staggering the optional one behind a grace period costs nothing — nothing
blocks on the diarizer, and meetings degrade to single-speaker until it lands.

## `selectBackend` is inert unless the app is idle

`AppState.selectBackend` guards on `state == .idle`. Restoring a pre-meeting backend from
`stopMeetingRecording()` silently does nothing — state is `.stopping` there. The restore has
to run after `state = .idle` at the end of `stopInAppRecording()`'s async Task.

Also ordering-sensitive: `preloadNemotronModel()` refuses to install the bridge unless
`selectedBackendType` is *already* `.nemotron`, so the switch must precede the load.

## Sortformer finalizes a turn only when the turn *closes* — so text arrives in bursts

`DiarizerTimeline.updateSegments` commits a finalized segment on a speaking→not-speaking
transition (or, in the finalized call, only when `aux.endFrame < finalizedEndFrame`). While a
speaker keeps talking, `aux.speaking` stays true and **nothing is committed** — `finalizedUntil`
does not advance at all.

`MeetingSpeakerCoordinator.drainPending()` gates on `first.end <= finalizedUntil`, so this
propagates straight through: during continuous speech the queue fills and emits nothing, then
the speaker takes a breath, a turn closes, `finalizedUntil` jumps, and a whole burst drains at
once. Measured on a 48s uninterrupted monologue: 31 Nemotron partials arriving smoothly at
~1.1s each, delivered downstream as 7 bursts.

The consequence is that **arrival cadence on this path carries no information about speech**.
Anything downstream that infers "the speaker paused" from a gap between callbacks is reading
the diarizer's commit schedule, not the audio.

## Queue items abut exactly, so the raw span can never show a pause

`ingest()` sets each pending item's `start` to `lastPartialAudioSeconds` and its `end` to the
current `audioSeconds`, then assigns `lastPartialAudioSeconds = now`. Consecutive items
therefore share an edge by construction — `item[n+1].start == item[n].end` always. A consumer
diffing those spans sees a single unbroken stream no matter how long the speaker was silent.

Real silence only becomes visible after clipping each item to the finalized turns
(`voicedRuns`). Nemotron emits no partial while nobody is talking, so the partial that follows
a pause carries a window spanning it; clipping to one envelope would average the gap away, so
the item is split at its internal voiced runs and the words apportioned by voiced duration.

## The ANE compile cache does not make a second load cheap

`MeetingDiarizerService.warm()` originally loaded the palettized Sortformer bundle at launch for
the side effect on CoreML's on-disk compile cache, then released the handle on the theory that
`MeetingSpeakerCoordinator.start()` would reload it cheaply. Measured in one session:

| Load | When | Duration |
|---|---|---|
| `sortformer-warmup` | launch, idle ANE | **518 ms** |
| coordinator `start()` | meeting start, Nemotron streaming | **9299 ms** |

`Diarization: Sortformer ready (4 speaker slots)` landed 9.3 s into a 57.5 s meeting — 16% of it
recorded with no speaker labels. The dominant cost is ANE contention with the live ASR, which the
compile cache does nothing about. Retain the handle instead.

The coordinator's fallback load deliberately does **not** go through `ModelWorkQueue`: the meeting
gate is raised at exactly that moment, so a queued load would wait for the meeting it is supposed
to be diarizing.

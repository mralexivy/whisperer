# Transcription — Facts and Confirmed Patterns

## Chunk cadence is a property of the backend, not of the speech

`StreamingTranscriber.onChunkCompleted` does **not** fire on a uniform schedule. Each backend
has its own commit policy:

| Backend | Cadence |
|---|---|
| whisper.cpp | One chunk per voiced VAD segment (a few seconds, speech-dependent) |
| WhisperKit | Every ≥6s of cross-window-agreed audio |
| Nemotron | **Exactly one chunk containing the whole session, at stop** |
| SpeechAnalyzer | Its own path |

Any consumer that derives structure from chunk *arrival* — "flush a paragraph every N
chunks", "cap a segment when a chunk pushes it past 30s" — silently degrades to a single
unbounded blob on Nemotron. Symptom observed: a 54-second meeting produced exactly one
transcript card spanning 0:00 → 0:54, while the same code produced sensible paragraphs on
whisper.cpp.

Anything that must be bounded needs a **post-hoc split** that operates on the accumulated
text, not just an arrival-time check. See `MeetingSession.splitByDuration()`.

## Audio clock, not wall clock, for anything that maps text to time

Transcript timestamps must be derived from `samplesReceived / sampleRate`
(`StreamingTranscriber.recordedDuration`, or the chunk's own sample-index range), never from
`Date()` or a 1 Hz `elapsedSeconds` counter.

Wall clock includes inference latency, cold-model promotion stalls, and UI hitches, so it
drifts away from the recorded `.m4a`. Since that file is what playback scrubs, wall-clock
timestamps mean tapping a transcript card seeks to the wrong audio.

`TranscriptChunk` carries `start`/`end` on the audio clock precisely so consumers never have
to reconstruct it. `recordedDuration` is a separate field because "how long is the session"
and "what span does this chunk cover" are different questions — passing only the former is
what forced the earlier wall-clock workaround.

## VAD chunk boundaries are the only real silence signal available

For VAD-segmented backends, `chunk.startSample`/`endSample` bound the *voiced* audio exactly,
so `nextChunk.start - previousChunk.end` is genuine silence and a sound basis for paragraph
splitting (1.2s threshold in `MeetingSession`).

A wall-clock "no chunk has arrived for 2.5s" timer is **not** silence detection — it also
fires on slow inference, and never fires meaningfully for single-blob backends. It is still
worth keeping as an idle backstop (the gap rule can only fire once the *next* chunk lands, so
without it a long pause leaves the card open), but it must not be the primary rule.

## Proportional time distribution when word timings are unavailable

whisper.cpp with `no_timestamps = true` gives no word-level timing, so subdividing an
over-long span has to approximate. Speech rate is near-constant over tens of seconds, so
allocating each piece a share of the span equal to its share of the characters is accurate
enough for scroll-to-timestamp. Cut at sentence terminators; fall back to word boundaries
when the text is unpunctuated (common in raw whisper output). Pin the final piece's end to
the true end so rounding never leaves a gap.

## The stored `language` column is the router's decision, not the transcript's language

`TranscriptionEntity.language` records what `LanguageRouter` locked onto, which for a
recording that switched language mid-way — or that locked before enough voiced audio
arrived — is not the language of the text that was ultimately produced. In the dev
history, a purely Hebrew recording is stored as `"en"`.

Anything that needs to know what language a transcript *is* must read the transcript.
`ScriptAnalyzer.dominantScript(in:allowedLanguages:)` filtered to the shortlist in play
answers it directly (Latin→en, Cyrillic→ru, Hebrew→he), and a stray English technical
term inside a Hebrew sentence loses on character count as it should.

This cost a whole benchmark run: selecting multilingual test fixtures by the `language`
column produced four English chunks and one each of Hebrew and Russian, all mislabelled,
and the "multilingual" comparison it fed was effectively an English-only one.

### The scale of the mislabelling, measured (2026-08-17)

The polish benchmark measured it over the whole corpus rather than a handful of fixtures.
`ZLANGUAGE` declares **151 Hebrew recordings, of which only ~10 contain any Hebrew**. The
golden set inherits the same field — `GoldenEntry.language` is copied from the database row,
so its `he = 93` is likewise ~10 real Hebrew and ~83 English or Russian speech that happened
to be routed through the Hebrew model. A "Hebrew" column built on it measures mostly English.

What the field actually records is **which model the audio was routed to**. That is a useful
fact about the router and a useless one about the speech, and the two are only correlated
when detection was right — which is the thing a benchmark is usually trying to measure.

The replacement is `PolishBenchmarkTests.detectedLanguage(of:)`: majority-by-word over
`ScriptAnalyzer.scriptFamilies(in:)`, `mixed` when nothing holds a majority. Majority by
*word* rather than by character, matching `ProtectionDetector.dominantFamily`, so one
borrowed Latin technical term cannot relabel a Hebrew utterance.

## Whisper's language routing is not stable between a streaming and a whole-file decode

Same audio, same model, same decode params, differing only in windowing — and the two land
in different languages on **22 of 400 recordings (~5.5%)** in the golden set. 21 are English
speech whose whole-file `goldenTranscript` came back in Russian, one came back Bulgarian,
one went Russian → English.

This is not a polishing result and not a transcription defect that shows up in normal use;
it is a property of running language detection over a different amount of audio. It matters
because the whole-file decode is used as a *reference* (see `GoldenSet.swift`), and a
reference in another language is a **translation of the input**: WER against it is ~1.0 by
construction, on every arm, however good the thing being measured was.

Measured cost of not excluding those rows, on the Russian column of the polish benchmark:

| | mean WER | median WER |
|---|---|---|
| including cross-language references | 0.6566 | 1.0000 |
| excluding them | 0.0215 | 0.0000 |

The metric inverted — Russian went from the corpus's worst-scoring language to its best. The
exclusion applies to WER only. Metrics that never read the reference (script drift, digit and
URL preservation) still run over every row, because a mistranslated reference must not be
allowed to excuse damage.

## Encoder cost on largeTurboQ5: ANE is a flat ~0.57s floor; audio_ctx breaks it (measured 2026-08-15)

Measured by `WhispererTests/EagerStreamEncoderBenchmarkTests` (Phase 0b), M2 Pro, Debug,
median of 3 greedy decodes on a real history recording. All decodes deterministic.

| window | A: ANE, audio_ctx=0 | B: Metal, sized audio_ctx | speedup |
|---|---|---|---|
| 3s  | 0.555s | 0.180s (ctx=256) | 3.1x |
| 6s  | 0.568s | 0.259s (ctx=512) | 2.2x |
| 12s | 0.616s | 0.418s (ctx=768) | 1.5x |

- **ANE latency is flat regardless of window length.** The Core ML encoder always builds a
  fixed 1500-frame (30s) mel, so a 3s window costs the same as a 12s one. Shrinking the eager
  window — or lowering `softCommitSamples` to keep windows short — buys *nothing* on the ANE
  path. Only `audio_ctx` moves this number.
- **`audio_ctx = 256` (3s) causes verbatim phrase repetition.** Config B at 3s returned
  `"Yes, but now all the queries are in Data Backs. Yes, but now all the queries are in Data
  Backs."` — the same span twice, for audio that contains it once. At 512 and 768 the text is
  comparable to ANE. Treat **512 as a hard floor** for `audio_ctx`; below it the decoder loops.
  This is a likely contributor to the duplicated-word reports on the eager stream.
- The two configurations are mutually exclusive: Core ML loads on `.mlmodelc` file presence in
  `whisper_init_state` with no cparams opt-out, and `whisper_coreml_encode` ignores `audio_ctx`.

### Harness rule — never mutate the user's model directory to run a measurement

The first version of the benchmark moved `ggml-large-v3-turbo-encoder.mlmodelc` aside and
restored it in a `defer`. The test process aborts on exit while freeing the whisper context
(`pointer being freed was not allocated`), so the `defer` never ran and the install was left
without its ANE encoder — twice. Correct approach: symlink the `.bin` into an empty temp
directory. whisper.cpp looks for the encoder next to the `.bin` it was handed, so it falls back
to Metal with zero mutation. Test output must also be appended to a file per measurement, not
printed in a summary at the end — the abort discards stdout's buffer.

### The ANE encoder is removed from the whisper.cpp path entirely (2026-08-15)

Not just slower per pass — slower to load, and it recurs:

```
whisper_init_state: loading Core ML model from '.../ggml-large-v3-turbo-encoder.mlmodelc'
❌ Main thread unresponsive for 19.0s
ANE model load has failed for on-device compiled macho. Must re-compile the E5 bundle. @ GetANEFModel
E5RT: ... (13)
Whisperer V3 pre-loaded in 79.37s
```

The E5 recompile is not a one-time first-run cost; it fires again on later launches.

whisper.cpp has **no `cparams` opt-out** — `whisper_init_state` loads Core ML purely on file
presence. Deleting the directory is the only switch. `WhisperBridge.purgeCoreMLEncoder(besideModelAt:)`
does it on every model load, replicating `whisper_get_coreml_path_encoder`'s derivation
(strip extension, strip a trailing `-qN_N`, append `-encoder.mlmodelc`). Removed 1.2 GB from
Application Support.

Corollary: `WHISPER_USE_COREML=1` stays in the build settings — with no `.mlmodelc` on disk it is
inert, so there is no need to relink whisper.cpp.

**Correction — the switch is compile-time, not the filesystem.** `whisper.cpp/build-static` had
`WHISPER_COREML:BOOL=OFF` in its CMake cache, but the linked `libwhisper.a` was months older and
still contained the Core ML path — the cache had been reconfigured without a rebuild, so the
"off" setting was a lie. Rebuilt with `-DWHISPER_COREML=OFF -DWHISPER_COREML_ALLOW_FALLBACK=OFF`
and removed `WHISPER_USE_COREML=1` + `-lwhisper.coreml` from all three Xcode configs. Verify with
`strings <binary> | grep -i "loading Core ML model"` — must be empty. Deleting the `.mlmodelc` is
now only a disk cleanup.

### `audio_ctx` does NOT work on the eager path — reverted (2026-08-15)

The 3/6/12s benchmark above does not extrapolate down. Real eager windows are **0.5–2s**, where:

- the encoder was never the bottleneck, so there is no latency to win, and
- a reduced `audio_ctx` is almost all padding (512 frames ≈ 10s of mel for 1s of audio), pushing
  the positional embeddings far outside the training distribution.

Result at the supposedly safe floor of 512: the decoder loops. Live text came back as
`"Let me try to see it one one Let Let me"`, and that garbage then propagates into the next pass's
`initial_prompt`, compounding. Same failure mode previously seen at 256.

Rule: **benchmark at the window sizes the code actually produces.** Measuring 3/6/12s and shipping
a value used at 0.5–2s was the mistake.

### Eager stream: measured profile over real recordings (2026-08-16)

`WhispererTests/EagerStreamProfileTests` replays recordings from the app's own history through
the real `StreamingTranscriber` and measures the eager path. Report:
`/tmp/whisperer-eager-profile.txt`.

**The single most important methodological fact: feed the audio at wall-clock real time.**
The first version of this harness slept 10 ms per 85 ms chunk — 8.5x real time. Per-pass decode
*latency* survives that, but nothing else does: the transcriber saw a 204s recording in 24s, so
it was 180s behind through no fault of its own, and every lag, cadence, pass-count, coverage and
WER number was an artifact. Worse, it *flattered* the results, because a fast feed lets the
decoder fall behind and then get rescued by one big tail decode. Two rounds of conclusions were
drawn from it and both were wrong. Any measurement of "does it keep up" is invalid without a
real-time feed.

**Pass latency is flat in window length.** 536 passes, 12 real recordings, real-time feed, 8s cap:

| window | p50 | p90 | max |
|---|---|---|---|
| 0.5-1s | 1350 ms | 1394 ms | 1463 ms |
| 1-2s | 1350 ms | 1427 ms | 1701 ms |
| 2-4s | 1358 ms | 1456 ms | 1792 ms |
| 4-6s | 1366 ms | 1471 ms | 1888 ms |
| 6-8s | 1381 ms | 1507 ms | 1716 ms |
| at cap | 1341 ms | 1381 ms | 1614 ms |

The decoder dominates and the encoder is noise. An earlier version of this table showed a sharp
break above 8s (p50 2347 ms, max 13161 ms) and that break was **queue backlog, not decode cost** —
it vanished entirely once admission control landed.

**`isProcessing` could not do admission control (TOCTOU).** Reading it and setting it were two
separate locked operations with real work in between — a ring copy, a full-window VAD scan, and
normalisation. Two callers reach the pass function concurrently *by design* (the 150 ms heartbeat
and the completion callback's self-schedule), so both observed `false` and both submitted. Nothing
drained the backlog, so error accumulated for the whole recording. Measured before the fix, at a
real-time feed: a 204s dictation reported p50 pass latency 12193 ms and max 28452 ms on a window
capped at 8s — arithmetically impossible as decode time (155 passes x 12s >> 204s). The live
preview ran 179s behind the speaker and the recording ended with **no text at all**.

Fix: an `NSLock`-guarded `eagerPassInFlight` claimed atomically *before* any work and released on
every path out. Effect, same fixtures and cap:

| | before | after |
|---|---|---|
| p50, long/very-long | 2726-12193 ms | 1341-1513 ms |
| corpus max | 28452 ms | 1888 ms |
| max window lag | 179.2 s | 2.9 s |
| stop latency, long | 2592-5316 ms | 492-2877 ms |

**Rule: a VAD gate on a capped window must test the whole window, not its tail.** The window is
`[agreementStartIndex, +cap]` and `agreementStartIndex` advances *only* inside
`EagerStreamEngine.consume`. So any early return from a pass is a permanent stall: the next pass
sees byte-identical audio and makes the same decision every 150 ms for the rest of the recording.
Two separate bugs came out of this:

1. Gating on the last 2s. A pause routinely has seconds of never-decoded speech behind it, so the
   gate refused to decode audio that no later pass would revisit. `05011586` (204s) took 197 such
   skips against 12 real passes.
2. A capped window that is genuinely all silence. Needs `EagerStreamEngine.seek(past:)` to move
   the boundary, since no decode will move it.

Testing the whole window fixed both and improved WER across the corpus: 0.135->0.090,
0.199->0.155, 0.192->0.163, 0.159->0.122.

**Rule: never return empty final text while live text is on screen.** On the eager path
`completedChunkTexts` only fills after a soft-commit, which needs the agreement boundary to run 6s
past the last commit. A recording where that never happened reached the end with no chunks and the
user watched a screenful of live text vanish on key release — measured: a 204s dictation that
published 143 display updates returned the empty string. `finalizeCompletedChunks` now falls back
to `previewAccumulatedText`.

**Still open.** Live text is not append-only (139 monotonicity violations over 12 fixtures) because
the published string includes the speculative hypothesis tail, which the decoder rewrites freely.
The existing guard is a word-*count* floor and cannot see a same-length rewrite.
`StreamingTranscriber.eagerPublishesSpeculativeTail` makes this an A/B axis the profile measures.

**Harness gotchas, all of which cost a run:**

- Use `stopAsync()`, never `stop()`. The sync path returns while a pass is in flight; that pass
  calls back into a released transcriber and the process aborts in `SafeLock.deinit` with
  "pointer being freed was not allocated" — which looks like a transcriber bug and is not.
- Pace the feed with `Task.sleep`, not `Thread.sleep`. Blocking a thread starves the main queue
  that `onTranscription` is delivered on, so no display sequence is ever recorded.
- Collect probe callbacks under a lock. They fire on `WhisperBridge.queue`; appending to a
  captured local `var` races the test thread and corrupts the heap.
- `HistoryTestLoader.loadFixtures` orders by closeness to 20s, so `maxCount: 300` yields only
  short/medium. Ask for 3000 to get a stratified corpus.

### A held pass and a skipped pass are not the same cost (2026-08-16)

`EagerStreamProfileTests` counted skips from the start and that hid the largest single cost on the
path for three runs. The two outcomes are opposite:

- A **skip** is free. The guard fired before the decode; nothing was spent.
- A **hold** is a completed GPU decode that is thrown away — *and* because `agreementStartIndex`
  advances only inside `EagerStreamEngine.consume`, a hold also freezes the agreement boundary, so
  the next pass re-decodes nearly the same window. It costs roughly two passes, not zero.

`EagerOutcome.holdReason` (`unanchored` / `largeRetraction`) plus the `onEagerPassHeld` probe make
this visible. Measured before the fix below: **35% of 2918 outcomes were holds.**

### The retraction guard compared word counts across windows of different spans (2026-08-16)

The guard held a pass when the new hypothesis had more than `maxRetraction` fewer words than the
previous one. With head-capping the window is `[agreementStartIndex, +cap]`, so **every soft-commit
shrinks the next window** — fewer words come back because less audio was in scope, not because the
decoder took anything back. The guard scored that as a retraction and held the pass, which froze
the boundary, which made the next window shrink again.

Fix: compare like with like — only the previous words whose audio the new window actually covered.
`consume` takes `windowEndIndex` and filters `previousHypothesis` to `endIndex <= windowEndIndex`
before the count comparison. The parameter deliberately has **no default value**; a default would
silently reinstate the bug for any caller that forgot it.

Measured effect across all 16 arms of a full profile run:

| | before | after |
|---|---|---|
| `largeRetraction` holds | ~375 | **0** |
| corpus max pass latency | 249430 ms | 1681 ms |
| worst stop latency (`4cef75da`) | 1040197 ms | 2124 ms |
| passes on that fixture | 41 | 100 |
| WER | improved on 5 of 8 fixtures | (0.350→0.250, 0.200→0.155, 0.148→0.115, 0.162→0.137, 0.188→0.166) |

Cost: p50 rose ~1340 ms → ~1500-1600 ms, because windows legitimately grew (mean window on
`00720393` 3.84s → 5.15s). Remaining holds are 40-50% of passes and are now **all** `unanchored` —
a single isolated cause rather than two mixed ones.

### `gap_ms` separates "passes are slow" from "passes are not being launched"

Wall clock between consecutive pass completions (`EagerPassSample.sinceLastPassMs`). When
`gap_ms ≈ p50ms` the decoder is self-scheduling back-to-back and the cadence is healthy; a much
larger gap is a scheduling problem with a completely different fix. Every row of the current
profile shows `gap_ms` within ~50 ms of `p50ms`.

### Single-run WER cannot resolve a difference below ~0.1 on this corpus

The same fixture scored 0.232 and 0.122 across two runs that differed only in what was
*displayed*. Window-alignment timing shifts what the decoder sees and greedy decoding is not
stable across that. Any A/B on this corpus needs repeats and a stated spread, or the ordering it
reports is noise. `EagerStreamWindowSweepTests.reportRepeatSpread` prints that noise floor next to
the results for exactly this reason.

### A fixture whose `.wav` is shorter than its stored transcript is not a bug to chase (2026-08-16)

`05011586` scored WER 0.922 in every arm of every profile run and was treated as a streaming
failure for three runs. It is a broken fixture:

- history DB `ZDURATION` = 203.7s; the `.wav` on disk is **49.4s** (header self-consistent, so the
  file was finalised short, not truncated afterwards)
- the stored transcript describes all 203.7s, so three quarters of the reference is speech that is
  not in the audio — no decoder could score better
- its audio is also 13 dB quieter than every other fixture (peak 0.093 against 0.19–0.40); it is
  the recording the user made *about* a capture bug, and it captured the bug

Second-order damage: `durationSec` came from the database, so the harness bucketed a 49s recording
as "very-long" and reported its window lag against a timeline four times too long.

`loadEagerCorpus` now derives duration from the samples, re-buckets on it, and drops any fixture
where the audio is under 90% of the database duration, listing what it dropped in the report.
Quiet audio alone is **not** grounds for exclusion — the app has to handle it. A reference that
describes audio the file does not contain is, because it makes WER meaningless rather than bad.

### `requestAbort()` is not a barrier, and an aborted decode is not a failed one (2026-08-16)

Two defects on the eager stop path, found by reading the code after a sweep run aborted the test
host on `malloc: pointer being freed was not allocated` between two back-to-back fixtures.

**The flag does not stop anything synchronously.** whisper.cpp only consults `abort_callback`
between decoder steps, so `whisper_full` keeps running for tens of milliseconds after
`requestAbort()` returns. `stopAsync` set the flag and returned, which left a decode live on the
bridge while the caller tore the transcriber down and started the next recording. Fix:
`drainInFlightEagerPass()` — set the flag, poll `isProcessing` to a 400 ms ceiling (matching the
in-flight-chunk drain), then `resetAbort()`. The wait is cheap because it only happens when a pass
is genuinely in flight, and an *aborting* decode returns in tens of ms rather than the ~1.4 s a
full pass takes. `resetAbort()` matters as much as the wait: the flag is bridge state, and leaving
it set makes the next session's first decode return -9 immediately.

**Return code -9 means "you asked me to stop"** (`whisper.cpp:7475`) and is indistinguishable by
code alone from a genuine decode failure. `WhisperBridge` counted it toward
`maxConsecutiveFailures = 2`, which schedules `recoverContext()` — a full free-and-reload of the
whisper context. Every stop that reuses a live eager preview calls `requestAbort()`, so two stops
in a row were enough to tear down a perfectly healthy GPU context mid-session.

**Third defect found in the same read:** `recoverContext()` hardcoded `cparams.use_gpu = true`.
The preview/detector bridge is created CPU-only on purpose (Metal contention with the main model
freezes the HUD); a recovery silently promoted it to the GPU, with no log line saying so. It now
reloads with `self.useGPU`.

### Cap size does not move p50 — the ANE encoder pads the mel to 30 s regardless (2026-08-16)

Sweep of 7 validated recordings × caps {4, 6, 8, 12, ∞} at real-time feed, uncapped arm measured
twice as the noise floor:

| cap | p50 ms | mean lag | worst lag | worst pass | mean WER |
|-----|--------|----------|-----------|------------|----------|
| 4   | 1563   | 4.4s     | 9.4s      | 2158 ms    | 0.206    |
| 6   | 1576   | 0.6s     | 4.6s      | 1740 ms    | 0.186    |
| 8   | 1498   | 0.1s     | 2.6s      | 1722 ms    | 0.181    |
| 12  | 1357   | 0.0s     | 1.6s      | 1723 ms    | 0.198    |
| ∞   | 1411   | 0.0s     | 0.0s      | 3433 ms    | 0.215    |

**p50 cannot resolve this axis** and never will on an ANE encoder: the mel is padded to a fixed
30 s whatever the window, so shrinking the window removes decoder tokens only. The uncapped arm
repeated at 1411 and 1409 while cap 12 measured 1340 and 1548 — the ~200 ms spread between caps is
machine state. **WER cannot either**: one fixture scored 0.136 and 0.245 across the two identical
uncapped runs.

**Lag is the monotonic discriminator.** Small caps do not make passes faster, they make each pass
cover less, so the window falls behind live audio — 4.4 s mean, 9.4 s worst at cap 4. That is live
text seconds stale on a long recording, and WER on the *final* text cannot see it. Cap re-elected
8 → 12: the mean window is only 4.4 s even uncapped (the agreement boundary keeps it short) so 12
almost never binds, but when it does it bounds the pathological tail (1723 ms against 3433 ms).

### Skipping the anchor check after a boundary move: hypothesis refuted (2026-08-16)

Held passes are 40% of all passes, and the two anchor failures have different causes:
`unanchoredSameStart` is real decoder instability, while `unanchoredAfterBoundaryMove` is the
window being re-cut at the boundary word's `startIndex`, so the leading word is decoded from a
clipped span. Skipping the check on that second case looked free.

It halved held passes exactly as predicted (40% → 20%) and was decisively wrong on everything
else: WER 0.364 → 0.739, duplicate runs 4.8 → 17.2 per fixture, monotonicity violations 20 → 24.4,
retracted chars 442 → 573. **0 fixtures improved, 7 regressed** (worst 0.929 → 3.557). The held
passes are the price of correctness, not waste — the recovered decodes were spent producing text
that had to be thrown away. `skipsAnchorCheckAfterBoundaryMove` stays `false`.

### Duplicate words come from a decoder repetition spiral, not timestamp jitter (2026-08-16)

The standing hypothesis was that duplicates came from a confirmed tail being re-emitted with
jittered timestamps. Instrumented as `repeatedConfirmedTails` (`rpt` in the profile): 0–4 per
fixture while `dupes` ran 0–23. Largely refuted.

The real mechanism is a whisper repetition loop **amplified by LocalAgreement-2**. The algorithm
cannot distinguish a stuck decoder from a person repeating themselves: two consecutive windows
both emit the phrase, so it agrees, so it is confirmed — and once confirmed it enters
`initial_prompt` for the next pass, which primes the model to say it again. On the VAD path this
stayed inside one chunk and was bounded by `max_tokens`; on the eager path it compounds. Fixture
`5f64f423` confirmed "я не знаю, что" nine times in a row: dupes 23, WER 0.929 against a reference
containing it once.

Guard (`EagerStreamEngine.confirm`, flag `suppressesRepetitionLoops`): a run of up to 5 words may
be confirmed twice back-to-back; an immediately following identical run is dropped. A count rather
than a similarity score, and deliberately permissive — real speech does say "no no" — while a
decoder loop overshoots on the third pass and every pass after. Only *adjacent* repeats count. A
`committedTail` carries the last few confirmed words across a soft-commit, so a loop straddling a
commit boundary does not restart its count from zero.

### A transliterated reference makes WER meaningless — report the median too (2026-08-16)

Fixture `004a0565` scores 1.000 in every arm of every run. Its audio is English; the transcript
the app stored is English transliterated into Cyrillic ("Тудей из Бьютифул Дэй"), so a perfect
decode still misses every word. Unlike `05011586` this is not a truncation case — the audio and
reference cover the same speech — so `loadEagerCorpus` keeps it and `reportArmComparison` prints a
median WER column next to the mean instead. One fixture can pin a corpus mean on its own.

### The repetition spiral is intermittent — one paired run cannot price a guard against it (2026-08-16)

Two identical paired corpus runs (8 real recordings, `suppressesRepetitionLoops` off vs on, same
audio, real-time feed) two hours apart:

| | raw mean / median WER | guarded mean / median | duplicate runs |
|---|---|---|---|
| run 1 — spiral fired on 2 fixtures | 1.081 / 0.350 | 0.360 / 0.198 | 31.2 → 3.2 |
| run 2 — spiral fired on 0 fixtures | 0.330 / 0.185 | 0.334 / 0.198 | 3.5 → 3.1 |

In run 1 the guard took `07642168` from WER 3.210 to 0.155 (96 duplicate runs → 4) and `5f64f423`
from 3.400 to 0.682 (143 → 13). In run 2 the *same* recordings produced no spiral in either arm
and the two arms tied, both inside the ±0.1 single-run noise floor, with three fixtures nominally
worse by 0.013–0.033 and two nominally better by 0.018–0.021.

The generalisable point: **a guard against a low-frequency catastrophic mode cannot be evaluated
by a corpus mean from a single paired run.** On a run where the mode does not fire the guard looks
like a tie and is easy to argue away; on a run where it does it is worth three WER points. Value
it on the worst case it prevents and the cost it charges when idle — here, three points and zero.

### One 197s "pass" that did not reproduce, and the instrumentation left behind (2026-08-16)

Run 1's guarded arm on `5f64f423` reported `maxms 197665` against a p90 of 1381 ms. It cannot have
been a real decode: the same 203.7s fixture completed 128 passes averaging ~1.35 s, which already
fills the wall clock. `decodeMs` spans submit-to-callback, so it also counts time queued behind
another operation on the bridge's serial queue and time blocked on `ctxLock` — both plausible, but
neither reproduced on the re-run (max pass 1939 ms, no outlier warning, no `-6`).

Not chased further; instead `EagerPassCollector.record` now logs any sample over 5000 ms with its
window, lag and word count, because those three numbers distinguish a slow decode from a queued
one immediately. An unexplained outlier with a trap set for it beats a speculative fix.

### An abort surfaces as -6 as well as -9, depending on which stage was running (2026-08-16)

The abort guard added earlier covered only `-9` (decoder loop, `whisper.cpp:7475`). A corpus run
then logged `❌ Whisper transcription failed with code: -6 (failure 1/2)` one line after
`Eager stop drained in-flight pass in 120ms` — the drain working exactly as designed and being
recorded as a fault. `-6` is "failed to encode" (`whisper.cpp:7037`), returned when
`whisper_encode_internal` sees the same abort callback at `:2455`. Both codes are now suppressed,
and only while `shouldAbort` is set: outside a stop the flag is clear, so a real -6/-9 still counts
toward `maxConsecutiveFailures`.

### A richer `initial_prompt` made transcription worse on this corpus, twice (2026-09-01)

`wparams.initial_prompt` has always been wired end to end and fed only the user's hand-typed word
list. The obvious upgrade — bias the decoder with vocabulary mined from the user's own history and
from the destination app — was built (`PromptContextBuilder`, `PromptVocabularyCache`), measured
against a pre-registered verdict rule, failed it twice, and was **reverted**. The code is gone; this
is the record of why, so it is not rebuilt on the same theory.

The bench: 40 paired real-audio decodes through the real `StreamingTranscriber`, arm A with no
prompt, arm B with the built one, arm A always decoded first so thermal drift penalised B.

| Metric | Bar | Run 1 (naive miner) | Run 2 (fixed miner) |
|---|---|---|---|
| WER vs decode gold, delta | ≤ +0.005 | +0.0423 | +0.0142 |
| Prompt leakage | 0 | 7 | 1 |
| Recovery (better / worse) | better > worse | 1 / 26 | 4 / 12 |
| Decode p50 | ≤ +5% | +0.37% | +0.21% |

**Run 1's miner was genuinely defective, and the defect is a general one.** `isDistinctive` treated
any leading capital as a proper noun, so the prompt whisper actually received was
`Like, I'm, Let's, The, This, Also, Prefect, What, 364, Docs, Google, How, It's, Let, MCP, Not, …`.
Sentence-initial function words are the *most frequent* capitalised tokens in any transcript, so
frequency ranking promoted them rather than suppressing them — the opposite of what the code's own
comment predicted. Six of the seven leaks were exactly those words.

The discriminator that fixes it: a real proper noun is almost never written lowercase, so a
capitalised term that also appears lowercase somewhere in the same corpus was capitalised by
position. That plus a two-sighting minimum produced a clean prompt —
`I'm, Prefect, 364, Docs, Google, Let, MCP, Parakeet, Wow, Linkerd` — ten genuine terms, 65 chars,
well inside budget.

**Run 2 is the finding.** Every metric improved sharply and not one cleared its bar. A tightly
relevant, correctly mined, short prompt of real proper nouns still cost 1.4 WER points, still
leaked (`parakeet` into a recording that never said it), and still made three times as many
recordings worse as better. Prompt biasing is not a free lever that was merely being fed badly: on
this corpus it is a net negative even when fed well. Latency was never the problem — the prompt is
essentially free at +0.2% p50.

Two consequences worth carrying:

- The `StreamingTranscriber` preview carve-out (`:1698-1720`), which withholds prompt words from
  short preview windows because they "strongly bias ambiguous audio", is now supported by measured
  evidence on full windows too. Do not weaken it.
- The user-typed `promptWords` list is untouched and still ships. An explicit instruction from the
  user is a different thing from vocabulary we inferred: it carries intent, it is small, and the
  user can see and remove it. Nothing here argues against it — only against inferring more.

### The explicit-correction W1 retry has no certifiable corpus yet (2026-09-01)

A narrower retry was specified: only user-created dictionary corrections, and only after an
unprompted hypothesis supplies alias/strict phonetic evidence. Built-in packs, history mining,
destination context, and W2 collection-only candidates are excluded; short-preview prompt
carve-outs remain untouched. The fixed gate is mean WER delta ≤ +0.005, zero negative-control
leakage, more positive recordings improved than worsened, and decode p50 ≤ +5%, all against frozen
authored gold. See `docs/exec-plans/explicit-correction-prompt.md`.

The local database contained zero non-built-in dictionary entries. Therefore there were no eligible
corrections, no recordings whose selection could be grounded in explicit correction evidence, and
no honest way to author the required positive gold population. Existing recordings containing
proper nouns are not substitutes: assigning them invented aliases would choose the answer after
seeing the corpus, while using their stored same-model decode as gold cannot score improvement.

Verdict: **UNMEASURED, runtime reverted/not landed**. W1 remains rejected until W2 produces reviewed
corrections plus subsequent real recordings sufficient to certify the pre-registered population.

## Dictation-to-injection latency: measured breakdown (2026-09-03, n=7)

All measurements in the same target app with the same app's `restoreDelayByBundle`.

| Stage | Log markers | Median | Range |
|---|---|---|---|
| Stop plumbing | `Shortcut RELEASED` → `rec.stop` | 0.032 s | 0.022–0.049 |
| Eager-stop reuse decision | → `Hybrid preview check` | 0.018 s | 0.012–0.695 |
| Drain in-flight eager pass | → `Eager stop drained` | 0.265 s | 0.016–0.396 |
| Tail setup | → `Transcribing tail:` | 0.081 s | 0.060–0.547 |
| **Tail whisper decode** | → `rec.stop chars=` | **1.350 s** | 0.690–1.993 |
| Polish (mmBERT) | → `polish:` | 0.060 s | 0.035–0.103 |
| Clipboard paste + restore | → `Dictated text entered` | 0.128 s | 0.126–0.220 |
| **Total** | | **2.03 s** | 1.15–3.31 |

Paste is not perceived latency: `enterViaClipboardPaste` posts Cmd+V *before* the
`restoreDelayByBundle` sleep. Perceived latency is ~1.9 s; the injector is not the target.

The tail decode cost is **uncorrelated with tail audio length** (1.8 s audio → 1.99 s; 3.8 s
audio → 1.35 s) and quantized in ~0.67 s steps, suggesting encode-count multiples. Use the
`tail.timing` log line (added by B1 instrumentation) to distinguish encode-loop, decoder-loop,
and normalization as the dominant factor.

## Why short dictations confirm nothing (the 8.6 s language-decision delay)

LocalAgreement-2 skips confirmation when `languageIsLocked == false`. It is false until the
language is decided. The decision was delayed by:

1. `firstProbeSamples = 80,000` (5 s) total-audio gate before the first probe fires
2. `minVoicedFirstProbeSamples = 40,000` (2.5 s) voiced-audio gate (both gates required)
3. V3 probe blocked on `ctxLock` by the live decoder: observed 3.245 s in the 2026-09-03 log
   (logged as `Language probe (V3): … in 3245ms`)
4. MLX was skipped whenever an eager pass was decoding (`!whisperDecoding` guard), so every
   first probe fell through to V3 despite MLX being ~10× faster

Combined: ~8.6 s minimum before any language is decided. For 59 % of dictations (median 4.9 s)
the key is released before the language is ever decided → 0 / 22 confirmations for dictations
under 10 s.

**Fixed (Levers A1–A3, 2026-09-04):**
- A1: single-language users now pass the sole allowed language as the concrete `startLanguage`,
  making `languageIsLocked == true` from pass 1 (no probes needed)
- A2: `firstProbeSamples` lowered to 24,000 (1.5 s), `minVoicedFirstProbeSamples` to 16,000
  (1.0 s); a `minFirstProbeConfidence = 0.80` floor at `recordAccurate` admission compensates
  for lower-quality short-audio probes
- A3: MLX restricted to `isFirstProbe` (was: blocked by `!whisperDecoding`), eliminating the
  ctxLock block on the first probe for multi-language users

Verification target: first non-`auto-detect` `Language: <lang>` line should fall from ~8.6 s
to ~2–2.5 s after key press. `Eager stop: tail starts at agreement boundary` should begin
appearing for 5–10 s dictations (was 0/22).


## Two-encode discovery: `.auto` language costs double (confirmed 2026-09-04)

The ~0.67 s quantization in tail decode (0.690 / 1.350 / 1.993) is **encoder-count multiples**,
confirmed. When `language == "auto"`, `whisper_full` calls `whisper_lang_auto_detect_with_state`
which runs a full `whisper_encode_with_state` before the transcription encode. Every `.auto`
decode pays **two encoder passes** (~660 ms each on this hardware).

Two artefacts hid this:
- `whisper_get_timings().encode_ms` is **average** per encode, not total
  (`t_encode_us / max(1, n_encode)` at `whisper.cpp:4251`)
- `encoder_begin_callback` is not invoked by the language-detect encode, so the B1 `encodes=1`
  counter under-reported by one

**Fix (2026-09-04):** Agreement ratchet in `StreamingTranscriber.runEagerStreamPass` harvests
`WhisperBridge.lastDetectedLanguage` after each eager pass. Two consecutive passes agreeing on the
same language → pin via `LanguageRouter.adopt` + `pinNemotron`. Pinned passes use a fixed
language code, skip the language-detect encode, and halve the per-pass cost (~660 ms → ~330 ms
per encode). Expected: tail decode ~1373 ms → ~690 ms; total perceived latency ~2.03 s → ~1.1–1.2 s.

MLXLanguageDetector removed entirely: on measured English speech it returned `yi p=0.495`,
`hr p=0.279`, and `it p=0.966` — whisper returned `en p=0.980`, `en p=0.836`, `en p=0.805`
on the same audio. Whisper's per-pass detection (used as the free by-product of the existing
language-detect encode) is the reliable source.

## A1–A3 outcome (2026-09-04): mechanically correct, no observed latency change

The A1/A2/A3 changes from 2026-09-04 were correctly implemented:
- A1: single-language users get a concrete `startLanguage`, bypassing the detection path
- A2: first-probe gates lowered to 1.5 s audio / 1.0 s voiced; 0.80 confidence floor added
- A3: MLX restricted to `isFirstProbe` instead of being blocked by `!whisperDecoding`

But the gate issue was never the bottleneck: MLX probes fired successfully (235–468 ms each)
and were confidently wrong. No probe landed, language stayed `.auto`, every pass paid 2 encodes,
and latency was unchanged. Superseded by the two-encode discovery and agreement ratchet above.

The A1 contribution remains: single-language users skip detection entirely, which is correct
regardless. `minFirstProbeConfidence`, `firstProbeSamples`, and `minVoicedFirstProbeSamples`
removed along with MLX.

## The stop watchdog's liveness signal has now been the wrong layer twice (2026-09-16)

2026-08-20: a tail decode ran long without setting `isProcessing`, the stop watchdog saw silence and
force-idled. Fix: set `isProcessing = true` around the tail decode — the comment is still at the top
of `transcribeTail`.

2026-09-16: the Nemotron preview feed chain blocked stop for ~29 s without setting `isProcessing`,
the stop watchdog saw silence and force-idled — this time destroying the recording (see
`audio/knowledge.md`). The tempting fix is identical: teach the watchdog about one more component.

Two occurrences of the same failure mode mean the component-by-component liveness patch is not a
fix, it is a list that grows every time someone adds an `await` to the stop path. The 2026-09-16
change kept a heartbeat (`lastActivityAt`, folded into the `isProcessing` setter so *every* call site
is covered at once rather than enumerated) but treated it as a backstop, and put the real fix one
layer down: the stop path no longer performs an unbounded wait at all. The watchdog's absolute
ceiling went 20 s → 90 s for the same reason — with the stall gone, the ceiling is a guard against a
genuinely wedged decode (SafeLock held, Metal failure), not a cap on legitimate work.

Diagnostic signature of this class: the log shows an ordinary `rec.stop`, then a `Stop watchdog`
line a few seconds later, then the *real* transcription completing tens of seconds after that with
more text than the row was saved with. Any time completion text is longer than stored text, a
watchdog beat the pipeline.

## Qwen3-ASR backend (2026-09-26)

- The UniMocha CoreML export (`Qwen3-ASR-1.7B-CoreML-INT8`) is unusable for dictation: its decoder takes exactly one token per call (`input_embeds [1,1,2048]`), ~70 ms/step on M2 Pro on GPU (ANE refuses it with error -14), so the 12.5 audio tokens per second of speech each cost a separate call. That caps it at ~1× realtime. Its embedding model also cost 9–16 ms per token lookup.
- The MLX port (`Whisperer/Transcription/Qwen3ASR/`, weights `mlx-community/Qwen3-ASR-1.7B-8bit`) prefills the whole prompt in one pass: in Debug on M2 Pro, 9.7 s of audio → 1.19 s total (encode 70 ms, prefill 200 ms, ~23 ms/token).
- The correct prompt is `<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>{pad×N}<|audio_end|><|im_end|>\n<|im_start|>assistant\n`; the model answers `language X<asr_text>text`. Appending `language X<asr_text>` forces the language. The CoreML build used a chat prompt ("You are a helpful assistant…") and stripped the header by token id, which leaked "language None" / "language English" into history titles.
- The audio tower chunks mel into 100-frame pieces (13 tokens each, positional embedding restarts per chunk) and attends in windows of 104 tokens. A full-length conv (400 frames → 50 tokens instead of 52) is not the trained model.
- Live preview with a slow serial backend: if a pass starts while the previous one is still in flight, every result arrives stale and is discarded. Gate preview passes on backend idleness.

## English decoded as Russian (2026-09-26)

- Config: allowed [en, ru], primary en. Qwen3-ASR as ground truth: 7 of the 10 history recordings stored as `ru` are English speech.
- The 10 s V3 language probe is **not** the cause: on those same recordings it answered `en` in 30/30 cases (`LanguageArbitrationCorpusTests`, opt-in).
- Actual paths that produced Russian: (1) eager passes decode as `.auto` before any evidence, and whisper's per-pass detection picks `ru` on a few seconds of accented English and emits Russian words (R5 `2026-09-20_11-55-41`: 28 Cyrillic words at logProb −0.57, while the probe later said en 0.765); (2) a weak probe (ru 0.55–0.70) becoming the arbiter's leading candidate and driving provisional or tail decoding.
- Signature of the wrong language: logProb gets worse once forced (R135 −0.6 → −2.1). Genuine Russian decodes at about −0.1.
- Fix: the non-primary switch gate (`StreamingTranscriber.languageSwitchGate`). The last 8 s are decoded forced to the primary and forced to the candidate; the candidate is allowed only if its avg logProb leads by ≥ 0.10. Measured leads: correct language ahead by 0.20–1.05 in 29/30 corpus rows plus all 5 gate-test recordings. `.auto` eager passes that detect a non-primary language are held until verified.

## Merging a monolingual fine-tune into Qwen3-ASR (Caspi/Hebrew, 2026-10-04)

`OzLabs/Caspi-1.7B` is a Hebrew fine-tune of Qwen3-ASR-1.7B and a drop-in weight swap: 707/707
tensors match the mlx-community layout after stripping the `thinker.` prefix and transposing the
three `audio_tower.conv2d*.weight` from NCHW to NHWC. It is CC-BY-NC-4.0, so nothing derived from
it is shippable; the base is Apache-2.0.

Used alone it is catastrophic for every other language — it emits Hebrew for English audio *even
when the language is force-prompted to English*, so the damage is in the weights, not in detection.

Task-vector interpolation `W = W_base + λ(W_caspi − W_base)` was measured across λ. The per-tensor
delta map explains the behaviour:

- Overall delta is small — median 6.4%, mean 8.1% — i.e. the fine-tune stayed in the base's loss
  basin, which is why interpolation works at all.
- The entire top-25 by relative delta is `audio_tower.*`, peaking at **52% on `audio_tower.proj2`**
  (the projection from the audio encoder into the decoder hidden space). The text decoder barely
  moved.
- `model.embed_tokens` changed only 16.6% (rank 140 of 707). An "embeddings are the culprit" fix
  was built and failed — still all-Hebrew.

Language tolerance to λ is wildly uneven, and **English is a dangerously misleading probe**:

| λ | Russian | English | Hebrew |
|---|---|---|---|
| 0.2 | ok | ok | slight gain (`אובד נחון` → `עובד נכון`) |
| 0.25 | mixed-script corruption | ok | ok |
| 0.3 | destroyed | ok | ok |
| 0.5–0.9 | destroyed | ok on long audio, flips to Hebrew on <3.5 s windows | ok |
| 1.0 | destroyed | destroyed | perfect |

- English survives to λ=0.9 on a full sentence because it dominates pretraining. Russian breaks at
  0.25. **Validating a merge on English alone overstates the usable λ by ~4×.**
- Evaluate on the window sizes the preview loop actually uses (0.35–3.5 s), not on a clean
  full-length clip. At λ=0.9 a 6 s English clip decoded perfectly while 0.55 s and 1.05 s prefixes
  both detected `he`, which trips the two-pass ratchet in `Qwen3ASRBridge` and pins Hebrew for the
  rest of the dictation.
- At λ=0.9 the English content was transcribed *correctly and then written in Hebrew*
  (`אני רוצה לנסות את זה עוד פעם` = "I want to try this again"), which looks like a decoder
  language-prior bug and is not one.

Layer-split merges were tried and none separate the abilities:

- Base decoder + full Caspi audio tower: English clean, but Hebrew **romanises**
  (`Ani rotsce l'ibdokk...`) and Russian still breaks — proving the loss is in the encoder, since
  the decoder was untouched.
- Full Caspi audio tower + decoder at λ=0.3: English clean on every window, Hebrew in correct
  script — but Russian comes out as Hebrew-letter transliteration (`יהיה חתשיו פרבירית` for
  "Я хочу проверить").
- Keeping base `audio_tower.proj1/proj2` while taking Caspi elsewhere: no effect, still all-Hebrew.
  The Hebrew bias is distributed across the whole tower, not concentrated at the interface.

Conclusion: a monolingual ASR fine-tune's gains and its multilingual damage live in the *same*
audio-tower parameters, so no λ and no layer split recovers both. λ=0.2 is the ceiling for a single
merged checkpoint that keeps Russian. Caspi-grade Hebrew requires loading Caspi as a separate
checkpoint under an explicit language selection (load is ~1.4 s, so swapping outside recording is
imperceptible).

Tooling: `~/Documents/huggingface/_merge/` holds `build_merge.py` (streaming merge — `mx.load`
mmaps and MLX arrays are lazy, so peak RSS tracks output size; an eager dequantise-everything
version needed ~21 GB and froze the machine), plus the base and Caspi sources. Quantise to match
the base layout exactly: scales/biases are keyed `foo.scales`, **not** `foo.weight.scales`, the
text decoder is 8-bit group-64, and the audio tower stays bf16.

## Qwen3-ASR as the default engine — measured baseline (2026-10-07)

Measured by `WhispererTests/Qwen3GateBenchmarkTests`, 60 clips from the user's own history,
Apple M2 Pro. There is no human ground truth for this corpus, so the metric is **medoid
consensus**: every engine decodes the clip, the hypothesis with the lowest mean WER to the others
becomes that clip's reference, and each engine scores against it. `medoid%` is how often an
engine *was* that reference. This identifies the odd one out; it cannot prove correctness.

`GoldenSet` is deliberately **not** used for cross-engine comparison. It is a whisper.cpp
full-file decode, so whisper.cpp scores ~0 against it by construction — a rigged comparison. It
remains correct for its own purpose: measuring what windowing costs one engine.

| engine | clips | meanWER | medoid% | RTF |
|---|---|---|---|---|
| qwen3 | 60 | **0.037** | **41.7** | 10.7x |
| whisper-v3 (`.largeTurboQ5`) | 60 | 0.055 | 35.0 | 12.5x |
| parakeet-v3 | 60 | 0.085 | 23.3 | 83x |

Per language: English 0.039 / 0.072 / 0.090 (Qwen3 clearly ahead). Hebrew 0.017 / 0.013 / 0.068
(whisper-v3 marginally ahead, inside the 0.02 noise band). No engine returned an empty decode.

Streaming, same machine: 21 preview updates on a 9.7 s clip, first word under 1 s, stop-to-final
1.57 s, batch RTF ~5x on short clips and ~13x on 20 s clips.

### The history language column is not a label

The first Hebrew specialist run scored `ivrit-v3-turbo` at WER 0.749 against Qwen3's 0.000. That
number measured the corpus, not the model: of 12 clips tagged `he` in `ZTRANSCRIPTIONENTITY`,
most were English or Russian speech. Both engines were force-decoded to Hebrew; the specialist
obediently transliterated English and Russian into Hebrew letters
(`תקסט שאת פרופאה בגרית` for `Я хочу проверить`), while Qwen3 ignored the forcing and emitted the
right language.

**Rule: never select a per-language benchmark corpus by `RecordingFixture.language`.** Run an
auto-detect pass and select on the script of the output. `Qwen3GateBenchmarkTests
.testHebrewSpecialistVersusQwen3` now does this via `ScriptAnalyzer.dominantScript`.

Second: a forced language is obeyed differently by the two engines. Whisper transliterates
mismatched audio into the forced script; Qwen3 overrides the forcing and reports what it heard.
That makes Qwen3 safer under a wrong language pin and makes any forced-language comparison
between them invalid unless the audio really is that language.

### Hebrew: Qwen3 loses, decisively

On **56 clips confirmed Hebrew by script** (not by the history language column), same harness:

| engine | clips | meanWER | medoid% | RTF |
|---|---|---|---|---|
| ivrit-v3-turbo | 56 | **0.183** | **64.3** | 14.9x |
| qwen3 | 56 | 0.341 | 35.7 | 7.3x |

The gap is visible in the text, not just the number. Qwen3 invents words and bleeds Cyrillic into
Hebrew sentences (`הם נסע לא видл אתו צה"ל od מודי חותית`) where the specialist reads cleanly
(`אני מנסה להעביר לתוצאה מאוד מאוד איכותית`). Qwen3 is also *slower* on Hebrew — 7.3x against
14.9x — because garbled output generates more tokens.

Two consequences, both implemented:

1. `RefineModelTable.specialistsBeatingQwen3[.hebrew] = .ivritLargeTurbo`. Hebrew meetings still
   get the post-recording second decode; every other language skips it.
2. `BackendType.weakLanguages` and `defaultBackend(for:)`. A Hebrew user is defaulted to
   whisper.cpp even on a machine where Qwen3 is cached, the Models tab does not recommend Qwen3
   to them, and the 2.5 GB upgrade card is not shown. Qwen3 remains selectable — weak is not
   unsupported.

The general rule this is an instance of: **a leaderboard-leading multilingual model can still
lose badly to a monolingual fine-tune, and "supports the language" is not "is good at it".**
`supportsLanguage` answers the first question; `weakLanguages` answers the second, and only ever
from a benchmark run.

### Latency and long-session behaviour (same harness)

Time to first preview word, measured from when *speech* is fed rather than from `start()`:
2.07–3.43 s across repeat runs on the same clip, tracking an RTF that moved 9.5x → 8.3x with
background load. About 1.4 s of that is the language-agreement ratchet in `Qwen3ASRBridge`,
which withholds an unpinned auto-detect preview until two consecutive passes name the same
language — a deliberate trade against the stray misdetected first character. Timing assertions
on this are bounds against collapse, not targets; the variance under load is larger than any
regression worth catching that way.

20.4 minutes of concatenated audio, fed at 4x: 1642 preview updates, 0 retractions, 2791 final
words, stop-to-final 1.12 s, no production-threshold repetition loop.

**Feed rate must stay inside the engine's throughput.** An earlier version of this test fed at
20x, above Qwen3's ~9x. Committed chunks could not keep up, the uncommitted tail grew for the
whole session, and the stop-path decode of that tail took **19.3 s**. Dropping to 4x took the
same measurement to 1.12 s. The 19.3 s was the harness outrunning the engine, not a defect — but
it does describe a real overload mode, and it is the reason the live preview sheds work when the
chunk backlog exceeds 10 s.

### Two repetition guards added, neither of which fired on this corpus

The long session produced `в глубь,` three times back to back — a phrase in none of the source
recordings. Investigating it added two guards that are correct on their own merits:

- `Qwen3ASREngine` stops a greedy decode once `TranscriptRepetition.containsLoop` fires on the
  text so far. Greedy decoding has no escape from a repetition attractor; without this the loop
  runs to the token budget.
- `StreamingTranscriber.createsSeamLoop` drops a chunk whose arrival would repeat a phrase
  across the seam. `isHallucination` inspects one chunk in isolation and is blind to a decoder
  emitting one copy per chunk.

Neither explains the observed case: `в глубь,` is a **two-word** phrase, and
`TranscriptRepetition.minimumPhraseLength` is 3 by deliberate choice ("that's it, that's it" is
ordinary speech). The observation is printed by the test and not asserted on — one occurrence on
60 unrelated clips welded into one stream does not justify lowering a tuned threshold.


## Bundled instant model (2026-11-02) — DROPPED 2026-11-03, kept for the measurements

- Shipped model: whisper **base q5_1** (59.7 MB; 52.9 MB as a lossless pack). It replaced tiny-q4_0 after the user found tiny "highly not accurate": on the one real-voice clip with a full reference, tiny-q4_0 made 4 word errors in 24, base-q4_0 2, **base-q5_1 0**, small-q5_1 2. Clean TTS did not separate the models (0-1 errors each), so synthetic audio is not evidence here. Beam 5 did not help tiny. Evidence is one real clip: re-measure on more real recordings when they are available.
- Smaller quantizations don't load: k-quants use 256-element blocks and whisper's tensors are 384 (tiny) or 512 (base) wide, so q3_k and q2_k fail with `tensor ... has wrong size`. Base q4_0 would be 46.5 MB raw, 38.2 MB xz.
- Pack: quantized blocks split into scale header and payload (Q5_1: 4 + 20 bytes), `encoder.positional_embedding` regenerated from its sinusoid with a patch list, LZMA2 lc/lp/pb=0. Lossless; the unpacked SHA equals the pinned source SHA. xz alone saves ~8% on q5_1 data, the pack ~11%.
- Measured on an M2 Pro, 17 s clip, greedy: tiny-q4_0 ~135 ms, base-q4_0 ~170 ms (150 MB peak), base-q5_1 ~210 ms (Metal).
- Whistle (Cactus, 16.9 MB, CPU-only closed `libneedle.a`, 7 languages, no Hebrew) was evaluated and not adopted: new backend with 20+ touchpoints, and no unload API.


## Omnilingual ASR (Meta CTC via speech-swift) evaluated, not adopted (2026-11-03)

Harness: `Tools/omni-eval/` (`build_manifest.py`, `build_cs.py`, `run_engine.py`, `run_ivrit.py`, `score.py`, `stream_sim.py`). FLEURS test, 100 distinct sentences per language, seed 42; hypotheses in gitignored `hyp/`. Runtime is the `speech` CLI (`brew install speech`, v0.0.29), MLX backend, M2 Pro. Corpus-level WER/CER after case, punctuation and diacritic folding.

| engine | he WER/CER | ru WER/CER | en WER/CER | code-switch WER | RTF | punct / case |
|---|---|---|---|---|---|---|
| Omni CTC 1B 4-bit | 71.6 / 24.1 | – | – | – | 0.03 | none |
| Omni CTC 3B 4-bit | 28.6 / 9.6 | 11.7 / 2.6 | 10.3 / 3.5 | 70.7 | 0.08 | none |
| Omni CTC 7B 4-bit | 26.3 / 9.1 | 10.1 / 2.5 | 9.4 / 3.2 | 78.0 | 0.17 | none |
| **ivrit-v3-turbo** (app's whisper.cpp, `-l he`) | **14.8 / 6.7** | – | – | 69.7 | 0.20 | yes |
| whisper-turbo (CLI, no language hint) | 28.6 / 12.4 | 9.8 / 5.9 | 8.0 / 5.0 | 68.7 | 0.2 | yes |
| Qwen3-ASR 1.7B | 77.2 / 43.1 | 6.4 / 2.3 | 4.1 / 1.8 | **55.4** | 0.07 | yes |
| Parakeet v3 | – | 5.1 / 1.6 | 5.2 / 2.4 | – | 0.014 | yes |

- **Verdict: fails the gate.** It loses to ivrit-v3-turbo on Hebrew (26.3 vs 14.8 WER) and to Qwen3 / Parakeet on Russian and English. It is not better on code-switching either.
- **Size matters a lot below 3B.** 1B is unusable for Hebrew: it merges words and bleeds Latin letters into Hebrew output. 3B → 7B gains only ~2 WER points at 2× the latency and 2× the memory, so 3B-4bit (1.7 GB) is the sweet spot if this is ever revisited.
- **Code-switch (40 synthetic 3-clip mixes, he+en and he+ru, sentence-level switches): every engine fails.** CTC commits to one script per window and renders the other-language sentence as phonetic gibberish in that script, or drops it. The "language-neutral, handles code-switching" claim does not hold. The test is harsh (hard cuts between sentences).
- **Output is lowercase with no punctuation** (0-10% of outputs have any). It would need the polish LLM as a final stage.
- **Streaming is re-decode only** (non-causal CTC, 40 s hard cap, no stream API upstream). Simulated eager passes at 2 s steps: 3B ~0.5 s per pass (max 0.9), 7B ~1.1 s per pass (max 1.9 s on a 14 s window). Hebrew partials are unstable: 16% (3B) / 23% (7B) of words outside the last two change on the next pass, against 1% for English.
- **Fragility:** both 3B variants emitted garbage on `jfk.wav` (exactly 11.000 s), while 1B and 300M Core ML were fine. Lengths 10.9-11.05 s failed and 10.5/11.5 s worked, but the 100 FLEURS clips of 10.5-11.5 s showed no failures, so it is clip-specific. A garbage-output check with a padded retry would be mandatory in any bridge.
- **Not evaluated:** Omni LLM variants (best paper numbers, Hebrew CER 6.7) because speech-swift ports only CTC v2, and Omni v2 / Unlimited.
- The XCTest target did not compile at HEAD when this ran (`StopPathDataLossTests.swift:49`, actor `SlowNemotronBridge` vs global-actor-isolated `NemotronBridging`); the ivrit run therefore used the vendored `whisper-cli`.


## Omnilingual LLM variants (CrispASR GGUF) evaluated, not adopted (2026-11-03)

Full report: `docs/knowledge/transcription/omnilingual-llm-benchmark-2026-11-03.md`. LLM-300M, LLM-Unlimited-300M and LLM-1B (q4_k, `cstr` GGUFs, CrispASR `3181f0f`, Metal) lose to Qwen3-8bit on en/ru and to Omni CTC 7B everywhere; Hebrew/Russian output has no word spaces. Their only advantage is a flat ~1.3-1.75 GB peak footprint (Qwen3-8bit 3.1 -> 6.8 GB from 5 s to 60 s; CTC 7B 5.6-6.8 GB). RTF 0.34-1.06, so no streaming or meeting use. The GGUFs ship placeholder `lang_codes`, so CrispASR silently conditions on English unless `-l lang_<parquet index>` is used. Gated at a 6-20 clip pilot; the full 340-clip run was not done.


## Live preview: Whisper Base vs Omni CTC 300M Core ML (2026-11-03)

Full report: `docs/knowledge/transcription/live-preview-whisper-base-vs-omni300m-2026-11-03.md`. The historical preview/detector model was Whisper **Tiny** (CPU-only `WhisperBridge`), never Base. FLEURS full 100 clips: Whisper Base (Core ML encoder, greedy) he 62.8 / ru 23.7 / en 9.9 WER; Omni 300M Core ML 10 s window he 50.5 / ru 30.6 / en 17.5, mixed set 49.1 vs 80-93. Per-pass compute 0.13 s vs 1.15 s (fixed-shape Core ML window). With Qwen3 final running, Qwen3 slowed +4% (Base, CPU decoder) vs +15% (Omni). The Base encoder plans 100% onto the ANE; Omni plans ~94-99% with ~20% of cost weight on GPU under default units. Verdict: no winner; neither is usable for Hebrew preview. ANE/GPU utilisation and energy were not measured (no sudo for powermetrics).


## Decision: Nemotron is the built-in engine; the bundled stand-in is dropped (2026-11-03)

Evidence: `live-preview-whisper-base-vs-omni300m-2026-11-03.md` and its addenda. Nemotron 3.5 0.6B is the only candidate that genuinely streams: text lags the speaker by 0.04 s, never revises what it showed, and the final text is ready 0.03 s after the audio ends (Qwen3's repeated decode: 0.49 s and 1.07 s). Full-set FLEURS WER with a language hint: he 43.6, ru 13.1, en 10.9; mixed 53.0.

**The design.** Nemotron is a *built-in engine*, not a choice:
- Always downloaded at startup (`AppState.startBuiltinEngine()`, called from launch, onboarding and every engine start) and kept resident. A backend switch never releases it (`previewOwnsNemotron` is permanent once started).
- It drives **live text** for the dictation HUD and the meeting live transcript whenever the selected engine is whisper.cpp or Qwen3 (`builtinEngineDrivesLiveText(for:)`). The selected engine still produces the **final** transcript from committed chunks. When no other engine is loaded, or the user has not picked one (`selectedBackendType == .nemotron`, the first-launch default), Nemotron transcribes on its own.
- It is in no picker. `BackendType.selectable` excludes it (and the Hebrew sub-backend); the Models tab shows a "Built-in engine" row: Downloading n% / Loading / Loaded / Not loaded, plus "Use alone" to make it the sole engine.

How it is wired: `StreamingTranscriber(nemotronPreviewOnly:)` generalises the existing whisper-eager preview-only mode to chunk engines. Every display write from the final engine goes through `emitDisplay`, which is swallowed while Nemotron owns the display; the engine's own preview loop is not started (it would burn GPU on swallowed text); a chunk commit no longer clears Nemotron's accumulated text. `MeetingCoordinatorFeed` selects `.accumulatedPartials` for Qwen3 when Nemotron is the live source. The download no longer calls `activateBackendAfterDownload`, so fetching the built-in engine never switches the user's engine, and it does not put the app in `.downloadingModel` unless Nemotron is the engine.

**Exception that contradicts "always": Hebrew.** The built-in engine's Hebrew is "adaptation-ready" in NVIDIA's card; on 100 FLEURS clips it scores WER 0.436 against ivrit-v3-turbo's 0.148. So for Hebrew (selected, or among routed languages) live text stays with the user's own engine, and the first-launch default is whisper.cpp. Remove `BackendType.nemotron.weakLanguages` to change that.

Not routed yet: Parakeet, WhisperKit and Apple Speech keep their own live text; whisper.cpp and Qwen3 are the two engines the transcriber swap was built and reasoned for.

Removed: the bundled base-q5_1 stand-in (`BuiltinModelStore`, `PrimaryInstallGate`, `WhisperModel.builtin`, the pack, its size script and tests). The bundled Silero VAD stays. Everything is backed up in `~/ai/whisperer-builtin-backup-2026-11-03/`. Consequence: a fresh install has no engine until the ~650 MB download finishes.

Stability: the speech-swift Core ML runtime leaked ~1 MB per audio-second and aborted at ~400 s, but Whisperer's FluidAudio `StreamingNemotronMultilingualAsrManager` (1120 ms chunks) held a flat **886 MB** across a 20-minute session and finished cleanly. The resident cost of the built-in engine is therefore ~0.9 GB. Not covered: a 180-minute session, and the live app; the Debug build compiles, but the XCTest target does not at HEAD, so the changed tests have not run.


## Decision: Apple dictation replaces Nemotron as the built-in engine (2026-11-04)

Supersedes the 2026-11-03 Nemotron decision above. Every streaming candidate (Nemotron, Omni, Whisper Base, Qwen3's repeated decode) was chunky, needed its own model, and competed with the user's engine for memory and GPU. The built-in engine is now Apple's on-device dictation, `SystemLivePreviewBridge` (`Whisperer/Transcription/SpeechAnalyzer/`). It drives live text only, in the HUD and the meeting transcript. Qwen3 or Whisper V3 still produces the final text.

**There are two Apple models, and only one of them has our languages.** Probed on this Mac (macOS 26, 2026-11-04):
- `SpeechTranscriber`, used by the existing "Apple Speech" final engine (`SpeechAnalyzerBridge`), has 45 locales and **no he-IL and no ru-RU**.
- `DictationTranscriber`, the System Settings › Dictation model, has 54 locales, including en, he and ru. The built-in engine uses this one.
- Do not "just switch on" `SpeechAnalyzerBridge` for live text. It is also batch-only: it passes `reportingOptions: []` and keeps only `isFinal` results.

**Measured** with `SystemLivePreviewTests`, real audio fed at wall-clock rate, preset `.progressiveLongDictation`:
- English: first words at 1.2 s, then a word every 0.2–0.5 s.
- Hebrew: first words at 0.7 s.
- `endSession` takes 0.08–0.17 s.
- Analyzer start costs 60 ms the first time and about 2 ms after that.
- A no-sandbox CLI and the test host needed no speech-recognition permission prompt.
- **Not yet verified:** the sandboxed app; see Open below.

**Gotchas:**
- Hebrew results start with U+200F. Strip it, as `clean()` does, or the text diffing downstream breaks.
- `AssetInventory.status` reports `.supported`, not `.installed`, for locales that System Settings installed. Read `DictationTranscriber.installedLocales` instead. `assetInstallationRequest` returning nil means the assets are present; it must run once per locale before use.
- No language detection: one locale per analyzer. In auto mode the session starts in the first installed preferred language. `pinLanguage` (driven by `LiveLanguageArbiter` through `pinNemotron(to:)`) retires the analyzer and starts a new one, carrying the text over.
- Russian is "supported" but its assets download only on request. System Settings shows "Russian will download later" until something asks for it. `AppState.installSystemLanguage` does that, from onboarding and from the Settings › Models "Live preview" row.

**Wiring:**
- `LivePreviewEngine` (formerly `NemotronBridging`) is `nonisolated`. Under default MainActor isolation it had been inferred `@MainActor`, which actors cannot conform to; that was the HEAD test-target compile failure.
- `builtinEngineDrivesLiveText` requires an installed language. Handing over the display switches off the main engine's own preview, so with no Apple assets the HUD would otherwise go blank.
- `builtinCovers`: while the user's engine is not loaded, Apple's text is the final dictation text.
- The default main engine is back to Qwen3 when cached, else whisper.cpp. Saved `.nemotron` choices migrate at launch.

**Open:**
- Run the live app: sandbox TCC for `DictationTranscriber`, a real meeting with speaker attribution fed by Apple partials (volatile revisions can shrink the text, and `MeetingSpeakerCoordinator` drops shrinking updates), and the Russian install end to end.
- No HUD hint yet when the session's language is still installing.


## Language ID for the built-in engine: restricted, calibrated language ID on the main engine (2026-11-04)

**Symptom:** with Apple dictation driving live text, English worked and Hebrew and Russian did not.
- Every session started in the primary language (en).
- The fused verdict pinned the real language 9–10 s in, longer than most dictations, so they showed wrong-language nonsense throughout.
- The 10 s voiced-sample floor on the old V3 detect is one cause of the delay.
- Apple's he and ru output were fine once the language was right.

**Ruled out:**
- Apple has no built-in language ID.
- `.transcriptionConfidence` is empty on volatile results.
- Racing en, he and ru Apple transcribers does not work: the wrong one emits fluent text in its own language as fast as the right one.

**First attempt, reverted the same day: a calibrated WhisperKit base on the ANE.**
- On FLEURS it looked best: 89/90 with the session rule, 141–178 ms per probe.
- On the user's own microphone it failed badly:
  - English → he 0.62–0.83.
  - Two Russian dictations → he 0.99 and he 1.00.
  - Each wrong answer was confident enough to commit at 1 s.
- **Rule this taught:** FLEURS read speech is not evidence for a language probe. Gate on real mic recordings (`WhispererTests/TestData/live-preview/`, `LanguageProbeBenchmarkTests.testRealRecordings`).

**What ships: `LanguageProbe` on the user's main engine** (no model of its own). It only identifies the language: Apple produces the live text, and the main engine the final text.
- **Qwen3-ASR:** prefill the audio prompt plus the `language` token, then read the logits of each candidate's name token (`Qwen3ASREngine.languageLogits`). One pass, no decode, ~90–125 ms on the GPU, on the bridge's serial queue. Fully silence-calibrated.
- **Whisper V3 (whisper.cpp), when it is the main engine:** `WhisperBridge.detectLanguage`, half-calibrated. Fully calibrated, it pulled the user's accented English to ru (0.57 at 3 s, Apple stayed in Russian).
- Restricted to the user's languages. Unrestricted, V3 called Hebrew "es" (eager pass) and FLEURS Hebrew "ar".
- No probe right after launch, before any engine has loaded. The session then keeps its sticky start, and the log says so ("Language probe: no answer").

**Gate, the user's 9 real dictations (3 en, 2 he, 4 ru) with the session rule:**

| Probe | Correct | Confident wrong windows | Per window |
|---|---|---|---|
| Qwen3, calibrated, first checkpoint 2 s | 9/9 | 0 | ~125 ms |
| V3 on the ANE, fully calibrated (shipped briefly, removed) | 8/9 | 0 | ~800 ms, 626 MB extra |
| NVIDIA AmberNet (ONNX) | 7/9 | 5 | 49 ms |
| SpeechBrain ECAPA (Core ML) | 6/9 | 3 | 7 ms |

- The acoustic models (ECAPA, AmberNet) fail on accented English: the user's English read he/ru at up to 0.95. The Whisper and Qwen3 models judge by the words. All four reach 87–90/90 on FLEURS, which does not separate them.
- **Qwen3 on 1.0–1.5 s is a coin flip between he and ru at p 1.00.** The user's 3.1 s Russian read he 1.00 from a window starting at 0.28 s and ru 1.00 from 0.06 s. From 2.0 s, all 18 windows (9 dictations × 2 starts) were right at 1.00. Hence `Source.earliestSeconds`: 2.0 s for Qwen3, 1.0 s for V3. English was right from 1.0 s on every window.
- Qwen's published LID table (Qwen3 1.7B 97.9% vs Whisper V3 94.1%) measures whole utterances unrestricted, so it says nothing about 1–2 s windows.
- **Correction:** the "V3 is 29/30 at 1 s" figure from `whisper-cli -dl -d 1000` was wrong. `-d` limits only the decode span; language ID ran on the mel of the whole clip.

**Session rule** (`SystemLivePreviewBridge`):
- Sticky start: begin in the last decided language (`builtinEngineLastLanguage`).
- Probe at the engine's first checkpoint (Qwen3 2.0 s, V3 1.0 s) and commit if p ≥ 0.8. From 1.0 s, if unsure, ask again at 2.0 s; if still unsure, take the 3.0 s answer. The 2.0 s step exists because the user's 9.6 s Russian read ru 0.64 at 1 s, and waiting for 3 s put Russian on screen at 4.3 s; with it, 3.25 s.
- An early commit is re-checked at 3.0 s, and only a confident re-check overturns it.
- When the probe corrects the language, restart the analyzer and **replay** the session's audio (up to 30 s held), dropping the wrong-language text.
- A later external pin carries the text over instead, because a mid-session pin means the language changed.
- **Pitfalls found on the user's recordings:**
  - Actor reentrancy let a second switch start while the first awaited Apple, which restarted twice. The language is now claimed before the first await.
  - Audio fed during a switch was lost to the new analyzer. The replay is now read from `sessionAudio` in the same turn that publishes the new input.
  - One-time costs inside the session (Apple's first per-process asset allocation for ru-RU, the V3 calibration encode) pushed the first Russian text to 4.8 s. `prepare()` pays them at engine start.
- **End to end**, real-time feed and deliberately wrong start, on the user's recordings: ru (en start) 2.16 s, short ru (he start) 2.00 s, he (ru start) 2.03 s, en (he start) 1.03 s.
- Test-host pitfall: the test host shares the app's defaults, so an auto-mode test starts in the user's last language unless it sets `builtinEngineLastLanguage`.

**Meetings:**
- Apple's volatile text cannot feed `MeetingSpeakerCoordinator`, which rejects rewrites.
- With continuous speech Apple finalizes only at a pause: 34 s of read Russian produced one final, at the end, even with `.frequentFinalization`.
- So the bridge commits words by local agreement and passes only committed words to the coordinator, through `MeetingTranscriptAccumulator`:
  - A word is committed when it is unchanged across 3 consecutive updates and is not among the last 3 words.
  - Nothing is committed until the probe has decided.
- The volatile remainder is shown after the coordinator's pending tail.
- `prepareMeetingASRBridge` no longer falls back to Nemotron. It uses resident Qwen3, else the user's resident engine with Apple live text, else a fresh Qwen3 load, else loads the user's engine.

## Apple dictation live text: "installed" lies, and a missing language was a silent blank (2026-11-05)

- **Neither Apple signal alone is "installed".** An `AssetInventory.assetInstallationRequest(supporting:)` that comes back non-nil does not mean the assets are missing: on a second Mac (system Dictation off) Apple returned one for en, ru and he every time, and completing it took 0.4 s (a real download took ~25 s) — it is the step that allocates the locale to this process. Two consequences, both corrected 2026-11-05: (1) `startAnalyzer` refused to start whenever a request came back, so that Mac never streamed ("assets not installed" every session); it now completes the request within a 3 s budget and lets a longer download continue in the background. (2) A status check that read the request as "not installed" re-ran the install at every session start and kept the installing banner up. Status is now: in `installedLocales`, or no request → ready; an install that completed this run stays ready until relaunch.
- Handing the display to Apple used to require only that *any* configured language be ready. A session in an uninstalled language then swallowed the main engine's preview (`nemotronIsPreviewOnly`) and showed "Listening…" for the whole session. In meetings it was worse: the `.accumulatedPartials` feed takes committed words only from Apple's stable-text callback, so the meeting saved `segments=0`. Now: the decision is per session (`builtinEngineCanStreamSession`), the transcriber falls back to its own preview when the live engine reports `isStreaming() == false`, and the meeting commits the engine's chunks unattributed after a fallback.
- With routing on, the transcriber's start language is `selectedLanguage` (default `.english`), and it was passed to Apple as an explicit language: Apple transcribed every session in English, the probe never ran, and the fused-verdict pin was blocked. Preview-only live engines now open in `.auto` whenever the language router decides.
- A mid-session switch to an uninstalled language keeps the old analyzer (a meeting must not lose its live text) but is reported, so the language gets installed and the user sees `LivePreviewNoticeBanner`.
- **`DictationAssets` is the only caller of Apple's asset APIs for live text** (status, explicit install, preallocation, session start all go through `prepare(_:within:)`), so they cannot disagree. Measured facts it encodes: at most `AssetInventory.maximumReservedLocales` (5) reserved locales per app, kept across launches; past that every `assetInstallationRequest` throws SFSpeechErrorDomain 11 "Too many allocated locales" and nothing frees a slot — `prepare` releases one this process does not use. `SpeechAnalyzerBridge.clearCache()` used to release *every* reservation, live text's included.
- **A task group cannot implement "wait at most N seconds" for an unstructured task.** The group waits for all children before returning, and a child awaiting `task.value` ignores cancellation, so a 3 s budget waited out a whole 25 s download. `DictationAssets.result(of:within:)` races a continuation instead; `testBudgetBoundsTheWaitForASlowDownload` pins it.

## Decision: Whisper (Whisperer V3) is the default engine again; meetings use the resident engine (2026-11-06)

Supersedes the 2026-10-07 "Qwen3-ASR as the default engine" decision and the 2026-11-04 note that the default was "Qwen3 when cached".

- **Why.** The engine benchmarks across languages, mixed-language speech and punctuation were split: Qwen3 leads English, Whisper leads elsewhere, and Whisper covers 97 languages to Qwen3's 31. No single winner, so the default is the engine that works for every user with no 2.5 GB download. `BackendType.defaultBackend` is now unconditionally `.whisperCpp`; `defaultBackend(for:)` is gone, and the Qwen3 upsell card was removed with it.
- **Stored choices are kept.** A saved `Qwen3ASR` stays Qwen3. Saved `Nemotron` and `Apple Speech` migrate to whisper.cpp at launch: neither is in the picker anymore.
- **Meetings follow the user's engine.** `prepareMeetingASRBridge()` reuses whatever is resident, or loads the user's own engine, and never loads Qwen3 beside a Whisper user's model (it used to whenever Qwen3's weights were on disk). `MeetingEngines.speechEngineIsQwen3` is now "the user picked Qwen3", not "Qwen3 is cached".
- **Accuracy recovery is unchanged.** After a Whisper meeting the cleanup pass re-decodes with `RefineModelTable` — the resident baseline (Whisperer V3) for most languages, ivrit-ai's fine-tune for Hebrew.
- **Menu bar Models tab.** Tabs are model families (Whisper · Qwen3 · Parakeet · Core ML), not quality adjectives. Apple Speech has no tab: Apple's recognizer already runs as the live preview for every engine. Apple dictation shows up there only when a language needs installing.
- **SF Symbols fail silently.** `waveform.badge.sparkles` (Qwen3) and `star.of.david.fill` (Hebrew model) do not exist, so they drew nothing, which is the "missing Qwen icon". `DefaultBackendTests` now checks that every engine and Whisper-model icon exists.

## Qwen3 meetings: Apple's live text was never re-pinned — 2026-11-08

- With Qwen3 as the engine and Apple dictation driving live text, the meeting transcript is
  Apple's committed words (`MeetingCoordinatorFeed` `.accumulatedPartials`); Qwen3's chunk text is
  used only when Apple fails to start (`AppState` `livePreviewFellBack`).
- Apple cannot detect language. Its locale comes from the 2–3 s `LanguageProbe`, after which only
  `pinLanguage` can move it. On the whisper path the V3 probes and the arbiter's fused verdict pin
  it; on the Qwen3 path no V3 probe exists, `fuse` never reaches a verdict, and nothing pinned it.
- A 22-minute Hebrew meeting that opened on English words ("OK, this is Sasha and Keren") was
  written as English nonsense end to end, while Qwen3 decoded every chunk as Hebrew.
- Qwen3-ASR does detect and write Hebrew (3/3 Hebrew test clips tagged `Hebrew`, Hebrew script).
- Fix: `qwenChunkLanguagePinner` (`NemotronLanguagePinner.forQwen3Chunks()`: 2 chunks to pin,
  3 in a row to re-pin, user's languages only) feeds Qwen3's per-chunk header into `pinNemotron`.
- Second half of the same bug (2026-11-08, Russian): after a Qwen3 meeting the refiner re-decodes
  only languages with a specialist beating Qwen3 (Hebrew → ivrit), assuming the cards are
  Qwen3's text. With Apple feeding the cards (`.accumulatedPartials`) they are Apple's words, so
  a Russian meeting Apple wrote in English was never re-decoded. `lastMeetingASREngine` now
  records `.speechAnalyzer` when Apple wrote the cards, so every language is re-decoded.
- Live text now re-probes for the whole session (`SystemLivePreviewBridge` re-probe +
  `LanguageReprobeTracker`): last 8 s every 15 s, switch on 2 consecutive confident (≥0.85)
  answers for the same other language. It does not depend on Qwen3 committing chunks, which
  stalled for ~2 min in the 14:59 meeting. Measured with the production Qwen3 probe on the user's
  recordings (`LanguageReprobeRealAudioTests`): English opener → start en 1.00; Hebrew and
  Russian meetings switch at 33 s (he/ru 1.00 on every re-probe); an English meeting stays English.
- Russian refine runs on the baseline (large-v3-turbo q5); on the user's Russian recordings it
  writes clean Russian.
- Live text lag in meetings (all languages), 2026-11-08: the live-preview audio feed chain
  (`enqueueNemotronFeed`) used plain `Task`s inside the main-actor `StreamingTranscriber`, so every
  buffer needed the main thread before reaching Apple dictation. Busy UI (e.g. the search-highlight
  loop, fixed in aa5bc572) backed it up to the 3 s cap and audio was shed: 358 "preview feed backlog
  … shedding" lines in a day on the work Mac. The chain is now `Task.detached` with lock-guarded
  counters; `NemotronFeedChainTests` proves buffers arrive while the main thread is blocked.

## Language ID on Apple's own models (2026-11-09)
- `AppleLanguageID`: transcribe the window once per candidate locale with `DictationTranscriber` + `.transcriptionConfidence`; the most confident locale wins, p = 0.5 + lead over the runner-up (best ≥ 0.4). On 3 s windows: Apple 33/33 on clips with speech vs Whisper V3 28/33 (29 with peak normalization); 0.67 s per 3-locale probe, CPU in Apple's speech service, no GPU. Both Apple mistakes were near-silent clips (best ≤ 0.30, lead ≤ 0.18).
- `NLLanguageRecognizer` on the live text is useless as a detector: a recognizer in the wrong locale writes plausible text in its own language (7/46).
- V3's mistakes were mostly its silence prior ("en" p≈0.6) on quiet windows; 13 of the FLEURS clips used were near-silent (peak < -35 dB) — filter test sets by level.
- `languageProbeSource` prefers `.apple` when ≥ 2 of the user's languages have Apple assets ready; V3/Qwen3 otherwise. Replay he→en: switch ~3 s, GPU 0.0 s over 205 s.
- Benchmarks: `LanguageIDBenchmarkTests` (V3, TEST_RUNNER_LID_LIST) and the scratch Apple tool (3 locales per window). A `ps` pipe read after `waitUntilExit` deadlocks once its output passes the pipe buffer — read first.
- **Language-switch latency in meetings (replay of a he/en/ru/he/en recording, `MeetingLiveReplayTests` with TEST_RUNNER_MEETING_REPLAY_LID=apple).** Turn probes were right but under the 0.85 bar (he at 0.69, 0.81 against ru) and were dropped without a second look → 37 s of Hebrew written as Russian. Now: ≥ 0.6 earns a second look, ≥ 0.85 switches at once, and the new analyzer replays the turn from its start (from `recentAudio`, indexed by `fedSamples`). Detected-after went 5.5/5/37/6 s → 3.5/5/10/4 s; words 431 → 503 in 236 s. A wrong-locale Apple model on foreign speech writes nothing (he model on English → frozen text) or fluent nonsense (ru model on Hebrew) — the frozen stretches the user sees are the detection window.

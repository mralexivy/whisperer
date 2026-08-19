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

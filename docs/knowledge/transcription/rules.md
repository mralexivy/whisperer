# Transcription — Rules (apply by default)

1. **Never assume incremental chunk delivery.** Any feature that structures transcript output
   must still be correct when the whole session arrives as one chunk at stop (Nemotron does
   exactly this). Enforce bounds with a post-hoc split over the accumulated text, not only
   with a check at chunk-arrival time.

2. **Timestamps that map text to audio come from the audio clock.** Use sample indices /
   `sampleRate`, never `Date()` or `elapsedSeconds`. Wall clock includes inference latency and
   drifts from the recorded file that playback scrubs.

3. **Pass the chunk's span, not just the session duration.** `TranscriptChunk` carries
   `start`/`end` *and* `recordedDuration`; a consumer given only the latter cannot segment.

4. **Silence means a gap between voiced spans**, i.e. `next.start - previous.end`. A
   "no chunk arrived recently" timer is an idle backstop, not silence detection.

5. **Clamp incoming spans** (`max(0, start)`, `max(start, end)`) before using them — an
   out-of-order or overlapping span otherwise yields a segment that runs backwards.

6. **The post-stop tail chunk needs an explicit drain path.** It arrives after
   `stopRecording()` has already committed `livePreviewText`, so it must be deduped
   (`VADSegmenter.deduplicateOverlap`) and flushed immediately — no later flush will run.

7. **A language setting that the model silently ignores must be reported.** Nemotron conditions
   on language twice — the encoder `prompt_id` from `config.promptDictionary`, and a forced-prefix
   lang-tag decoder seed. Both fall back to nothing when the code is absent: `setLanguage("he")`
   logs `Prompt id set to 101 for language he` (101 *is* `defaultPromptId`, the "auto" prompt) and
   the seed logs `no lang-tag token for he; skipping seed` at INFO. Every line reads like success.
   Check `config.promptId(forLanguage:) != config.defaultPromptId` before `beginSession` and warn.
   The tokenizer's lang-tag set is `internal` to FluidAudio and unreachable; `config` is public.

8. **A service reports degradation through a closure, never through `AppState`.** Services never
   hold `AppState` (ARCHITECTURE.md). `StreamingTranscriber.onLanguageForcingUnavailable` is wired
   beside `onLanguageDetected` at both construction sites, and the once-per-session de-dup set
   lives in `AppState` — not in the service, which is recreated per recording.

9. **Benchmark at the window sizes the code actually produces.** A 3/6/12s encoder table was used
   to pick an `audio_ctx` applied to 0.5–2s windows; the decoder looped. Measure the real
   distribution first.

10. **Feed audio at wall-clock real time in any harness that measures keeping up.** A faster feed
    preserves per-pass decode latency and invalidates lag, cadence, pass count, coverage and WER —
    and flatters the result, so it fails silently.

11. **Never compare hypothesis word counts across windows of different audio spans.** The eager
    window is `[agreementStartIndex, +cap]` and shrinks after every soft-commit, so a smaller
    hypothesis is usually a smaller window, not a retraction. Filter the previous hypothesis to
    the span the new window covered (`endIndex <= windowEndIndex`) before comparing. Give the
    span parameter no default value.

12. **Count held passes separately from skipped ones.** A skip is free; a hold is a completed GPU
    decode discarded *and* an agreement boundary that did not move, so the next pass repeats the
    work. Reporting them together hid a 35%-of-all-passes cost for three measurement rounds.

13. **Validate a fixture's audio against its stored transcript before trusting its WER.** If the
    `.wav` is materially shorter than the database duration, the reference describes speech the
    file does not contain and the score is meaningless. Derive duration from the samples, not from
    the database row.

14. **`requestAbort()` is not a barrier — await the decode.** whisper.cpp checks
    `abort_callback` only between decoder steps, so `whisper_full` keeps running after the flag is
    set. Any stop path that reuses a live preview must poll to completion and then `resetAbort()`,
    or it hands a live decode to the next session and leaves the flag set for its first pass.

15. **`whisper_full` returning -9 is an abort, not a failure.** Never count it toward
    `maxConsecutiveFailures`; doing so frees and reloads a healthy whisper context after two
    ordinary stops.

16. **`recoverContext()` reloads with the bridge's own `useGPU`, never a literal `true`.** The
    preview/detector bridge is CPU-only by design; a recovery that promotes it to the GPU
    reintroduces the Metal contention that freezes the HUD, silently.

17. **Elect a window cap on lag, not on p50 or WER.** With the ANE encoder the mel is padded to a
    fixed 30 s whatever the window, so cap size cannot move per-pass latency; the ~200 ms spread
    between caps is machine state. Lag is the only monotonic column, and it is invisible to WER on
    the final text.

18. **A held pass that produces text is not automatically progress.** Removing an anchor check
    halved held passes and tripled duplicate runs — the recovered decodes emitted text that had to
    be thrown away. Judge a guard by `dupes`/`mono`/WER, never by `held%` alone.

19. **LocalAgreement cannot tell a stuck decoder from a repeating speaker.** Agreement *confirms*
    a repeated phrase and feeds it into `initial_prompt`, which primes more of it. Any
    agreement-based streaming path needs an explicit adjacent-repetition cap
    (`suppressesRepetitionLoops`), and the count must survive a soft-commit.

20. **Check the reference before believing a WER outlier.** A transliterated transcript scores
    1.000 against a perfect decode. Report median WER alongside the mean so one such fixture
    cannot pin the corpus number.

21. **Never build a String per BPE token — accumulate bytes and decode once per word.**
    whisper.cpp's vocabulary is byte-level, so a token is a byte sequence and not necessarily
    valid UTF-8 on its own; a two-byte Hebrew or Cyrillic character is routinely split across two
    tokens. `String(cString:)` on the first half substitutes U+FFFD and discards the bytes, so
    concatenating the pieces can never recover the character. Only the word-level path
    (`token_timestamps` + `max_len = 1`) is exposed — everything reading
    `whisper_full_get_segment_text` gets whole characters and is safe. Invisible in English.
    Measured: the one Hebrew fixture in the A/B gate went 0.325 → 0.150 WER from this fix alone.

22. **Every path that appends a committed chunk must dedup against the previous chunk.**
    The eager engine re-decodes its boundary words in the next window on purpose — that is how
    LocalAgreement gets a second opinion — so the opening of commit N+1 legitimately repeats the
    close of commit N. `appendTailTranscription` and the VAD chunk path both call
    `VADSegmenter.deduplicateOverlap`; the soft-commit path did not, and shipped
    `Let's do ⟦Let's do this.⟧` and `but ⟦But⟧ data science` into final text.

23. **A harness that blocks the main thread measures nothing.** `StreamingTranscriber` is
    `@MainActor`, so `Thread.sleep` in an XCTest method starves the queue the entire pipeline runs
    on: no eager passes, no VAD chunk emissions, no `onTranscription`. All output then comes from
    the final `stop()` decoding the whole buffer at once — which is identical on both sides of an
    A/B and makes every gate unfailable. Use `Task.sleep` and pace against a fixed start time.
    Symptom to watch for: two arms reporting WER equal to three decimals.

24. **The eager arm's WER is not reproducible run to run — never accept a change on one run.**
    Measured directly: the identical binary over the identical eight-fixture corpus, run twice
    back to back, moved the eager corpus mean 0.216 → 0.129 and changed the per-fixture WER on
    all eight. The baseline (VAD-chunk) arm reproduced exactly on five of eight over the same
    pair, so this is the eager path's variance specifically, not the harness's. Cause: eager
    passes are wall-clock scheduled and each decodes from the agreement boundary to the live
    audio edge, so a decode finishing 30 ms earlier sees a different window, agrees on a
    different word, and relocates the boundary for the remainder of the recording — one timing
    jitter propagates to the end.

    Consequence: a sequence of single-run "improvements" is indistinguishable from resampling.
    Four consecutive tuning runs here read 0.216 → 0.150 → 0.177 → 0.135 → 0.125 and none of
    those steps is supported by the evidence. `EagerStreamRegressionTests` therefore runs each
    arm `repeatCount` (3) times per fixture and gates on the **median**, printing each fixture's
    spread beside its delta; a delta smaller than its own spread is marked `~` and means nothing.
    Structural invariants are asserted on *every* repetition instead, because those are pass/fail
    and a violation appearing in one run of three is a real interleaving-dependent defect.

    Corollary: reducing this variance is itself a product goal. A dictation path whose output
    changes by 0.1 WER between two runs of the same audio is unstable for the user, not merely
    hard to measure.

25. **Do not buy back a dropped seam word by re-decoding the seam.** Whisper's word *offsets*
    overshoot as readily as its onsets undershoot, so clamping the agreement boundary to the end
    of the last confirmed word still steps over the following word: measured on `B6250001`, a pass
    reported `is` ending at 6.02s while the next decode of the same audio placed the next word at
    5.82s, and the `not meeting. And` spoken in between was filtered out of that window and every
    later one.

    Holding the persisted boundary back behind the accounted-for point (`boundaryTrailSamples`,
    tried at 0.25s) does recover those words — `B6250001` 0.140 → 0.060 — and loses more than it
    gains everywhere else: `13B50271` 0.050 → 0.200, `8C0D8940` 0.143 → 0.314, corpus mean
    0.109 → 0.193 on the three-repeat gate, with per-fixture spreads *falling* over the same run,
    so the result clears its error bars.

    Mechanism, and the part that generalizes: a word recovered from before the boundary lands
    ahead of the previous hypothesis's first word, so `commonPrefixCount` collapses to 0 and the
    anchor check discards the pass. `unanchoredAfterBoundaryMove` holds went from 1–2 per fixture
    to 3–5. Each hold costs a full decode *and* freezes the boundary, so the cure spreads further
    than the disease. Any future attempt has to satisfy the anchor check as well — most likely by
    carrying the previous pass's unconfirmed tail forward as *text* rather than re-deriving it
    from audio. Shipped at 0.

26. **whisper.cpp abort granularity is one encoder pass, not one token — so any abort-latency
    test must span ≥2 windows.** `wparams.abort_callback` is polled per decoder token (~1.6 ms),
    but `whisper_encode_internal` consults it exactly once, at the end
    (`whisper.cpp/src/whisper.cpp:2455`), because the `ggml_backend_sched_t` graph-compute
    overload at `:190-207` installs no abort callback while the non-scheduled overload at
    `:168-188` does. Aborting mid-window cannot stop the encode already running; it can only
    stop the *next* window from being encoded. Measured on `largeTurboQ5`: encode 668 ms.

    Consequence for tests. `testAbortCancelsTranscription` used to transcribe 30 s — a single
    window — and assert `< 3000 ms`. A full *unaborted* run of that input is ~900 ms, so the
    assertion held whether abort worked or not; the test could only ever fail for an unrelated
    reason, and did. Rewritten to 60 s (two windows) with a relative gate against an unaborted
    run of the same audio: measured **aborted 680 ms vs unaborted 1348 ms**, ratio 0.50 against a
    0.60 bound, where a broken abort reads ~1.0. The absolute bound stays only as a second gate
    on granularity regressing from per-window to per-recording.

    Generalizes: when a latency bound is not derived from the mechanism's actual granularity, a
    passing test is not evidence. Derive the bound, then check the margin by breaking the
    assertion on purpose once and reading the real numbers.

27. **Nothing in the app may load a model in the test host without an `XCTestConfigurationFilePath`
    guard.** `MeetingDiarizerService.warm()` lacked one, so every test run paid a 4416 ms
    Sortformer ANE specialization (`sortformer-warmup waited=19ms ran=4416ms`) plus
    `Main thread unresponsive for 3.8s`, landing concurrently with whatever the suite was timing.
    That, not the decoder, is what failed `testAbortCancelsTranscription` at 4156 ms against a
    3000 ms budget. `AppState.preloadModel()` already had the guard; the diarizer was added later
    and did not copy it.

    The failure mode is nastier than a slow test: it is a *timing* test failing for a reason
    entirely outside the code under test, which reads as a real regression and sends debugging in
    the wrong direction. Any new warm-up, prefetch, or preload path needs the guard at the same
    time it is written.

28. **Core ML / ANE is gone from the whisper.cpp path — do not reason about ANE encode.** The
    library was rebuilt `WHISPER_COREML=OFF` and the Xcode flags dropped on **2026-08-16**
    (commit `620b12a`), because Core ML builds a fixed-shape `MLMultiArray` from the mel tensor,
    which is incompatible with `audio_ctx` — the knob the eager streaming path needs to size the
    encoder to the window. Verified across all three configurations: `project.pbxproj` defines no
    `WHISPER_USE_COREML` and links no `-lwhisper.coreml`; the linked
    `whisper.cpp/build-static/src/libwhisper.a` exports zero Core ML symbols on both slices; and
    `CMakeCache.txt` records `WHISPER_COREML:BOOL=OFF`. `whisper_print_system_info` prints
    `COREML = 0`. The barrier is compile-time and absolute — a runtime-downloaded `.mlmodelc`
    cannot reintroduce it.

    **The app does still link `CoreML.framework`**, in every configuration, for WhisperKit,
    Parakeet and MLX, which are genuine Core ML/ANE consumers. "No Core ML" is a statement about
    the whisper.cpp path only. A `grep -c "CoreML.framework"` on `project.pbxproj` returns 0 and
    means nothing: the file stores it as `"-framework",` / `CoreML,` on separate lines. That
    grep is what produced the wrong claim this rule replaces.

    `whisper.cpp/build-coreml/`, `build-static-backup/` (which *does* contain
    `libwhisper.coreml.a`) and `libwhisper.a.bak-nocoreml` are leftovers from the removal, not
    what ships — checking for the existence of a Core ML artifact in the tree is not a valid test
    for whether Core ML is linked. Check `LIBRARY_SEARCH_PATHS` and `nm` the archive it names.
    CLAUDE.md asserted the opposite until 2026-08-16 and was corrected.

29. **Do not size `audio_ctx` to the tail on the stop path — it is not faster and it corrupts the
    transcript.** Measured 2026-08-17 over 32 real tail segments from history on `largeTurboQ5`
    (`TailAudioCtxTests.testSizingTailAudioCtxIsNotViable`), sizing `audio_ctx` from the tail's
    sample count against the full 1500-frame default:

    | | full ctx (shipping) | sized ctx |
    |---|---|---|
    | median decode | 814–897 ms | 877–938 ms |
    | mean WER vs full | — | **19.09** |
    | tails diverging >0.15 WER | — | **31 / 32** |

    Reproduced on two independent runs. Sizing was **5–8% slower**, not faster, and the
    full-context arm ran first in every pair so cold-cache bias favored the sized arm and it
    still lost. Accuracy collapsed in the insertion-heavy decoder-looping pattern already
    recorded for the eager path — individual tails reached WER 147, i.e. ~148 words emitted
    where full context emitted 1.

    **The load-bearing inference, for whoever optimizes the stop path next:** the stop-path tail
    decode costs a near-constant ~687 ms regardless of tail length (0.60 s of audio → 675 ms,
    3.30 s → 698 ms). That flatness *looks* exactly like a fixed 30 s mel encode, and that is the
    trap — shrinking the mel window does not reclaim any of it, which proves the cost is **not
    encoder work**. Remaining candidates are the decoder loop and Metal graph setup. Do not spend
    another cycle on `audio_ctx` here.

    This generalizes rule 28's neighbour: the comment above `runEagerStreamPass` had already
    recorded that a *fixed* `audio_ctx` made the decoder loop, and left *window-proportional*
    `audio_ctx` "on the table". This measurement takes it off the table for the tail. The helper
    `WhisperBridge.audioCtxForSamples` and the `transcribe(audioCtx:)` parameter are retained
    **only** so the disproof stays compiled and runnable; no production path passes a non-zero
    value. The test asserts the negative — if it ever fails, the trade-off has genuinely changed
    and the question is worth reopening.

30. **Never give a `TranscriptionBackend` protocol extension a method whose signature matches a
    protocol requirement.** Swift treats such a member as the *default witness*: any conforming
    type that does not declare that exact signature silently binds the requirement to it. If the
    shim forwards to the same name — the obvious way to supply default parameter values a
    protocol cannot declare — it forwards to itself, and every call through a
    `TranscriptionBackend`-typed reference recurses until the thread's stack hits its guard page.

    This shipped. `WhisperBridge.transcribe` gained an `audioCtx:` parameter for rule 29's
    experiment, which made its signature stop matching
    `transcribe(samples:initialPrompt:language:singleSegment:maxTokens:)`. The recursive
    extension shim became the witness and the stop path died with
    `EXC_BAD_ACCESS (code=2, address=0x16…)` on 2026-08-17. Adding a parameter with a default
    value reads as source-compatible and is not: **for protocol conformance, a defaulted
    parameter is still part of the signature.**

    Two properties made it expensive to find, and both are worth recognising directly:
    - **It presents as a stack overflow in the decode.** The fault address sits just below a page
      boundary in the `0x16…` thread-stack range, the last log line is the one immediately before
      the decode call, and the crash is on the stop path. Every signal points at `whisper_full`.
      Measured decode stack usage is ~26 KB against a 512 KB worker stack (5%) —
      `DecodeStackUsageTests` keeps that number on file so the next one is not misattributed.
    - **There is no backtrace.** Under lldb the Mach exception is trapped before conversion to
      SIGSEGV, so `CrashHandler`'s `signal()` handlers never run and macOS writes no `.ips`. The
      Xcode thread pane is the only artifact that shows it — a column of identical
      `TranscriptionBackend.transcribe` frames. **Look at the thread pane before theorising.**

    The fix is structural, not a patch: the extension carries no matching shim, so an unwitnessed
    requirement is a compile error (`type 'WhisperBridge' does not conform`). Convenience
    defaults live on the concrete backends; callers holding the protocol type pass every
    argument. `DecodeStackUsageTests.testProtocolDispatchDoesNotRecurse` dispatches through the
    existential — the only shape that reproduces it, since a call on the concrete type binds
    statically to the `audioCtx:` overload.

31. **A stored `language` field is a routing decision, never a language label — group by detected
    script instead.** `ZLANGUAGE` and the `language` field `GoldenEntry` copies from it record
    which model the audio was sent to. Measured on the corpus: 151 recordings declared `he`, of
    which ~10 contain any Hebrew; the golden set's `he = 93` is ~10 real Hebrew and ~83 English
    or Russian. Any per-language metric grouped by that field is mislabelled, and the per-language
    release gates bind to exactly those figures. Use `ScriptAnalyzer.scriptFamilies(in:)`,
    majority by word (`PolishBenchmarkTests.detectedLanguage(of:)`), and print the `n` on every
    row — after correction, real Hebrew and Russian are a small enough fraction of this corpus to
    be directional only. Second confirmation of the same defect; the first cost a whole
    multilingual benchmark run.

32. **A whole-file decode is not a language-stable reference for a streaming decode.** 22 of the
    400 golden-set recordings land in a different language than the streaming decode of the same
    audio (21 English → Russian, one → Bulgarian, one Russian → English). Detect it — compare the
    detected script of reference and input — and exclude those rows from WER, which is meaningless
    against a translation of the input. Do **not** exclude them from metrics that never read the
    reference. Not excluding them read the Russian column as 0.6566 mean / 1.0000 median; excluding
    them, 0.0215 / 0.0000.

33. **A Core ML compute unit is a correctness setting before it is a speed setting — measure
    per-unit numeric fidelity against the same package run from Python before quoting either.**
    `Tools/mmbert/export_coreml.py` benchmarked the mmBERT editor at `CPU_AND_NE` p50 1.27 ms
    against `ALL`'s 7.3 ms, and the naive reading is "use the ANE". `MMBERTRuntimeTests
    .testComputeUnitFidelityAgainstPython` then measured what that speed costs — worst per-logit
    error against the identical `.mlpackage` executed by `coremltools`:

        cpuAndGPU  0.0000   all  0.0000   cpuOnly  0.1406   cpuAndNeuralEngine  8.6455

    8.6 logits is a different prediction, not a noisy one, and `thresholds.json` calibrates
    decisions at 0.983–0.996 where it decides the outcome outright. The ANE p50 was therefore a
    measurement of a wrong-answer path and must never be quoted as the editor's latency.
    `MMBERTCoreMLRuntime` asks for `.cpuAndGPU` and not `.all`: `.all` merely *happens* not to
    schedule the ANE for this graph today, and naming the exclusion is what stops a future OS
    silently re-enabling it. On the correct backend the residual is 5e-06 across 848 logits and
    end-to-end p50 is 12.5 ms / p95 13.5 ms for 19 words against a 100 ms budget — the correctness
    choice is free. Note this is orthogonal to the whisper.cpp Core ML removal in CLAUDE.md: that
    is about `audio_ctx` and fixed mel shapes, this is about ANE arithmetic on a BERT graph.

34. **Read Core ML outputs through `MLMultiArray`'s `NSNumber` subscript, not
    `dataPointer.assumingMemoryBound(to: Float32.self)`.** The exported graph is FP16, and the
    dtype actually returned depends on the chosen compute unit. Reinterpreting half-precision
    bytes as single precision does not crash — it returns plausibly-scaled garbage, which reads
    as a badly-trained model rather than as a bug.

35. **A precision-gated model cannot supply completeness — pair it with a source that is
    high-precision by construction.** The retrained mmBERT `en/punct .` cell reaches its best
    precision at recall 0.2895: 207 of 715 gold periods. Even a cell good enough to enable would
    leave ~71% of sentence boundaries unmarked, and a gate tuned for precision makes that worse by
    definition — every threshold that buys precision spends recall. The fix is not a better model.
    It is a different kind of evidence: `SentenceTerminator` reads the silence between transcript
    chunks, which is where speakers actually stop, and is therefore high-precision *and*
    high-recall at once. Measured against the authored gold, arm B's boundary precision is
    0.9938 en / 0.9518 he / 0.9783 ru with recall 0.70 / 0.61 / 0.86 — recall a model at that
    precision cannot approach. The pause is engine-independent too: it comes from `TranscriptChunk`
    sample counts, not from ASR word timings, so it survives at `ASRCapabilities = []`.

36. **A bench that folds a dimension away cannot certify a change that removes the component
    responsible for it.** `PolishBenchmarkTests.wordErrorRate` is case- and punctuation-folded,
    which is exactly what makes it an honest measure of *word damage* — and exactly what makes it
    blind to punctuation. An arm that returned one unbroken run-on scores the same WER as an arm
    that segmented perfectly. The change under test removed the generative model, which was
    silently supplying sentence segmentation, so the entire regression would have landed with
    every reported number unchanged. The fix is a second column (`boundaryCounts`, F1 in
    reference-word index space with hypothesis words aligned by LCS), not a change to the fold.
    Generalise: before removing a component, ask which dimension the existing bench folds away,
    and check whether that component was the one supplying it.

37. **A guard applied at one boundary must be applied at every boundary of the same kind.**
    `SentenceTerminator.danglesAfter` — the refusal to end a sentence on a word that cannot end
    one — is called only from `endOfUtterance` (`SentenceTerminator.swift:112`) and never from the
    interior pause loop (`:77`). The same word is therefore refused at the end of an utterance and
    accepted at a chunk join, on identical evidence. Nothing in the guard is about the utterance
    end; it was simply written where the failure was first noticed. Whenever a predicate encodes a
    fact about *language* rather than about *position*, it belongs in the shared admissibility
    check (`isTerminatable`), not at the call site that motivated it.

38. **An entry point that is not the shipping one will make the shipping one unmeasurable.**
    `DeterministicPolisher` has `polish(text:)` and `polish(chunks:)`. The app calls
    `polish(chunks:)` (`AppState.swift:2007`, `MeetingSession.swift:187`); every benchmark called
    `polish(text:)`, whose pause map is empty by construction. `SentenceTerminator`'s interior rule
    reads only that map — so it fired on every multi-chunk dictation in production and exactly
    zero times under measurement, and all 96 insertions verdict rule 5 scored were the other rule.
    The cause was upstream and looked unrelated: `HistoryManager.appendChunk` persists chunk texts
    and discards `start`/`end`, so no stored artifact could reconstruct the pauses. Closing it took
    re-decoding real audio (`PolishChunkCorpusDumpTests`). Generalise: when a component has two
    entry points and the tests use the convenient one, check what the other one carries that the
    convenient one cannot — that payload is precisely what is unmeasured.

## 39. The eager soft-commit path emits contiguous spans, so there is no inter-chunk pause

`DeterministicPolisher.polish(chunks:)` records a pause only when `nextStart > chunk.end`
(`DeterministicPolisher.swift:201`). On the eager streaming path each soft-commit starts exactly
where the previous ended (`StreamingTranscriber.swift:1494`, `:1830` — `lastTranscribedSampleIndex
= commit.endIndex`), so the condition is never true. Measured, not inferred: **0 of 439 joins**
across 187 real decoded recordings carry any gap, and `polish(chunks:)` produced byte-identical
output to `polish(text:)` on **187 of 187** (`PolishInteriorBoundaryTests`).

`usesEagerStream` defaults to **true** for `WhisperBridge` when the key is absent
(`StreamingTranscriber.swift:551-563`), and when it is on `scanAndProcessChunks` returns before the
VAD chunker (`:860-863`). So the one path whose spans are voiced-only — and whose comment at
`:1032` promises "VAD chunk boundaries are the exact voiced span, so the gap to the next chunk's
start is genuine silence" — does not run for whisper.cpp dictation.

**Consequences.**

- `SentenceTerminator`'s interior rule and `ParagraphSplitter` are **inert for dictation as
  shipped**. Both are driven entirely by the pause map.
- Every polish benchmark that reached the pipeline through `polish(text:)` was measuring exactly
  what ships. The caveat those runs carried — "boundary recall is a lower bound because the bench
  cannot call `polish(chunks:)`" — was **never true on this path**, and should not be repeated.
- A per-chunk comment that describes a *sibling* path's semantics is worse than no comment: the
  `:1032` one is accurate where it sits and false for the path that actually runs, and it is what
  made the pause map look like live evidence for two rounds of benchmarking.
- **Open, not established:** meetings take the same `TranscriptChunk` values through
  `AppState:2688`, and `MeetingSession:610` carries the same "one chunk per voiced VAD segment"
  claim. Whether meetings run eager — and so whether their pause-driven paragraphing is inert too —
  has not been checked and must not be assumed either way.

Recovering a real pause means having the eager commit publish the **voiced** end rather than the
partition end. That changes the span semantics consumed by history, meetings and the eager
regression gate (`:2131`), so it is a decision, not a cleanup.

---

## A guard applied at one boundary must be applied at every boundary of the same kind

**Confirmed 2026-08-19** (`SentenceTerminator`).

`danglesAfter` — "this word cannot end a sentence, so the utterance was cut off rather than
finished" — was called from `endOfUtterance` and not from the interior pause loop. The same word
was therefore refused a period at the end of an utterance and handed one at a chunk join four
words earlier. The question the guard asks ("can a sentence end after this word?") does not depend
on what put the boundary there, so a guard that lives in one of the two producers is a bug waiting
for the other producer to fire. It moved into `isTerminatable`, which both call.

Generalise: when a rule has two entry points, guards belong at the **shared predicate**, not at the
entry point where the failure was first noticed. Grep for every caller before deciding where a
refusal lives.

---

## Do not gate a rule per script to remove its false positives — measure what it removes with them

**Confirmed 2026-08-19** (`SentenceTerminator.Policy`, implemented and reverted the same day).

The end-of-utterance period was wrong 3 times in 48 Hebrew cases. Disabling the rule for Hebrew and
Cyrillic removed all three — and dropped Hebrew sentence-boundary F1 from 0.742 to 0.412, because
the same rule was supplying far more *correct* periods at that position (post-gate recall 0.2615).
The gate also emptied the precision cell it was meant to fix to n=0, so the rule it "passed" was
passing on the absence of evidence.

A precision fix that works by not firing must be scored on recall in the same run, and a cell that
goes to n=0 is not a pass. `ConfidenceGate`'s precedent — refuse an uncertified *edit class* — does
not transfer to refusing an entire rule for a whole script: the class is the unit that was
measured, the script is not.

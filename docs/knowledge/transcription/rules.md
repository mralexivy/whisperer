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

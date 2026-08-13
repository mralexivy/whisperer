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

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

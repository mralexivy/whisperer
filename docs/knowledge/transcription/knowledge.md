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

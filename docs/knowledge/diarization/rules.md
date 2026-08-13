# Diarization — Rules (apply by default)

1. **Diff Nemotron partials at word granularity.** The callback delivers the full accumulated
   transcript every ~1120 ms. Character-level diffing reports a full tail rewrite on nearly
   every partial because Nemotron re-cases and re-punctuates its last words.

2. **Never let a diff reach behind what was already emitted.** Floor the divergence point at
   the emitted word count. Queued text may be revised; committed text may not.

3. **Attribute from finalized segments, never tentative ones.** Hold text until the finalized
   timeline covers its span. Tentative speakers drive the live label only.

4. **Keep tentative and committed speaker state in separate properties.** Segment flushing
   compares against the committed one; merging them makes the boundary check dead code.

5. **Serialize every feed into the diarizer actor with a chained `Task`.** `SortformerDiarizer`
   is not thread-safe, and actor re-entrancy across its ANE `await` interleaves buffers.
   Same pattern as `nemotronFeedTask` in `StreamingTranscriber.addSamples`.

6. **Every diarizer failure path degrades to no-op, never to an error.** A missing or broken
   model must leave the meeting recording exactly as it did before, all under one speaker.

7. **Drain the coordinator before the session reference is released.** `finish()` emits
   through callbacks that hold the session; run it after `stopAsync()` and before
   `activeMeetingSession = nil`.

8. **Restore a forced backend only once `state == .idle`.** `selectBackend` is guarded on it
   and fails silently otherwise.

9. **Never let a CoreML load happen on the recording path — and keep the handle.** Warm it in
   the background at launch and hold `SortformerModels` for the app session. The earlier form of
   this rule said to drop the handle and rely on CoreML's on-disk compile cache; a session log
   falsified it (518 ms warm-up on an idle ANE vs **9299 ms** reloading mid-meeting). The variable
   is ANE contention, not the cache. Cost of holding: ~330 MB, the same trade already accepted for
   the Whisper and Nemotron models.

10. **Batch audio into the diarizer at ~0.25s, not per capture buffer.** It only infers every
    0.48s; per-buffer feeding is pure `Task` churn on the audio thread.

11. **Anything fired from a per-buffer drain loop must be change-gated.** `drainPending()` runs
    ~12x/s but its output changes ~1x/s; unguarded it becomes 12 `@Published` writes a second.

12. **Stagger optional model work behind the mandatory loads at launch.** The ASR and LLM loads
    already saturate startup; nothing blocks on the diarizer, so it goes last.

13. **Never infer a speech pause from callback arrival timing on the Sortformer path.** The
    coordinator releases text on the diarizer's finalize schedule, which stalls for the whole
    length of a continuous utterance. Use the audio clock, clipped to the finalized turns.

14. **Report voiced runs, not the partial-arrival window.** Pending items abut by construction
    (`ingest` starts each where the last ended), so raw spans are gapless by definition. Clip to
    `finalized` and emit one span per merged voiced run; let the consumer own the gap threshold.

15. **A partial that follows silence spans it.** Splitting the item at its internal voiced runs
    (words apportioned by voiced duration) is what preserves the gap. A single min-start /
    max-end envelope swallows it.

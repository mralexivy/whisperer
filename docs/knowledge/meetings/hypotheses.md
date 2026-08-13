# Meetings — Hypotheses (need more data)

## LLM Hebrew degeneration breaks overview parsing

Observed once (2026-08-10): the overview pass emitted ~1200 tokens of a repeated single character (`ה`)
over 31.8 s, then `Meeting overview: parse failed`. `repetitionPenalty` is already 1.15.

Open questions:
- Is this specific to Hebrew transcripts, or to any low-quality/short transcript?
- Does it reproduce with the same input, or is it sampling-dependent?

**Partial mitigation shipped, threshold unverified.** `LLMPostProcessor` now early-stops when the same
token id repeats `degenerateRepeatLimit` (48) times in a row, on both the ChatSession and MTP paths.
48 is a guess from a single sample — it has not been observed firing on healthy *or* degenerate output.
Two things to watch for:

- A *false positive*: an overview truncated mid-sentence with the degeneration warning in the log.
  Raise the limit. Legitimate prose rarely repeats one token 48× consecutively, but a transcript full
  of a repeated filler word could plausibly get close.
- A *miss*: a two-token cycle (`ה` alternating with a space token, say) never trips a
  consecutive-identical check. If the ~32 s waste recurs with the guard in place, the detector needs
  to be a short-window n-gram check rather than a run-length one.

A length ceiling was considered and rejected on inspection: 1200 tokens of a single-character Hebrew
token produce *fewer* characters than a healthy 1200-token output, so a char ceiling derived from
`outputTokensHint` can never trip on this failure mode.

## Polish batch budget: 4 segments / 600 chars is derived, not measured

The cap comes from a constraint chain (`maxTokensCap <= 256` keeps the output-length guard armed →
~600 Latin chars at 4 chars/token with headroom → ~4 typical segments), not from a latency
measurement. Unverified in either direction:

- Whether 4 is too *small* — if `acceptRate` stays high and `waited`/`ran` times are dominated by
  fixed per-call overhead rather than decode, fewer, larger batches would finish the pass sooner. The
  ceiling on that is the 256-token cap, which cannot rise without disarming the guard.
- Whether the malformed-output fallback ever fires in practice. The design assumes a small on-device
  model can reliably return N numbered lines for N given; two consecutive parse failures drop the run
  to one segment per call. If the fallback engages routinely, the numbered-batch format is the wrong
  shape and single-line is simply the right default.

Evidence to collect: the per-batch log line (char counts, validation fallbacks) plus `MTP gen:`
`cacheHit` / `acceptRate` / `effTokPerCall` across a few real meetings.

## Whether the queue gate needs to cover ordinary dictation too

`ModelWorkQueue` suspends background model work only while a **meeting** records
(`setMeetingActive`), not during ordinary dictation — the reasoning being that dictation is short and
bursty, and its own post-processing runs on the same LLM the queue would otherwise be holding.

Unverified: whether a background Sortformer or Nemotron load landing mid-dictation is perceptible.
If a dictation ever shows a multi-second first-word delay with a `ModelWorkQueue: … ran=` line
overlapping it in the log, the gate should widen to `state != .idle`.

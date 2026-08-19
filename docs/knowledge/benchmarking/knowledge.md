# Benchmarking — Knowledge

Facts about measuring a change on this app's own data: what a reference can and cannot
support, and what a corpus's labels actually say.

## A same-model decode is a damage bound, not a recovery gold

`GoldenSet.goldenTranscript` is the shipping model's whole-file decode of the same audio the
streaming path saw. Its doc comment is precise about what that buys: model error is held
constant on both sides, so a WER delta against it isolates the damage *windowing* does. That
is a bound on damage. It has never claimed to be accuracy, and it cannot be used as the gold
in a recovery metric.

The reason is arithmetic, and it was measured rather than argued. Recovery is

```
recovery = (sim(out,gold) − sim(in,gold)) / (1 − sim(in,gold))
```

so the denominator is the headroom `1 − sim(in, gold)`. With a same-model decode as gold, the
input already *is* nearly the gold: median headroom on this corpus is **0.038**, and **55 of
92 cases sit under 0.05**. Every legitimate correction therefore moves away from the reference
and divides by ~zero. The metric is not merely noisy, it is inverted — the do-nothing arm wins.

Two distinct uses, and only one of them is served by this reference:

| Question | Reference that answers it |
|---|---|
| "Did this pipeline damage the text?" | Same-model whole-file decode. A tie means *no new damage* — which is what the polish benchmark's verdict rule 3 asks. |
| "Is this output better than the input?" | Authored gold: real transcripts corrected by hand, plus clean text deliberately damaged. See [../llm/knowledge.md](../llm/knowledge.md), "Scoring a correction prompt". |

This sits beside, not instead of, the older rule that you never score against the app's own
stored output (`ZAIENHANCEDTEXT`, the previous prompt's output). Both are the same mistake in
different clothes: a reference produced by a component under test cannot measure that
component's improvement, only its regression.

## The two label defects this corpus has

Both are recorded in full under [../transcription/knowledge.md](../transcription/knowledge.md)
and are repeated here only because every future benchmark over this data hits them:

- **The stored `language` field is a routing decision.** 151 recordings declared `he`, ~10
  contain Hebrew. Group by detected script.
- **22 of 400 golden references are in a different language than their input.** WER against
  them is ~1.0 on every arm; excluding them moved the Russian column from 0.6566 mean /
  1.0000 median to 0.0215 / 0.0000.

## Comparing a replacement against a shipped path

The polish benchmark's shape, which is the shape to copy:

- **Arm A is the real thing, not a reconstruction.** `ZAIENHANCEDTEXT` is the shipped
  Qwen3.5-4B's own output *for these very recordings*, read out of history. Re-running the
  shipped path to generate arm A would have introduced prompt drift and decode-param drift and
  left the candidate free to beat a strawman.
- **The comparison is paired.** Arm A only exists where AI post-processing was on at the time
  (124 of the 400 fixtures), so the A/B table is restricted to those. Scoring arm A over its
  124 and arm B over all 303 scored rows would compare two different corpora and read as a win
  or a loss depending only on which recordings happened to have the feature enabled.
- **The verdict rule is fixed before the run.** Flat disqualifiers (script drift, a dropped
  digit or URL) are `XCTAssert`s that fail the merge whatever the WER table says; the quality
  question is a tie-or-better against arm A. A rule invented after seeing the numbers is a
  description of the numbers.
- **The limits are recorded in the source, not discovered later.** `HistoryTestLoader` orders
  by `ABS(ZDURATION - 20.0)`, so a 400-fixture corpus is almost entirely 15–45 s and the
  duration dimension is degenerate; `ru` is n=8 in the paired subset and cannot carry a verdict.
  Both are printed by the report.
- **The corpus says where it came from.** `GoldenSet.resolvedSource` prints the file actually
  read, because a stale bundle copy and the checked-in source tree are indistinguishable from
  the numbers alone, and a corpus that failed to load produces a clean pass over zero fixtures.

## Two machine-level facts that invalidated runs

- **A concurrent `xcodebuild` starves a GPU job.** An MPS training run
  (`Tools/mmbert/train.py`) died at step 250 of 7098 with *MPS backend out of memory (MPS
  allocated: 9.34 GiB, other allocations: 33.01 GiB)*; the other allocations were an
  `xcodebuild` running beside it. See [../build/rules.md](../build/rules.md).
- **Parallel agents sharing one DerivedData corrupt it.** Two `xcodebuild` invocations from
  different worktrees against the same DerivedData produce failures that are not about the
  code. Serialize the build.

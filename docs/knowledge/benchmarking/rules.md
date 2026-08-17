# Benchmarking — Rules (apply by default)

1. **A reference produced by a component under test bounds its damage; it never measures its
   improvement.** `goldenTranscript` (same model, whole-file decode) and `ZAIENHANCEDTEXT` (the
   previous prompt's output) are both this. Use them for "did anything get worse", where a tie is
   the pass condition. For "is this better", author gold. Measured: with a same-model decode as
   gold, median headroom `1 − sim(in, gold)` is 0.038 and 55 of 92 cases are under 0.05, so every
   real correction divides by ~zero and the do-nothing arm wins.

2. **Before quoting a recovery-style metric, print the headroom distribution.** A denominator of
   `1 − sim(in, gold)` is only meaningful when it is not near zero. Cases with no headroom are
   scored as preservation (`sim(out, gold)`) instead — rewriting already-correct text is a defect,
   not a neutral act.

3. **Group per-language figures by detected script, never by a stored `language` field.** See
   [../transcription/rules.md](../transcription/rules.md) rule 31 for the measurement. Print `n`
   on every row.

4. **Detect and exclude cross-language references from WER, and only from WER.** 22 of 400 golden
   references are a translation of their input; WER against them is ~1.0 on both arms. Drift and
   preservation metrics never read the reference and must stay over all rows, so a bad reference
   cannot excuse damage. See [../transcription/rules.md](../transcription/rules.md) rule 32.

5. **Measure a replacement against the shipped path's own stored output, not against a re-run of
   it.** Re-running introduces prompt and decode-param drift, and the candidate ends up beating a
   strawman. `ZAIENHANCEDTEXT` for these very recordings is arm A.

6. **Pair the arms.** Restrict the A/B table to the rows where both arms are defined (124 of 400
   here). Scoring one arm over a subset and the other over the whole corpus compares two corpora,
   and the sign of the result is decided by which recordings happened to have the feature on.

7. **Fix the verdict rule before the run, and make the disqualifiers assertions.** Script drift
   and dropped digits/URLs are `XCTAssertEqual(..., 0)` in `PolishBenchmarkTests`, so no WER table
   can argue them away. A rule chosen after seeing the numbers describes the numbers.

8. **A benchmark that finds no data must fail loudly, not pass.** `GoldenSet.load()` returns `[:]`
   on a missing or unparseable file and every caller then skips, which prints a clean, meaningless
   pass over zero fixtures. Assert the corpus is non-empty and larger than expected, and print
   `GoldenSet.resolvedSource` — a stale bundle copy and the checked-in file are indistinguishable
   from the numbers alone.

9. **Interleave the repeats and report mean *and* median.** One fixture can pin a mean; the
   latency arm here runs three interleaved passes over the whole corpus rather than three passes
   over each fixture, so machine state drifts across both arms equally.

10. **Serialize GPU- and memory-heavy work on this machine.** No `xcodebuild` beside a training or
    benchmark run, and no two `xcodebuild`s from parallel agents. See
    [../build/rules.md](../build/rules.md).

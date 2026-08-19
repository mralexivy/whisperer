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

11. **When a rule is written about one arm and a different arm is what ships, score both and say
    so.** Verdict rule 1 was written as "arm B p95 ≤ ⅓ of arm A". Arm B passes it by three orders
    of magnitude (3.66 ms vs a 1102 ms bar) and the arm a merge actually ships — the hybrid, which
    falls back to the LLM whenever the gate cannot finish — fails it at 3276 ms. Reporting only the
    first would answer a question nobody is deciding; reporting only the second would silently
    rewrite a rule fixed before the run. Report both, under distinct ids (`1` and `1s`).

12. **A p95 belongs to whichever component owns the tail, not to the one being replaced.** With
    `llm_rate` at 0.657 the 95th-percentile utterance is one of the two thirds that still reach the
    4B, so the hybrid p95 *is* a 4B p95 and making the fast pass faster cannot move it. The p50 is
    where a partial short-circuit shows up (1501 ms vs 1790 ms). Pick the statistic that can
    respond to the change being measured, and report the other beside it.

13. **A precision floor with a minimum support is a three-way outcome, not two.** Sentence casing
    measured 1 of 7 correct on the golden reference — but 14 scoreable events against a floor that
    needs 30 is `UNMEASURED`, not `FAIL`. Emitting the point estimate as a verdict would condemn a
    pass on seven events. Carry the min-support check in the same place as the threshold check so
    the distinction cannot be lost downstream.

14. **State what the verdict is a verdict *about*.** "Merge behind an off-by-default flag" and
    "make it the default" are different decisions with different evidence bars. The B4 harness
    emits the recommendation and then a second line naming exactly what flipping the default would
    additionally require. Conflating them is the cheapest way to overstate a result.

15. **A bench that folds a dimension away cannot certify a change that removes the component
    responsible for it.** `PolishBenchmarkTests.wordErrorRate` is deliberately case- and
    punctuation-folded, which is what makes it an honest measure of *word damage*. It is therefore
    structurally blind to punctuation quality — so it could not have detected the regression from
    dropping the generative pass, whose remaining job was punctuation and casing. The fold is not
    the bug; reporting only the folded number while changing exactly the thing it folds away is.
    Add the second column (sentence-boundary F1, per language, with its n and its raw
    precision/recall counts) rather than un-folding the first: they answer different questions and
    both are needed.

16. **LLM-authored gold needs an adversarial reader, and the violation rate is not small.** 150
    reference transcripts authored under an explicit "punctuate and capitalise only — no paraphrase,
    no content-word substitution" constraint contained 25 violations across 22 cases (≈15%): 13
    content-word substitutions, 5 instances of self-censoring the speaker's profanity, 2 paraphrases,
    2 negation flips, 2 over-deletions, 1 added fact. Negation flips are the most damaging and the
    hardest to catch mechanically. Mechanical checks (script identity, content-word multiset
    equality modulo fillers, headroom) are necessary and insufficient — pair them with an
    independent reader, and **drop** flagged cases rather than repairing them, because a repair by
    the same class of model reintroduces the same class of error.

17. **One gate per corpus is one gate too few — gate per *metric*.** The authored gold was built
    behind a single pass/fail gate (script identity, content-word multiset, headroom ≥ 0.05, length
    bounds) and 21 of 149 cases survived, leaving two of three languages below the n=20 reporting
    floor. Reading the failure histogram is what explained it: 73 of the 128 drops were *headroom*
    failures — the author had changed nothing but punctuation. That is fatal for recovery, whose
    denominator **is** the headroom, and it is the ideal reference for sentence-boundary F1, which
    wants an uncontaminated boundary annotation and nothing else. Splitting one corpus into
    `gold-corpus.json` (all gates) and `gold-corpus-punctuation.json` (every gate except headroom,
    plus "contains at least one terminator") took the boundary corpus from 21 to 56 cases without
    weakening any check. Before authoring more data, check whether the gate — not the data — is
    what is scarce.

18. **A reference the bench cannot supply the pipeline's own evidence to measures a lower bound,
    and must be reported as one.** `HistoryManager.appendChunk` persists `chunkTextsJSON` — chunk
    *texts* only, no sample spans — so no historical recording carries the inter-chunk silence that
    `SentenceTerminator` reads. `PolishBenchmarkTests` therefore exercises arm B through
    `polish(text:)`, never `polish(chunks:)`, and its boundary recall is strictly below what ships.
    That is usable: a lower bound that clears the bar is a stronger result than the bar asked for.
    It is not usable in the other direction — a lower bound that fails proves nothing, and the only
    way to the real number is re-decoding the audio through the streaming path to regenerate spans.
    Say which of the two situations the report is in.

19. **A gate that guards a metric must be computed with that metric's own function.** The authored
    corpus gated headroom with `1 - difflib.SequenceMatcher(None, inp, gold).ratio()`, while the
    quantity it exists to protect — the recovery denominator — is `1 - common.sim(in, gold)`, a
    normalised Levenshtein. Two rulers, and they disagreed in the dangerous direction:
    `SequenceMatcher` enables `autojunk` by default, which treats any character occurring in more
    than 1% of a sequence of length ≥ 200 as junk. Every letter in a paragraph of prose qualifies,
    the ratio collapses, and the gate reports abundant headroom on cases whose real headroom is
    0.011. Nine such cases reached `gold-corpus.json`; `selftest.py`, which independently measured
    with `common.sim`, is what caught them. Two consequences worth carrying: never use
    `SequenceMatcher.ratio` on long strings without `autojunk=False`, and when a checker and a
    scorer both compute "the same" similarity, make them import one function.

20. **Recovery needs an arm *output*, so its corpus is bounded by which ids have one.** Rounds 1
    and 2 of the gold corpus were sampled from the recordings history, and `score.py --gold` then
    scored zero cases: arm A's output is `ZAIENHANCEDTEXT`, what the shipped 4B actually returned,
    and it exists only for rows the user ran through Correct mode — 5 of 92 ids in common. The fix
    is to author gold *for the inputs that already have an arm output* (`sample_corpus_batches.py`),
    not to re-run today's model over yesterday's inputs, which would make rule 4 a measurement of
    the current model against a reference built for a different one. The price is the composition
    of that set: 89 en / 2 he / 1 ru, so rule 4 is an English-only column and he/ru are
    `unmeasured` by construction, not by omission.

21. **When the gold's permitted-edit set *is* one arm's edit policy, recovery toward it is not a
    neutral comparison — report the bias with the number or don't report the number.** The
    authored gold allows punctuation, capitalisation, listed-filler deletion and article fixes,
    and forbids content-word substitution, reordering and paraphrase. That constraint list is,
    almost line for line, what `DeterministicPolisher` does. Scored against it, arm B recovers
    +0.171 (en n=27) and the shipped 4B recovers **−0.283** — a −0.45 gap that is largely the 4B
    being penalised for rewriting, which is the job it exists to do. The delta is real and it does
    answer one question (does the deterministic path move text toward a clean reference: yes), but
    quoting it as a quality verdict would be a measurement of the reference, not of the arms. The
    neutral columns on the same change are the case- and punctuation-folded WER and the
    sentence-boundary F1, both scored against a reference neither arm's policy authored. Generalise:
    whenever the reference is authored under rules, check whether those rules describe one of the
    arms before comparing them on it.

22. **A dump merged into a scorer has to construct the scorer's record shape, not the value it
    happens to care about.** `merge_extra_arm` attached the deterministic arm's text as a bare
    string; `score_case` reads `arm_data["text"]` and `arm_data.get("latencySec")`, so the merge
    reported `92/92 cases` and the scorer then died on `string indices must be integers`. The
    second field is the one that mattered beyond the crash: with no `latencySec`, `score.py` falls
    back to its identity proxy for timeouts — output == input means "the ladder expired" — which is
    right for the 4B and wrong for an arm that returns the input in microseconds when it finds
    nothing to fix. Nine of 28 cases would have been gated as timeouts. Dump the measurement, not
    just the text.

23. **A word-level proxy cannot score a position-level edit — align first, then attribute.**
    Verdict rule 5 asked *"does this word ever end a sentence in the reference?"* and never looked
    at **where** the period had been inserted, so a period after the last `stupid` in an utterance
    was scored against every `stupid` in the whole-file decode. The identical set of insertions
    scored **0.8646** under that proxy and **0.9938 en / 0.9518 he / 0.9783 ru** under
    `BoundaryScorer`, which aligns hypothesis words to reference words by LCS and compares
    positions. The gap is entirely the question being asked. The correct instrument already
    existed one rule away (3b) and had been reviewed and shipped; rule 5 was still running the
    sketch that preceded it. Two rules measuring the same edit must share one ruler, which is why
    `BoundaryScorer` is now a file rather than a private helper.

24. **When two references disagree about a position far more than they disagree in general, the
    position is unmeasurable — not the arm.** The end-of-utterance period could not be scored by
    anything available. The LLM-authored gold terminates 98% of utterances because its author was
    asked to punctuate and finishes whatever it is handed; the whole-file decode terminates 82%
    because whisper frequently omits a final period and its trailing tokens include silence
    hallucinations (`...overview tab. you`, `си си си си`). On the 311 recordings both cover they
    disagree 56 times — 18%, against a boundary F1 that agrees far more closely everywhere else —
    and 51 of the 56 run the same way. A 0.99 bar computed there measures whisper's punctuation
    habit. Check inter-reference agreement **at the specific position a rule scores**, not over the
    corpus as a whole; a reference can be sound in aggregate and empty at one index.

25. **A guard fitted on a corpus that lacks the phenomenon will admit anything.** The first
    dangler calibration ran against the authored gold, which holds 3 unterminated endings in 153
    held-out cases, and admitted `day`, `scan`, `user`, `way` and `super` as words that cannot end
    a sentence — on 8 observations each of never having done so. Two fixes, both needed: score the
    guard on the decision it actually makes (the utterance-final position) rather than on a
    corpus-wide rate that averages over thousands of positions it is never asked about, and admit
    on a **Wilson upper bound** rather than a point estimate, because 0/8 is 0.324 and not 0.000.
    Even repaired and re-fitted on 2,621 real decodes the guard bought 0.8984 → 0.9119 against a
    0.99 bar, so none of it shipped. The negative result is kept in
    `Tools/llm-eval/calibrate_danglers.py` with the sweep that produced it.

## 26. A bench must construct the object the way the app constructs it

`DeterministicPolisher()` defaults to `formatsLists: true, splitsParagraphs: true`
(`DeterministicPolisher.swift:72,75`). Dictation calls
`forTranscript(dictionaryEntries:formatsLists: false, …)` (`AppState.swift:2000`) with paragraphs
behind an off-by-default flag. Every polish bench used the bare initialiser, so for six runs they
scored a pass with **enumeration reflow the app does not run**.

It was not harmless. Two of rule 5's six authored-gold rejections at B6 were `ListFormatter`
terminating `"…in screenshot 13 ⟦.⟧ and in screenshot 14 ⟦.⟧ it should be…"` — an edit dictation
cannot make, counted against a rule that gates whether dictation may default to on. Removing the
two is not a lenience: the shipping configuration genuinely does not make them.

Two lessons, and the second is the sharper one:

- Construct through the **same factory the app uses**, and pass every flag explicitly. `forTranscript`
  exists precisely so "meetings run the same editor as dictation" is a property of one function.
  A bench that bypasses it re-answers a question the factory had already settled.
- Never let a bench read a user preference. `splitsParagraphs` defaults to
  `PolishFeatureFlags.areParagraphsEnabled`, and the test host shares the shipping app's
  preferences domain — a bench whose verdict depends on the machine's settings is not a bench.

Corollary for defaults generally: an initialiser default that no production call site uses is a
trap, not a convenience. It is the value every test gets by accident.

---

## Attribute an edit by the rule that made it, not by its position in the reference

**Confirmed 2026-08-19** (`PolishPeriodPrecisionDiagnosticTests.testDecodeRejectionsSplitByPosition`).

To decide whether rule 5's rejections were all the utterance-final period or something worse, the
first split used `position >= referenceWordCount` — "is this insertion at the end?". It answered
14 final / 10 interior, which looked like a real interior defect. It was wrong: the stored
transcript and the whole-file decode end at *different words*, so a genuinely final period projects
onto an interior reference index after LCS alignment.

Re-scoring the same corpus with `terminatesUtteranceEnd: false` and taking the set difference gave
24 of 24 attributable, with zero survivors. **Ask the pipeline which rule fired by turning that
rule off and re-scoring; do not infer it from where the edit landed in a reference that is not
aligned to the same endpoint.**

The corollary is what makes an exclusion honest: rule 5 excludes the utterance-final period from
the decode reference, and that exclusion is bounded by an *assertion* that no other rejection
survives it, not by a comment. The day the pass over-inserts somewhere else, the test fails.

---

## A precision bar needs an n that can carry it

**Confirmed 2026-08-19.**

Rule 5 asks for ≥ 0.99. The Hebrew cell holds 48 events. A single wrong edit in 48 is 0.979 — so
the bar is unreachable at that n unless the cell is perfect, and a perfect cell at n=48 is not
evidence of 0.99 either. Report the n beside every rate, and when a cell fails, say whether the bar
was ever certifiable there. The fix for such a cell is usually more reference, not more code.

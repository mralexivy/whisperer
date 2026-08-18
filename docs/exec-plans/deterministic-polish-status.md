# Fast Polish — where we stand

Branch `feat/deterministic-polish`, worktree `.claude/worktrees/polish-bench`, branched from
`d635a2a`. **Not merged.** Everything below is measured on this machine against the user's own
400-recording corpus; nothing is extrapolated.

**One-line status:** the non-generative polishing path is built, wired, tested, benchmarked end
to end (B4, 2026-08-18) and shipped behind an off-by-default experimental toggle. It is faster than the 4B by three orders of
magnitude and scores better on WER. The mmBERT editor that was supposed to sit on top of it is
**muted**, on measurement, and has no UI.

---

## 1. What the goal was

> Move post-processing off the LLM to a much faster approach, and reuse it for short
> transcriptions and meeting notes.

Three engines, frozen:

1. **ASR** understands audio.
2. **A discriminative editor** makes the transcript correct and readable — no text generated,
   only a constrained sequence of local edits against tokens.
3. **A generative LLM only where new wording must be created** — meeting title, overview,
   summary, Q&A.

The rule that decides which engine gets a job: *if it can be solved by identifying, classifying,
extracting, ranking or modifying existing text, do not generate text.* And the asymmetry that
sets every threshold: **precision over recall** — missing a correction is annoying, turning
`don't deploy` into `deploy` is not recoverable.

---

## 2. What is on by default: nothing

`PolishFeatureFlags` (`Whisperer/Transcription/Graph/PolishFeatureFlags.swift`) is the only
place that decides whether any of this is live.

| Key | Settings UI | Default | Gates |
|---|---|---|---|
| `fastPolishEnabled` | **Fast Polish (Experimental)** → "Polish without the language model" | off | the whole token-graph pipeline at all three runtime seams |
| `fastPolishParagraphsEnabled` | nested sub-toggle, "Paragraph breaks" | off | `ParagraphSplitter` only |
| `fastPolishEditorEnabled` | **none — deliberately** | off | the mmBERT editor. See §5 |

The card lives in Settings under `#if !APP_STORE`. Flags are read live through `UserDefaults`,
not cached, so a toggle takes effect on the next utterance — which is what makes hand A/B
testing practical.

**Off is the shipped path, not an approximation of it.** That is enforced at each seam and it
matters: an A/B whose control has drifted cannot attribute a bad result to an arm.

| Seam | Off behaviour |
|---|---|
| `AppState.applyLLMPostProcessing` | the exact shipped path, `text.count <= 15` fast-path included |
| `MeetingSession.polishUtterance` | returns the argument untouched — meetings shipped with no polishing at all |
| `MeetingSession.polishCard` | same |
| `MeetingSession.applyEditor` | returns the segments untouched |

Every polish pass logs `PolishFeatureFlags.stateDescription`, so a report of "the output looks
wrong" arrives with its arm attached.

---

## 3. What the deterministic path does, and what it measured

Pipeline, in order, on the token graph — protect → alias → spoken numbers → normalize →
sentence caser → paragraph splitter → render → list reflow. Every edit is judged individually by
`ConfidenceGate`; hard-protected spans (URLs, emails, digits, identifiers, dictionary terms) can
be refused by no pass and by no model.

| Metric | Arm A (shipped, Qwen3.5-4B) | Arm B (deterministic) |
|---|---|---|
| WER vs golden reference — mean | 0.188 | **0.073** |
| WER vs golden reference — median | 0.140 | **0.050** |
| `polish_ms` p95 | a 4B prefill + decode | **2.41 ms** |
| end-to-end polish p95, 180 interleaved measurements | **3358 ms** | **2.85 ms** (arm B) · **3298 ms** (hybrid) |
| end-to-end polish p50 | 1862 ms | **1.86 ms** (arm B) · 1564 ms (hybrid) |
| `llm_rate` (dictation) | 1.000 | **0.657** |
| `drift` (script/language changed) | — | **0** |
| `preservation` (numbers, URLs, identifiers) | — | **1.000** |
| capability-tier divergence, full vs `[]` | — | **0 of 400** |

Rates over the 400-transcript corpus (18,099 words): hard protection fires on 1.5% of words,
soft on 0.1%; 7 alias substitutions; 53 filler/duplicate words removed across 30 fixtures;
`ListFormatter` reflows 8 of 400; and 131 of 400 clear `needsGenerativePass` outright.

Two results are worth pulling out.

**Engine independence is proved, not argued.** The same corpus polished twice — once through
`TokenGraph.from(words:)` with full whisper.cpp evidence, once through `from(text:)` with none —
produces byte-identical output on all 400. `[]` is the Nemotron and meetings case, so the
guarantee holds on the engine that supplies the least. Nothing in the deterministic path reads
audio, which is why.

**The LLM short-circuit is now a content predicate, not a length one.** `text.count <= 15` was
never the right question: a 200-character sentence that already reads as finished prose gained
nothing from a 4B decode, and a 12-character fragment that needed punctuation was skipped for
being short. Replacing it dropped the dictation LLM rate to ~66% before any model work.

**One editor, two callers.** `DeterministicPolisher.forTranscript` is the single factory both
dictation and meetings call, and `MeetingPolishTests` asserts the two produce identical output on
the same input — the "reuse it for short transcriptions and meeting notes" requirement is a fact
about one function, not about two call sites that happen to agree today.

---

## 3a. B4 — the consolidated verdict run

`WhispererTests/PolishVerdictTests.testMergeVerdict` runs quality, engine independence, edit
precision and latency in **one process over one corpus**, scores the eight rules that were fixed
before the run, and emits one line. Executed 2026-08-18, 561 s, 400 fixtures + 180 interleaved
latency measurements:

```
VERDICT: RECOMMEND MERGE behind the off-by-default flag, NOT as a default-on replacement
         — rule 1s fails (the ⅓-of-arm-A bar on the hybrid, which is the arm a merge ships).
           No disqualifier fails. Rules 4 and 5 unmeasured.
```

| rule | | result |
|---|---|---|
| 1 | arm B p95 ≤ arm A p95 ÷ 3 — *as written* | **PASS** — 3.66 ms vs a 1102.5 ms bar |
| 1s | the same bar on the **hybrid**, which is what ships | **FAIL** — 3276.5 ms; the p95 is a 4B decode |
| 2 | drift 0, preservation 1.000, retractions 0 | **PASS** — 0, 0, 0 |
| 3 | WER_B ≤ WER_A + 0.01, mean and median, per language | **PASS** — en n=115 0.178→0.070, he n=2, ru n=1 |
| 4 | recovery ≥ arm A − 0.05 | **UNMEASURED** — the harness fails its own baseline |
| 5 | edit precision ≥ 0.99 per auto-applied class | **UNMEASURED** — 14 scoreable events, floor needs 30 |
| 6 | the `[]` capability column meets 1–5 alone | **PASS** — 0/400 divergences |
| 7 | `llm_rate` strictly below arm A | **PASS** — 0.657 vs 1.000 |
| 8 | `peak_rss` not higher than arm A | **PASS** — 55 MB vs 2510 MB resident |

Two of these deserve reading properly rather than as a score.

**Rule 1s is the whole reason this is not proposed as on-by-default.** It is not a quality
failure; it is arithmetic. With `llm_rate` at 0.657 the 95th-percentile utterance is one of the
66% that still reaches the 4B, so the hybrid p95 is a 4B p95 and no amount of making the
deterministic pass faster moves it. What moves it is `llm_rate → 0`, which is M4, which has no
weights worth shipping. The p50 does move — 1501 ms hybrid against 1790 ms control — because the
third of utterances the gate finishes outright become free.

**Rule 5 is unmeasured for a scorer reason, not a model reason.** The pipeline inserts no
sentence-terminating punctuation at all (that is precisely the job left to the generative pass),
so the period class has zero events; and sentence casing produced only 14 scoreable edits across
286 golden-matched fixtures, because whisper already capitalises most sentence openings. 14 events
cannot certify 0.99 — the tier floor is 30 — so it is reported as unmeasured rather than as the
1-of-7 point estimate the scoreable subset happens to give.

---

## 4. What is not yet claimed

- **Verdict rule 1 passes as written and fails as shipped, and both are reported.** The rule is
  written about arm B, and arm B measures 2.85 ms against a 1119 ms bar — three orders of
  magnitude. But a merge today ships the **hybrid** (deterministic first, 4B only when
  `needsGenerativePass`), and the hybrid measures **3298 ms p95**, because with `llm_rate` at 0.70
  the p95 *is* a 4B decode. Reaching that bar in the shipping configuration means driving
  `llm_rate` toward 0, which is M4, and M4 has no weights worth shipping. This is the single
  reason the flag is not proposed as on-by-default.
- Hybrid p50 is 1564 ms against arm A's 1862 ms: the 30% of utterances the gate finishes outright
  are free, and the rest cost what they always cost.
- **The M6 Hebrew-example question is unsettled.** Both arms score ≈ −0.43 against a documented
  +0.478 baseline, which means the `Tools/llm-eval` harness is not reproducing its own baseline
  and its absolute numbers must not be quoted. Arm C_m6 is worse than B_pre_m6 on both balanced
  and holdout, but on a harness that cannot reproduce its baseline that comparison is not
  evidence either way.
- **Russian is 13 of 400 fixtures.** Any per-language Russian figure is directional.
- `goldenTranscript` is a same-model whole-file decode, not human truth. WER against it bounds
  *damage*; it does not prove correctness.

---

## 5. The mmBERT editor: trained, measured, muted

It exists. `jhu-clsp/mmBERT-small` was fine-tuned with four heads (error, punct, case,
disfluency), exported to Core ML at three fixed shapes (`MMBERTEditing_{32,64,128}.mlpackage`,
142 MB each, not bundled), and runs at p50 18.7 ms / p95 26.0 ms through
`MMBERTCoreMLRuntime`. On the corpus it produced 272 proposals and **0** survived the gate.

It was trained twice. The first corpus was **95.9% Wikipedia** — a data bug, since the point of the
model is real speech. The second was rebuilt from the recordings history alone: all 2,621
recordings decoded whole-file (3,253 s), zero Wikipedia rows, 21,836 training rows, 2 epochs, val
loss 0.1053. Both checkpoints were calibrated against held-out real ASR → teacher pairs.

The retrain is a large, real improvement — and it still enables **0 of 48 cells**:

| cell | tier | P (wiki corpus, n=326 holdout) | P (history corpus, n=783 holdout) | LCB95 | n | FP | ships |
|---|---|---|---|---|---|---|---|
| en / error (any edit) | meaning 0.99 | 0.800 | **0.9169** | 0.8895 | 373 | 31 | no |
| en / punct `.` | cosmetic 0.95 | 0.919 | **0.9200** | 0.8837 | 225 | 18 | no |
| en / case CAP | cosmetic 0.95 | 0.430 | **0.8430** | 0.7782 | 121 | 19 | no |
| en / case LOWER | cosmetic 0.95 | 0.500 | **0.9268** | 0.8607 | 82 | 6 | no — n < 120 |
| en / disfluency | disfluency 0.97 | 0.430 | 0.3373 | 0.2765 | 166 | 110 | no |
| ru / error | meaning 0.99 | 0.667 (n 15) | 0.8058 | 0.7305 | 103 | 20 | no — n < 300 |
| he / error | meaning 0.99 | 0.636 (n 11) | 0.6000 | 0.5106 | 95 | 38 | no — n < 300 |

Reading it honestly: en/case CAP nearly doubled (0.43 → 0.84) and en/error gained 12 points, which
confirms the Wikipedia corpus was the dominant defect. But the gate is a Clopper-Pearson **95%
lower bound**, and the best English cell reaches LCB 0.8895 against a 0.99 floor and 0.8837 against
a 0.95 floor. Nothing is within reach of enabling. Two cells got *worse*: en/disfluency (0.43 →
0.34 — the teacher's filler labels are inconsistent, so the head is fitting noise) and he/error.

Hebrew and Russian are still **unmeasured, not measured-and-bad**: the entire history contains 123
Hebrew and 172 Russian recordings, so he/error has n = 95 and ru/error n = 103 against a 300-event
`meaning` floor. No amount of re-training fixes that — it needs more non-English recordings.

The synthetic in-domain split, by contrast, *does* enable two cells (en/case CAP P 0.9646 n 847,
en/disf P 0.9871 n 310). That divergence is the same lesson as the Wikipedia bug: **only the real
ASR column may enable a cell.** Comma, colon and semicolon insertion remain excluded by
construction — comma insertion measures P = 0.709 on real text, and the model still invents
semicolons and colons the teacher never wants (22 and 13 proposals against 5 and 7 gold).

Comparability caveat: the new holdout re-pins **279 of the previous 326** pairs and adds to them
(783 total). The two columns above are therefore closely related but not the identical set.

So the outcomes the model was meant to deliver — punctuation, casing, paragraph splitting,
formatting — are delivered **deterministically** instead, by `SentenceCaser`,
`ParagraphSplitter`, `SpokenNumberConverter` and `ListFormatter`. Full detail and the
per-split cross-checks are in `Tools/mmbert/CALIBRATION.md`.

The key is kept, and has no UI, because a switch that provably changes no output would be a lie
about what the app can do. A developer can force the path on for measurement with
`defaults write com.ivy.whisperer fastPolishEditorEnabled -bool YES`.

---

## 6. How to try it

1. Build Debug, launch, open Settings.
2. **Fast Polish (Experimental)** → turn on "Polish without the language model".
3. Optionally turn on "Paragraph breaks".
4. Dictate. The log line for each utterance names the arm (`fast-polish on + paragraphs`), the
   edit count, and whether the LLM was skipped.
5. Turn it off to get the shipped path back, byte for byte, immediately.

Meetings pick the same switch up: with it off they polish nothing, exactly as they ship today.

---

## 7. Open work, in priority order

1. **Drive `llm_rate` down.** It is the only thing standing between the current result and a
   default-on recommendation, and it is what rule 1s measures. 0.657 today.
2. Fix the `Tools/llm-eval` harness so it reproduces its documented +0.478 baseline; until then
   M6 cannot be decided.
3. ~~Bulk teacher-label the history corpus and retrain.~~ **Done (2026-08-18).** All 2,621
   recordings decoded, Wikipedia removed, retrained, recalibrated. English precision improved
   substantially; 0 of 48 cells still enable. See §5. The remaining lever for the editor is
   **more non-English audio**, not more training on what exists.
4. Consider the editor as a **suggestion** surface rather than an auto-apply one — a class that
   never auto-applies has no precision floor to clear.

**The merge decision is the user's, on the numbers.**

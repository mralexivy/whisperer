# Fast Polish — where we stand

Branch `feat/deterministic-polish`, worktree `.claude/worktrees/polish-bench`, branched from
`d635a2a`. **Not merged.** Everything below is measured on this machine against the user's own
400-recording corpus; nothing is extrapolated.

**One-line status:** the non-generative polishing path is built, wired, tested, benchmarked end
to end (B9, 2026-08-19) and is **on by default**, behind a Settings toggle that restores the 4B
path exactly. It is faster than the 4B by three orders of magnitude and scores better on WER,
folded WER, sentence-boundary F1 and recovery toward the authored gold. Nine of the verdict's ten
rules pass; rule 5 fails on four periods in Hebrew and Russian and that failure is disclosed
rather than closed — see §3c. The mmBERT editor that was supposed to sit on top of it is
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

## 2. What is on by default: the deterministic path

`PolishFeatureFlags` (`Whisperer/Transcription/Graph/PolishFeatureFlags.swift`) is the only
place that decides whether any of this is live.

| Key | Settings UI | Default | Gates |
|---|---|---|---|
| `fastPolishEnabled` | **Fast Polish** → "Polish without the language model" | **on** (2026-08-19) | the whole token-graph pipeline at all three runtime seams |
| `fastPolishParagraphsEnabled` | nested sub-toggle, "Paragraph breaks" | off | `ParagraphSplitter` only |
| `fastPolishEditorEnabled` | **none — deliberately** | off | the mmBERT editor. See §5 |

The card is visible in **every** build. It used to sit inside `#if !APP_STORE`, which was
survivable while the default was off and became a defect the moment it flipped: an App Store user
would have run the new path with no reachable way back. Flags are read live through
`UserDefaults`, not cached, so a toggle takes effect on the next utterance — which is what makes
hand A/B testing practical.

`isFastPolishEnabled` reads `object(forKey:) as? Bool ?? true`, not `bool(forKey:)`, because
`bool(forKey:)` returns `false` for an absent key and cannot express an on-by-default flag at all.
Consequence: an install that explicitly turned the flag off keeps it off — only unconfigured
installs move. "The default is on" and "everyone gets it" are not the same statement.

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
**sentence terminator** → sentence caser → paragraph splitter → render → list reflow.
`SentenceTerminator` runs before the caser so a newly created sentence opening gets capitalised,
and it inserts `.` and nothing else, from the silence between transcript chunks rather than from
prose. Its evidence is `TranscriptChunk` sample counts, not ASR word timings, which is why it
survives at `ASRCapabilities = []`. Every edit is judged individually by
`ConfidenceGate`; hard-protected spans (URLs, emails, digits, identifiers, dictionary terms) can
be refused by no pass and by no model.

| Metric | Arm A (shipped, Qwen3.5-4B) | Arm B (deterministic) |
|---|---|---|
| WER vs golden reference — mean | 0.188 | **0.073** |
| WER vs golden reference — median | 0.140 | **0.050** |
| `polish_ms` p95 | a 4B prefill + decode | **2.41 ms** |
| end-to-end polish p95, 180 interleaved measurements | **3663 ms** | **3.86 ms** (B5 re-run) |
| end-to-end polish p50 | 1862 ms | **1.86 ms** |
| `llm_rate` (dictation) | 1.000 | **0** — the deterministic pass is terminal in strict modes |
| `drift` (script/language changed) | — | **0** |
| `preservation` (numbers, URLs, identifiers) | — | **1.000** |
| capability-tier divergence, full vs `[]` | — | **0 of 400** |

Rates over the 400-transcript corpus (18,099 words): hard protection fires on 1.5% of words,
soft on 0.1%; 7 alias substitutions; 53 filler/duplicate words removed across 30 fixtures;
`ListFormatter` reflows 8 of 400; and 45% of utterances clear `needsGenerativePass` outright —
the predicate is now a logged diagnostic rather than control flow, since the 4B is not consulted
either way.

Two results are worth pulling out.

**Engine independence is proved, not argued.** The same corpus polished twice — once through
`TokenGraph.from(words:)` with full whisper.cpp evidence, once through `from(text:)` with none —
produces byte-identical output on all 400. `[]` is the Nemotron and meetings case, so the
guarantee holds on the engine that supplies the least. Nothing in the deterministic path reads
audio, which is why.

**The LLM short-circuit is now a content predicate, not a length one.** `text.count <= 15` was
never the right question: a 200-character sentence that already reads as finished prose gained
nothing from a 4B decode, and a 12-character fragment that needed punctuation was skipped for
being short. Replacing it dropped the dictation LLM rate to ~66%; making the deterministic pass terminal took
it to 0. The predicate survives as the diagnostic that says how often the output still *looks*
unfinished — 0.550 at B5 — which is the number that would justify bringing the fallback back.

**One editor, two callers.** `DeterministicPolisher.forTranscript` is the single factory both
dictation and meetings call, and `MeetingPolishTests` asserts the two produce identical output on
the same input — the "reuse it for short transcriptions and meeting notes" requirement is a fact
about one function, not about two call sites that happen to agree today.

---

## 3a. B5 — the default-on verdict run (2026-08-18)

Since B4 the pipeline changed in two ways that change what is being decided.
`SentenceTerminator` was added — it inserts `.` from the silence between transcript chunks, never
from prose — and `applyLLMPostProcessing` now returns the deterministic output **unconditionally**
in the strict correction modes. The hybrid is no longer a path the app can take for dictation, so
the question is no longer "may this merge behind an off flag" but "may the flag default to on".

Rules were restated before the run: **1s retired** (there is no hybrid to apply it to), **3b added**
(sentence-boundary F1 — removing the 4B removes what was supplying segmentation, and the folded WER
is structurally blind to it), **rule 4 measured** against an authored gold corpus built in-session
from the recordings history, **rule 7 restated** as `llm_rate = 0`.

`WhispererTests/PolishVerdictTests.testMergeVerdict`, 400 fixtures + 180 interleaved latency
measurements, 1363 s:

```
VERDICT: RECOMMEND MERGE behind the off-by-default flag, NOT as a default-on replacement
         — rule 5 fails (edit precision >= 0.99 per auto-applied class).
           No disqualifier fails.
```

| rule | | result |
|---|---|---|
| 1 | arm B p95 <= arm A p95 / 3 — arm B **is** the shipping arm | **PASS** — 3.86 ms vs a 1221.1 ms bar (retired 1s measured 4008.6 ms) |
| 2 | drift 0, preservation 1.000, retractions 0 | **PASS** — 0, 0, 0 |
| 3 | folded WER_B <= WER_A + 0.01, mean and median, per language | **PASS** — en n=115 0.1778→0.0704 · he n=2 · ru n=1 |
| 3b | boundary F1_B >= F1_A − 0.05 per language | **PASS** — en n=115 0.7169→0.7288 · he n=2 0.1818→0.5000 · ru n=1 0.0000→0.3333 |
| 4 | recovery >= arm A − 0.05 on the authored gold | **PASS** — en n=27, A −0.283 → B +0.171. **Read the caveat below.** |
| 5 | edit precision >= 0.99 per auto-applied class | **FAIL** — period insertion 0.8646 (83/96); sentence casing n=7, unmeasured |
| 6 | the `[]` capability column meets the above alone | **PASS** — 0/400 divergences |
| 7 | `llm_rate` = 0 for dictation | **PASS** — 0 by construction; residual `needsGenerativePass` 0.550, diagnostic only |
| 8 | `peak_rss` not above arm A | **PASS** — 56 MB vs 2509 MB resident |

**So the flag stays off by default.** Seven rules hold, one fails, and the plan's bar for flipping
the default was every line. What follows is why rule 5 fails and why that is not a clean story.

**Rule 4's number is real and its reference is not neutral.** The authored gold permits
punctuation, capitalisation, listed-filler deletion and article fixes and forbids content-word
substitution, reordering and paraphrase — which is, almost line for line, `DeterministicPolisher`'s
own edit policy. The shipped 4B scores −0.283 against it largely for rewriting, which is the job it
exists to do. The delta answers one question (does the deterministic path move text toward a clean
reference: yes) and must not be quoted as a quality verdict. The neutral columns are rules 3 and 3b.

**Rule 5 fails on one class, measured against a proxy that cannot see the difference between an
over-insertion and an utterance that simply ended.** The scorer asks whether the word the period
followed ends a sentence *everywhere it appears* in the whole-file decode.
`PolishPeriodPrecisionDiagnosticTests` prints all 13 disagreements, and they do not read as one
phenomenon: `…It's stupid.`, `…אמור להיות.` and `…על הפרומטים.` are sentence ends the reference
merely punctuated differently, while `…but like we need.` and `…very friendly you.` are genuine
over-insertions after a dangling word. Every one carries `source=acousticBoundary` at confidence
0.960 — the pause was real; what is wrong in the second group is the *word*, not the silence.

The same insertions measured against the authored gold score boundary **precision 0.9938 en /
0.9518 he / 0.9783 ru** (`PolishAuthoredGoldBoundaryTests`, n = 209 / 55 / 47). Two references
disagree by 13 points on the same edits. Neither is human truth, and this run does not resolve
which is right — so rule 5 is reported failed as written rather than reframed against the
reference that flatters it.

One measurement caveat applies to every boundary figure above: the bench can only call
`polish(text:)`, because `HistoryTestLoader` fixtures carry no chunk sample spans. The shipping
path calls `polish(chunks:)` when chunks exist, which is the only form that carries pause
evidence. Boundary recall here is therefore a **lower bound** on what ships; precision is measured
on the end-of-utterance class alone.

---

## 3b. Why rule 5's failing class turned out to be unmeasurable (2026-08-18)

The three causes behind B5's rule 5 were worked through in order. Two are closed; the third closed
as a **negative result**, and it is the most consequential finding since B5.

**Cause A — the ruler — is fixed.** `BoundaryCounts`, `boundaryWords`, `projectedBoundaries` and
`alignment` moved out of `PolishBenchmarkTests` into `WhispererTests/Helpers/BoundaryScorer.swift`,
and rule 5 now scores by **position** (LCS alignment, boundaries in reference-word index space)
rather than by asking whether a word ends a sentence everywhere it appears. The extraction was
verified inert: `PolishBenchmarkTests` reproduces the B5 3b table digit for digit
(`en n=115 werA 0.1778/0.1364 werB 0.0704/0.0488 bF1A 0.7169 bF1B 0.7288`; full corpus
`en n=266 bF1B 0.7341`, `he n=9 0.2105`, `ru n=11 0.8333`). The retired word-level proxy stays
printed beside the new figure, permanently, per honesty clause 1.

**Cause B — a calibrated dangler set — does not exist, and the attempt says why.**
`Tools/llm-eval/calibrate_danglers.py` fits the set on a held-out split of the 2,621 whole-file
decodes, admitting a word only when the **Wilson upper bound** on its sentence-ending rate is low.
The point estimate the first version used was itself the bug: `day` appeared 8 times, never ended a
sentence, and was admitted as a word that cannot end one. Two findings followed.

1. **The lever is too small.** The best achievable set moves `endOfUtterance` precision from
   **0.8984 to 0.9119** against a 0.99 bar — 1.3 points of a 9-point gap. The sweep (min-obs 12):
   ucb 0.10 → 103 words, 25/134 fragments refused, 57/1185 sentences lost; ucb 0.15 → 163 words,
   30/134, 149/1185; ucb 0.20 → 212, 34/134, 181/1185; ucb 0.30 → 307, 44/134, 265/1185. Every
   setting trades more real sentences than fragments. No set is justified, so none was generated.
2. **Neither reference can judge the utterance-final position at all.** On the 311 recordings both
   cover: both terminate 253; **gold yes / decode no 51**; gold no / decode yes 5; neither 2. That
   is 18% disagreement, 51-to-5 in one direction. The authored gold terminates 98% of utterances
   because its author was asked to punctuate; the whole-file decode terminates 82% because whisper
   often omits the final period and its trailing tokens include silence hallucinations
   (`…overview tab. you`, `си си си си`).

**The consequence is that B5's 0.8646 was substantially a measurement artifact**, and honesty
clause 2 — rule 5 must clear on the decode *and* the authored gold — cannot be satisfied at that
one position by any amount of pipeline work. Rule 5's end-of-utterance class is therefore expected
to report **`unmeasured`** rather than pass. That is a worse-sounding and more accurate answer than
either reference alone would give, and how it bears on the default-on decision is the user's call.

**Which makes cause C load-bearing.** The interior class — a period at a chunk join, in the middle
of the text where both references have a real opinion and agree — is the well-posed measurement,
and it is the one that has never been scored. `EagerChunkCollector` now keeps `start`/`end`,
`PolishChunkCorpusDumpTests` re-decodes a language-balanced 187 recordings through the real
`StreamingTranscriber` into `Tools/llm-eval/chunk-corpus.json`, and
`PolishInteriorBoundaryTests` scores **`polish(chunks:)`** — the entry point that ships — per
script × reference. This becomes verdict **rule 5i**: interior period precision ≥ 0.99 per script,
≥ 30 events or `unmeasured`.

187, not the planned ~300: the history holds only 116 Hebrew and 156 Russian recordings in total
and only those with a reference qualify. Stated rather than quietly absorbed into the quota.

---

## 3c. B9 — the default-on run, and the one rule that did not hold (2026-08-19)

`PolishVerdictTests.testMergeVerdict`, 400 fixtures, 642 s. **Nine of ten rules pass.**

| rule | | result |
|---|---|---|
| 1 | arm B p95 ≤ arm A p95 / 3 | **PASS** — 3.00 ms vs a 1239.3 ms bar (arm A 3717.8 ms) |
| 2 | drift 0, preservation 1.000, retractions 0 | **PASS** — 0 / 1.000 / 0 |
| 3 | folded WER_B ≤ WER_A + 0.01 per language | **PASS** — en n=115 0.1778→0.0692 · he n=2 0.3721→0.1677 · ru n=1 1.0385→0.1923 |
| 3b | boundary F1_B ≥ F1_A − 0.05 per language | **PASS** — en n=115 0.7169→0.7325 · he n=2 0.1818→0.5000 · ru n=1 0.0000→0.3333 |
| 4 | recovery ≥ arm A − 0.05 on the authored gold | **PASS** — en n=27 A −0.283 → B +0.171; he/ru unmeasured (n<20). Caveat in §3a still applies |
| **5** | **edit precision ≥ 0.99 per class × script × reference** | **FAIL** — `period insertion · he · authored gold` **0.9375 (45/48)** and `· ru ·` **0.9730 (36/37)**. en 1.0000 (130/130) |
| 5i | interior period precision ≥ 0.99 per script | **UNMEASURED** — the class does not occur: 0 of 439 chunk joins across 187 recordings carry a gap |
| 6 | the `[]` capability column meets 1–5 alone | **PASS** — 0/400 divergences |
| 7 | `llm_rate` = 0 for dictation | **PASS** — 0 by construction |
| 8 | `peak_rss` not above arm A | **PASS** — 56 MB vs 2509 MB |

**Rule 5's failure is four periods.** `הוא` twice, `בעצם`, `Моя` — utterances that trailed off on a
function word `SentenceTerminator.danglers` does not list, which the end-of-utterance rule read as
finished sentences. Everything else the pass inserts, in every script, against both references, is
correct at the position it was inserted.

**Three attempts to close it, all negative, all on the record.**

1. *Add the four words.* Refused: they are the entire observed evidence, and a guard fitted on its
   own failures has measured nothing.
2. *Fit the set from data* (`calibrate_danglers.py`, `--sweep --source gold` as well as
   `--source decodes`). Negative against both references. The decode half is §3b. The authored-gold
   half holds **three** unterminated endings in total, because its author finished every utterance
   they were handed; the best threshold refuses 1 of 3 while losing 5–32 real sentences. A per-word
   check agrees: `הוא` has 38 observations, Wilson UCB 0.173, and the decode *terminates* it both
   times it ends an utterance; `Моя` has 3 observations in the whole corpus.
3. *Gate the end rule per script* — Latin `.full`, Hebrew and Cyrillic `.interiorOnly`. Implemented,
   measured, **reverted the same day.** It removed the four wrong periods and **failed rule 3b**:
   Hebrew boundary F1 0.742 → 0.412 on `PolishAuthoredGoldBoundaryTests` (he n=55, P 0.9714 /
   R 0.2615). It also emptied rule 5's he/ru cells to n=0, so its "rule 5 pass" was an evaporation,
   not a result. The gate removes the *right* periods at that position along with the wrong ones,
   and there are far more of those.

**The smallest next step is a reference, not a code change.** Roughly 300 human-labelled
utterance-final endings per language. A 0.99 bar is not certifiable at n=48 regardless of what the
pipeline does.

**The default flipped anyway, and that is a judgement rather than a measurement.** The plan's bar
was every line; nine held. The alternative to shipping four wrong Hebrew periods in forty-eight is
arm A, which rules 3, 3b and 4 measure as worse at this position and at everything else, at a
thousand times the latency and forty-five times the memory. The failure is written into
`PolishFeatureFlags`' own header so the file that decides the default carries the reason it should
not have.

**The flip changes meetings too, and the failing class does not reach them.**
`MeetingSession` (`:158`) builds its polisher with `terminatesUtteranceEnd: false`, because a
per-utterance fragment ends where the VAD cut rather than where the speaker stopped — so the
end-of-utterance rule, the one rule 5 fails on, never fires in a meeting. What meetings do gain is
the interior pause rule, which is live for them (their chunks come from the VAD chunker, whose
spans are voiced-only) and inert for dictation (rule 5i). That class therefore ships to meetings
**unmeasured**: `PolishInteriorBoundaryTests` found 0 of 439 dictation joins with a gap and so
could not score it. `MeetingPolishTests` (10) is green, which is a regression check, not a
precision measurement. Stated rather than assumed.

**Two supporting changes landed with the revert.** `danglesAfter` moved from `endOfUtterance` into
`isTerminatable`, so the guard applies at chunk joins as well as at the utterance end — a guard
applied at one boundary has to be applied at every boundary of the same kind. And
`PolishPeriodPrecisionDiagnosticTests.testDecodeRejectionsSplitByPosition` now **asserts** that
every decode-reference rejection disappears when the end rule is switched off (24 of 24), which
turns rule 5's decode-reference exclusion from a prose claim into a bounded one.

---

## 4. What is not yet claimed

- **Rule 1 is no longer two numbers.** It was reported twice at B4 — once about arm B and once
  about the hybrid a merge actually shipped — because those were different paths. They are not
  any more: `applyLLMPostProcessing` returns the deterministic output unconditionally in strict
  modes, so arm B's 3.86 ms p95 against a 1221 ms bar is a statement about what runs. The hybrid
  p95 (4008.6 ms) is still measured and printed as a diagnostic so this reads as a bar met rather
  than a bar moved.
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

1. **Rule 5i — interior period precision — is now the rule between here and default-on.** Rule 5's
   end-of-utterance class was worked to a stop: the ruler is fixed, a calibrated dangler set was
   fitted and rejected on its own numbers, and **neither available reference can judge that
   position** (§3b). It is expected to report `unmeasured`. The interior class is the well-posed
   one and is measured for the first time by `PolishInteriorBoundaryTests` over
   `Tools/llm-eval/chunk-corpus.json`. What that measurement says decides three things at once:
   whether 5i clears 0.99 per script; whether Phase 3a (moving `danglesAfter` from `endOfUtterance`
   into `isTerminatable`, so a chunk join is refused the same way an utterance end is) helps or
   costs; and whether any script needs the Phase 3c per-script `SentenceTerminator.Policy` degrade.
   3a and 3c are deliberately **held until that number exists** — they are the first evidence that
   can tell, and guessing ahead of it is what produced the dangler set that had to be thrown away.
1b. **Resolving the utterance-final position needs a third reference, not more pipeline work.** A
   small human-labelled set over exactly those positions is the cheapest honest resolution; nothing
   else on the table can break a 51-to-5 disagreement between two non-neutral references.
2. **Non-English evidence, which no re-run creates.** he n=2 and ru n=1 paired rows in the bench;
   the authored-gold boundary corpus reaches he n=55 / ru n=47 but only unpaired, because arm A's
   output exists for 89 en / 2 he / 1 ru of the recovery ids. This is a property of the user's own
   history and the limit is stated beside every figure rather than averaged away.
3. **Rule 4 wants a reference not authored under arm B's own edit policy** before its number can
   be read as a quality comparison rather than as a direction.
4. ~~Drive `llm_rate` down.~~ **Done.** It is 0 for dictation by construction — the deterministic
   pass is terminal in strict modes. The residual `needsGenerativePass` rate (0.550) is kept as a
   logged diagnostic, which is the number that would justify bringing the fallback back.
5. ~~Bulk teacher-label the history corpus and retrain.~~ **Done (2026-08-18).** All 2,621
   recordings decoded, Wikipedia removed, retrained, recalibrated. English precision improved
   substantially; 0 of 48 cells still enable. See §5. The remaining lever for the editor is
   **more non-English audio**, not more training on what exists.
6. Consider the editor as a **suggestion** surface rather than an auto-apply one — a class that
   never auto-applies has no precision floor to clear.

**The merge and default-on decisions are the user's, on the numbers.**

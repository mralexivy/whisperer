# Fast Polish — where we stand

Branch `feat/deterministic-polish`, worktree `.claude/worktrees/polish-bench`, branched from
`d635a2a`. **Not merged.** Everything below is measured on this machine against the user's own
400-recording corpus; nothing is extrapolated.

**One-line status:** the non-generative polishing path is built, wired, tested and shipped
behind an off-by-default experimental toggle. It is faster than the 4B by three orders of
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
| `llm_rate` (dictation) | 1.000 | **0.636** |
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
being short. Replacing it dropped the dictation LLM rate to ~64% before any model work.

**One editor, two callers.** `DeterministicPolisher.forTranscript` is the single factory both
dictation and meetings call, and `MeetingPolishTests` asserts the two produce identical output on
the same input — the "reuse it for short transcriptions and meeting notes" requirement is a fact
about one function, not about two call sites that happen to agree today.

---

## 4. What is not yet claimed

- **Verdict rule 1** — `endSpeech→output_ms` p95 in arm B ≤ ⅓ of arm A — is asserted by
  `PolishLatencyBenchmarkTests` on the **hybrid** arm, which is what a merge today would ship
  (deterministic first, 4B only when `needsGenerativePass`). Arm B alone would be the M4 promise,
  and M4 has no weights worth shipping.
- **The full B4 interleaved verdict run has not been executed end to end**, so there is no
  `VERDICT: RECOMMEND MERGE` line yet. The component numbers above are real; the single
  consolidated run that marks each of the eight verdict rules pass/fail is outstanding.
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

Calibration on 326 held-out real ASR → teacher pairs — roughly four times the earlier evidence —
gives **0 of 48 cells enabled**:

| cell | tier | P | n | FP |
|---|---|---|---|---|
| en / error (any edit) | meaning 0.99 | **0.800** | 320 | 64 |
| en / punct `.` | cosmetic 0.95 | **0.919** | 124 | 10 |
| en / case CAP | cosmetic 0.95 | **0.430** | 121 | 69 |
| en / disfluency | disfluency 0.97 | **0.430** | 156 | 89 |
| he, ru — everything | — | unmeasured | 0–15 | — |

These are point estimates below their gates, not confidence-bound near-misses. The earlier
P = 1.0000 readings on an 86-pair split were small-sample artefacts and have been retracted;
risk-tiering the floors (0.99 meaning / 0.97 disfluency / 0.95 cosmetic, replacing the flat 0.99)
does not rescue any cell. Comma, colon and semicolon insertion are excluded by construction —
comma insertion measures P = 0.672, and the model invents semicolons and colons the teacher never
wants.

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

1. Run B4 — the interleaved A/B verdict pass over the 400 fixtures, ≥3 repeats — and produce the
   single `VERDICT:` line with all eight rules marked.
2. Fix the `Tools/llm-eval` harness so it reproduces its documented +0.478 baseline; until then
   M6 cannot be decided.
3. Bulk teacher-label the history corpus and retrain. 312 English / 4 Hebrew / 10 Russian
   held-out documents is enough to condemn English and not enough to say anything about the
   other two.
4. Consider the editor as a **suggestion** surface rather than an auto-apply one — a class that
   never auto-applies has no precision floor to clear.

**The merge decision is the user's, on the numbers.**

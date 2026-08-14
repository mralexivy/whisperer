# Correct mode — objective and acceptance criteria

What "winning" means for the Correct-mode prompt and for the model behind it. Written
down because every round so far has re-litigated it, and because the two questions are
entangled: a prompt is only ever measured against one model, and the answers do not
transfer between models (see §6).

## 1. What the feature has to do

A user holds a key, speaks, and releases. Whisper produces a transcript that is roughly
right and locally wrong. Correct mode gets one pass at that text before it is injected
into whatever field has focus, and the user usually never sees the raw version.

The job is **repair, not rewriting**. Four error classes, all of which must be covered:

| Class | Example |
|---|---|
| Spelling | `Dicitation` → `Dictation` |
| ASR mishearing | `Plower` → `planner`, `rounds` → `routes`, `טורף` → `טוב` |
| Grammar | agreement, articles, prepositions, broken verb forms |
| Formatting | terminal punctuation, capitals, spoken marks (`dot slash` → `./`), digits |

It must do this in **English, Hebrew and Russian**, which is the whole reason the corpus
is balanced rather than the naturally English-heavy mix the history database contains.

## 2. The measurement

- **Corpus**: 112 cases — 43 real history transcripts with authored corrections, 57 clean
  texts with injected ASR damage, 12 long-form. 47 en / 33 he / 32 ru.
- **Gold is authored, never the app's own output.** Scoring against `ZAIENHANCEDTEXT`
  optimizes for reproducing the errors being removed.
- **Recovery toward gold** for damaged inputs:
  `(sim(out,gold) − sim(in,gold)) / (1 − sim(in,gold))`. A do-nothing prompt scores 0,
  a paraphraser scores negative. Raw similarity is not usable — transcripts already
  resemble their corrections, so similarity ranks do-nothing first.
- **Preservation** for the 10 already-clean inputs: `sim(out,gold)`, headroom 0.02.
  A prompt that improves damaged text by mangling clean text has not improved anything.
- **Headline = balanced score**: the mean of the three per-language means, not the mean
  over cases. The corpus is 47/33/32, so a raw mean still lets a candidate buy the
  headline with English alone.
- **Train vs holdout is always reported separately.** GEPA trains and validates on the
  same 48 balanced cases, so its own number is optimistic by construction. 64 cases are
  never shown to it. **A candidate is ranked on holdout.**

## 3. Hard gates — a candidate that trips one is out, whatever it scores

1. **Language drift.** Any case whose output leaves the input's language is −1.0 and
   disqualifies the candidate. Not a weighted trade-off, not something a strong English
   score can buy back. A user who dictates Hebrew and gets English back has lost their
   text, and no average recovers that.
2. **Preamble or delimiter echo.** The output budget in `LLMPostProcessor.process()` is
   derived from *input* length, so `Here is the corrected text:` or a repeated
   `[INPUT]…[/INPUT]` does not merely look wrong — it consumes budget that real content
   then loses to truncation. Measured on three Russian cases: the correction itself was
   right and got cut off mid-word.
3. **Timeout.** `process()` silently returns the *original uncorrected text* when the
   ladder expires (5s under 30 chars / 10s under 200 / 15s above). A case over budget is
   an invisible no-op in production, so it counts as a failure here even though the
   harness would happily wait.
4. **Degeneration.** Output/input length ratio outside 0.4…2.5.

## 4. Ranked criteria, once the gates are passed

1. **Balanced holdout score.** The single number.
2. **No language below the others by more than ~0.15.** Hebrew at 0.000 is what forced
   the last rewrite; a prompt that only works in English is not multilingual correction.
3. **Preservation stays at 1.000.** Non-negotiable in practice, and every candidate so
   far has managed it.
4. **Generality over memorization.** Worked examples lifted from the corpus are allowed
   *only* if they come from train cases and the holdout number still leads — otherwise
   the score is an answer key. Verified per candidate, not assumed.
5. **p50 latency**, as a tie-break only. Every candidate measured so far is far inside
   the ladder, so this has never actually decided anything.

## 5. Explicitly out of scope

**Paragraph and line-break formatting.** Measured on both models: given a prompt asking
for nothing but paragraph breaks, they emit zero newlines. Across the 12 long-form cases
the reference has 18 breaks and every candidate produces 0 — `STRUCT long` is 0.000 for
all of them. This is a capability ceiling, not a prompt bug, and asking for it spends
budget that turns into drift. Structure is therefore reported separately from content so
it cannot quietly drag a content comparison around.

## 6. Choosing the model

Prompt findings **do not transfer between models** — this is the expensive lesson of
round 9/10 and the reason model choice is part of this document. The same prompt text,
same corpus, same parameters:

| | Qwen2.5-1.5B | Qwen3.5-4B MTP |
|---|---|---|
| W_CLEAN balanced | +0.244 | **+0.358** |
| best measured prompt | +0.244 (W_CLEAN) | **+0.455** (W_FULL) |
| W_FULL behaviour | drifted 4 Hebrew cases → **disqualified** | 0 drift |
| obeys filler-deletion rule | yes | needed re-tuning |
| p50 / max latency | 0.35s / 2.7s | 0.73s / 6.1s (AR floor; MTP is faster) |
| cases over timeout ladder | 0 | 0 |

Selection criteria, in order:

1. **Gates first, on that model.** The best prompt for the 1.5B is disqualified on the
   4B and vice versa, so "which model" and "which prompt" are decided together, never
   separately.
2. **Best achievable balanced holdout on that model**, using a prompt actually optimized
   for it. Comparing a model against a prompt tuned for a different one measures the
   prompt, not the model.
3. **Latency inside the ladder** — the constraint is the timeout, not raw speed. The 4B
   is ~2.1× slower per case and still has zero cases over budget, so speed does not
   separate them. It would if the ladder were tighter or the model larger.
4. **Resident memory**, as the tie-break: ~1.6 GB vs ~3.2 GB. It only decides when the
   quality difference is inside the noise, which here it is not.

On this corpus the 4B wins criterion 2 by a wide margin (+0.455 vs +0.244, an 86%
relative gain) while passing criterion 3 outright, so it takes the workload and pays the
memory. That is the decision the numbers support; it is not a preference.

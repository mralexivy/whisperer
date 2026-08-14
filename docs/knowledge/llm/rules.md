# LLM — Rules

Confirmed. Apply by default.

## Prompting small on-device models

1. **No *English-only* examples in a prompt that must preserve a non-English input
   language.** They are training signal, not illustration, and they outrank the rule
   they contradict. Disclaiming them ("the examples above are illustrative only") is a
   mitigation, not a fix — measured 23/100 translations with the disclaimer in place.
   Deleting them is one answer; **making the set multilingual is the better one** —
   the shipped Correct prompt carries 2 English, 1 Russian and 3 Hebrew examples with
   zero drift on 112 cases, and removing them costs 0.11 balanced.

2. **Constrain by alphabet, symmetrically — never by language name.** *"Cyrillic stays
   Cyrillic, Hebrew stays Hebrew, Latin stays Latin"*, all three listed. Naming a
   language primes the model to emit it; the only prompt that said "Hebrew in, Hebrew
   out" was the only one that translated Hebrew into Russian.

3. **Treat edit-aggressiveness as a drift control.** Checklists, added obligations and
   examples all raise English scores and reopen translation together. Sentence
   mechanics (capitalize, terminal punctuation) is the only addition measured to be
   free. Anything beyond it gets re-measured against the corpus, not argued about.

4. **A correction prompt's default must be to change nothing.** State it first
   ("Your default is to change nothing; you edit only where the text is actually
   wrong") and end with "if the input is already correct, return it verbatim."

5. **No preamble, ever.** The output token budget in `LLMPostProcessor.process()` is
   derived from *input* length, so "Here is the corrected text:" consumes budget that
   real content then loses to truncation.

## Evaluating a prompt change

6. **Never score against the app's own stored output** (`ZAIENHANCEDTEXT` and friends).
   It is the old prompt's output; scoring against it optimizes for reproducing the
   errors being removed. Author gold, or damage clean text so the target is known.

7. **Score recovery toward gold, not similarity to gold.** Raw transcripts already
   resemble their corrections, so similarity ranks a do-nothing prompt first.
   Negative recovery is the signal that a prompt is paraphrasing.

8. **Weight languages equally in the headline** (mean of per-language means). A raw
   mean lets English hide a catastrophic non-Latin score — it hid −0.788 on Russian.

9. **Gates cap the score at 0, they do not set it to 0.** Otherwise a more-broken
   output can outrank a less-broken one. Language drift is the sole exception: flat
   −1.0, below the do-nothing floor.

10. **A ~20-case suite cannot validate a language-preservation claim.** The prompt that
    passed 18/18 was failing 23/100. Non-Latin cases need to be counted in the dozens
    before "it preserves language" means anything.

11. **Decode greedily (`temperature=0`) and save every output.** Scorer changes then
    cost nothing to re-apply; re-running the fleet costs thousands of calls.

## Model selection

12. **Rank models by wall-clock per workload, never by tok/s.** Prefill scales with
    prompt length and dominates long-prompt / short-output work; a 4B with speculative
    decoding out-decodes a 1.5B and still loses both workloads.

13. **A structural quality gate passes a degenerate output.** Parses + timestamps in
    range + non-empty scored 8/8 for an 85-word repeat loop. Pair it with a
    content check (length ratio, word count, or eyeballed side-by-side).

## Degeneration

14. **Scale the requested output length to the input.** Asking a greedy 4B for 250-350
    words from a 150-word transcript produced three good sentences and then
    `to Michael to Michael to to to…` for 48 tokens. A fixed length demand plus a
    generous `outputTokensHint` is a padding instruction on short input — size the
    prompt's word range, the token hint and the timeout together
    (`MeetingAIService.overviewRequest(transcriptWords:)`).

15. **Verify the sampling knobs reach the decoder that actually runs.** `repetitionPenalty`
    was passed and logged on every meeting overview while the MTP path (`generateMTPTokens`)
    was pure greedy argmax with no parameter to receive it. `GenerateParameters` applies to
    the ChatSession path only; a second decode path needs the penalty threaded explicitly,
    and the log line must not claim knobs that path ignores.

16. **Penalize the draft distribution in a speculative decoder, and record the verified
    token before both argmaxes.** Draft and verify must see identical logits or accept/rollback
    stops agreeing and the speculative path degrades to sequential decoding. Penalize
    generated tokens only — never the prompt, or a summary is pushed off its own source.

17. **A degeneration guard must detect a repeating *cycle*, not a stuck token.** "Same token
    N times in a row" misses `to Michael to Michael` (period 2) until its tail happens to
    trip it, tokens too late. Check periods 1-8 over a window, and **truncate the output back
    to before the loop** — stopping generation still ships the junk that was already emitted.

## A summary that comes out too short

18. **Read the stop reason before touching anything.** Stopped on the cap → a budget
    problem. Stopped on a clean EOS → the model believed it was finished, which is a
    prompt defect, and raising the hint or the timeout will change nothing. The shipped
    overview prompt sat at a median 18 words on 12% of its budget, all on EOS.

19. **Put the length in the format line, not in a later bullet.** `OVERVIEW: the summary`
    demonstrated a three-word answer next to five genuinely one-line labels, and template
    shape beat every word count stated further down. State it where the model reads the
    shape: `OVERVIEW: the summary — 140 to 240 words. This is by far the longest field.`

20. **Never ship a stop-directive alongside a length demand.** "Say what it contained and
    stop" / "do not pad" against "write 140 to 240 words" is a conflict a greedy decoder
    resolves toward the instruction it can satisfy immediately — stopping. Anti-degeneration
    belongs in the decoder (repetition penalty + `DegenerationGuard`), not in the prompt.

21. **Convert a length demand into a coverage demand.** "Write more" is not executable by a
    4B; "cover each of the sections you just listed" is. Have the model emit its TOPIC list
    first and state that it is the plan the OVERVIEW must follow. Check the parser first —
    this is only free because `MeetingOverviewParser` dispatches labels independently, and
    `OVERVIEW:` (the one multi-line-absorbing label) must still come after nothing it could
    swallow.

22. **Size `outputTokensHint` in the worst-case script.** Hebrew and Russian run 2-3 tokens
    per word against English's ~1.4. An English-calibrated budget becomes the new ceiling the
    moment a prompt fix starts working, and the resulting truncation reads exactly like the
    decode bug you just fixed.

## Prompt changes to Correct must be measured over all three languages

In Qwen2.5-1.5B, transform-aggressiveness and language drift are the same dial. Confirmed 5×:
memorized examples → 4 Hebrew drifts; a run-on split rule → 2 English→Russian drifts; **rewording
one rule with no new capability → the same 2 drifts**, reproducibly, under greedy decoding.

Never edit `AIMode.correct.prompt` and eyeball the result. Re-run the 112-case gold corpus and
check the per-language row and the drift count. Language drift is a `-1.0` disqualifier, never a
score to trade against — a translated transcript is total data loss for the user.

## When optimizing a prompt automatically, judge on held-out cases

An optimizer maximizes the number it is given. GEPA's top candidate scored +0.325 by copying
seven worked examples verbatim out of its own train set; on the full corpus it translated 4
Hebrew cases and was unshippable. Train and val were the same 48 cases, which made memorization
a valid strategy.

Keep a holdout the optimizer never sees and report it separately. The shipped prompt scores
**higher** on its 64 held-out cases (+0.272) than on the train slice (+0.203) — that, not the
optimizer's own number, is the evidence it generalizes.

## Do not ask this model for paragraph breaks

Qwen2.5-1.5B emits zero newlines with byte-identical output length in 5 of 6 probes when the
prompt asks for nothing else. It is a capability limit. Prompt budget spent on it converts into
language drift. Formatting needs a deterministic Swift pass, not a prompt.

Confirmed on Qwen3.5-4B MTP too: `STRUCT long` 0.000 for every candidate, 18 reference paragraph
breaks produced 0 times. Closed on both models — do not retry it by prompt on a third.

## A prompt is a property of the (prompt, model) pair — re-measure on a model change

Round 9 tuned Correct against Qwen2.5-1.5B; the model actually running it is Qwen3.5-4B MTP.
Re-measuring the same texts on the 4B **inverted** two of the four conclusions that had been
written into `AIMode.swift` as warnings: worked examples caused 4 Hebrew drifts on the 1.5B and
0 drifts plus +0.11 balanced on the 4B, and rule 7's corpus-specific mishearings hurt holdout
there and help here.

So: changing `selectedLLMModel` / `MeetingEngines.intelligenceVariant` invalidates the Correct
prompt's measurement, and shipping a prompt tuned on model A to model B is untested work.
Model choice and prompt choice are one decision — see [criteria.md](criteria.md).

## Examples shaped like the user-message scaffold get imitated into the output

Seven examples written as `[INPUT]x[/INPUT] → y` made the 4B emit `[INPUT]…[/INPUT] →` in its
answers on 3 of 112 cases. The same seven as blank-line-separated `before:` / `after:` lines
echo 0 times and score higher (+0.478 vs +0.455 balanced).

This is format imitation, not reasoning leakage: `enable_thinking: false` is already set on
every path, and Qwen3.5's template does not skip thinking under that flag — it prefills an
*empty* `<think></think>`, so there is nothing further to disable. Reformat the examples; do not
add a "never output [INPUT]" sentence (measured: +0.006 holdout, −0.03…−0.04 Hebrew).

The cost is not cosmetic — `LLMPostProcessor.process()` derives `maxTokens` from **input**
length, so an echo consumes budget the real correction then loses to truncation.

## Sampler-level fixes for echo are unavailable in this stack, and mostly unsound

`GenerateParameters` (`Vendor/mlx-swift-lm/Libraries/MLXLMCommon/Evaluate.swift`) has no
`logitBias`. Banning the input's first token is wrong anyway — the correct output usually starts
with that same word (`нам нужно` → `Нам нужно`) — and banning `[` breaks dictated code
(`./src/utils`, `docker run --rm -it`). A content-bearing assistant prefill is impossible because
the first correct word is unknown when the input opens with a filler. Fix echo in the prompt.

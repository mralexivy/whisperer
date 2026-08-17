# LLM Prompting — Knowledge

Facts and confirmed patterns for the on-device LLM (`LLMPostProcessor`) used by
meeting titles, meeting overviews, and Ask AI.

## The output budget is the summary length

`LLMPostProcessor.process()` computes `maxTokens = min(maxTokensCap, outputTokensHint)`
when a hint is given. A prompt asking for a 300-word summary with
`outputTokensHint: 600` is not wrong, but a prompt asking for a 300-word summary
with the old `outputTokensHint: 600` **and** a `timeoutSecondsOverride: 60` gets cut
off mid-generation on slower models, because the MTP path stops on the timeout
regardless of remaining tokens. Scale both together: ~1.4 tokens per English word,
plus headroom for the structured lines.

Current settings for `MeetingAIService.generateOverview`, all from
`overviewRequest(transcriptWords:)`:

| Kind | Transcript | Asked for | outputTokensHint | timeout |
|---|---|---|---|---|
| Note | < 60 words | 40-90 words | 300 | 40s |
| Brief | < 250 words | 90-180 words | 700 | 90s |
| Standard | < 700 words | 140-240 words | 1100 | 140s |
| Full | ≥ 700 words | 250-400 words | 1600 | 180s |

**Size the hint in the worst-case script, not in English.** Hebrew and Russian
tokenize at roughly 2-3 tokens per word against English's ~1.4, and the TOPIC lines
draw from the same pool. A hint calibrated on English becomes the new ceiling the
moment a prompt fix starts producing target-length output — the failure then looks
like truncation and gets misdiagnosed as a decode problem.

## Asking for more words than the source contains causes degeneration

A 150-word transcript given the full prompt ("250 to 350 words… do not stop after
three sentences", `outputTokensHint: 1200`) produced three good sentences and then
`to Michael to Michael to to to…` for 48 tokens. Greedy decoding cannot climb out of
that on its own — the argmax that produced the loop is the argmax the same state
produces again. The demand has to fit the material: the request length, the token
hint and the timeout all scale with the transcript, and the "do not stop after three
sentences" line — load-bearing for an hour-long meeting, see below — appears only in
the ≥ 700-word tier.

Two independent defences behind that, both worth keeping:

- **A repetition penalty must reach the decoder that is actually running.**
  `repetitionPenalty: 1.15` was passed on every overview call and logged, but the
  meeting model is MTP and `generateMTPTokens` had no parameter to receive it — a
  configured knob silently dropped for the whole life of the feature. When adding
  sampling to a speculative decoder, penalize the draft distribution too: draft and
  verify must argmax the *same* penalized logits or every accept becomes a coin toss.
  Record generated tokens only; penalizing the prompt pushes a summary off its source.
- **A degeneration guard must detect cycles, not a stuck token.** The old guard
  counted "same token 48 times in a row" — `to Michael to Michael` has period 2 and
  slipped past it until its one-token tail happened to trip it, 48 tokens too late.
  `DegenerationGuard` checks periods 1-8 and returns a rewind point so the looping
  tail is cut from the text before it reaches the parser, CoreData or the UI.

## Small models pad to the shortest instruction that satisfies the prompt

"Write one paragraph (2-4 sentences)" produced overviews that named the topic
without stating its content — "the speaker explained how machine learning relates
to AI" instead of "machine learning is a subfield of AI in the way thermodynamics
is a subfield of physics". Fixes that worked:

- Give an explicit word range and paragraph count (250-350 words, 2-4 paragraphs)
  — sized to the transcript, per the section above.
- Say "do not stop after three sentences" — the negative instruction is load-bearing
  when there is genuinely that much to say, and a padding instruction when there is not.
- Ban the "In this recording / The speaker discusses" opener explicitly; models
  default to it and it eats a sentence saying nothing.
- Show a good/bad rewrite pair in the prompt. One concrete example moves the model
  further than three more rules.

## Conditional structure invites fabrication

The prompt used to branch on "if this is a real meeting with multiple speakers,
write DECISION / OPEN / NEXT / ACTION". For a lecture or a solo voice note the model
still filled the format, inventing decisions and assigning action items to people
who were never named. Framing that flips it: state that omitting a label **is** the
correct answer when the thing did not happen, and require a real named person before
an ACTION line.

## The model can only cite timestamps it was given

`MeetingRecord.fullTranscript` is segment text joined with spaces — no timestamps at
all. Feeding that to a prompt whose format has `| <seconds>` fields makes the model
invent the numbers. `MeetingAIService` now builds `[95s] Speaker 1: text` lines from
`[MeetingSegment]` and tells the model to copy the number. Seconds (not `MM:SS`) so
there is no arithmetic to get wrong.

## Titles need post-processing, not just prompting

Even with "reply with the title and nothing else", small models emit `TITLE: …`,
wrap in quotes, add a trailing period, or prepend `**`. `sanitizeTitle()` strips all
of it and rejects output that is empty, under 3 chars, or itself auto-title-shaped.
Assume prompt compliance is ~80% and write the sanitizer.

## Speaker count does not classify a recording

Superseded in mechanism, not in conclusion: Sortformer now assigns real
`speakerIndex` values, so the old "every segment is Speaker 1" no longer holds. The
conclusion does. A lecture with one audience question and a two-person meeting both
report two speakers, so the count still cannot separate a monologue from a
discussion. The reliable Swift-side signals remain word count and duration; the rest
is left to the prompt.

## MLX loads safetensors — a GGUF repo is not usable by this stack

`LLMPostProcessor` loads through the vendored `mlx-swift-lm` via
`ModelConfiguration(id:)`, which fetches **safetensors** from the HF Hub. A
`…-GGUF` repo is llama.cpp's format and will not load, however correct the model
name is. The MLX mirror is the `mlx-community/<model>-<bits>bit` naming, e.g.
`mlx-community/Qwen2.5-1.5B-Instruct-8bit`.

Resolution goes by `model_type`, not by repo name: `"qwen2"` is registered in
`MLXLLM/LLMModelFactory.swift` → `Qwen2Model`, and is **absent** from
`VLMModelFactory`, so the generic `loadModelContainer` path resolves it with no
factory override. Only MTP variants need the `LLMModelFactory.shared` override.

## Parameter count does not predict wall-clock — prefill does

Measured three-way on real history fixtures (M-series, 8-bit MLX). Decode throughput
and end-to-end latency disagree, and the workload decides which one matters:

| workload | model | median tok/s (decode) | total wall | worst case |
|---|---|---|---|---|
| dictation, 18 cases | Whisperer V3 (0.6B) | 32.6 | 34.8s | 3.0s |
| dictation, 18 cases | Qwen2.5-1.5B | 28.9 | 39.1s | 3.3s |
| dictation, 18 cases | Qwen3.5-4B MTP | **37.8** | 44.4s | 4.9s |
| meetings, 8 cases | Qwen2.5-1.5B | 31.6 | **28.2s** | 8.6s |
| meetings, 8 cases | Qwen3.5-4B MTP | 30.6 | 60.0s | 22.3s |

**A 4B with speculative decoding out-decodes a 1.5B without it** — 37.8 vs 28.9
tok/s, at MTP accept rates of 6–92% (median ~65%; the 6% outlier was a short Hebrew
chunk). That result is counter-intuitive enough to get re-litigated from parameter
counts, so it is recorded here. It still loses both workloads on wall-clock, because
prefill scales with prompt length and the 4B's is several times slower: on a
4627-token meeting transcript it spent **16.0s** in prefill against the 1.5B's 2.9s.

The rule that follows: for long-prompt / short-output work (meeting overview, Ask AI,
title — the whole transcript is the prompt) prefill dominates and decode speed is
nearly irrelevant. Measure wall-clock per workload; never rank models by tok/s alone.

## English examples in a prompt override an explicit "do not translate"

`AIMode.correct`'s prompt states *"Keep the same language. Do not translate."* and then
spends 200 words on English-only demonstrations (`"five hundred dollars" → "$500"`,
`"dash dash rm" → "--rm"`, `"heart eyes emoji" → "😍"`). Qwen2.5-1.5B translated
**every** Hebrew and Russian input to English under that prompt — 4/4 non-Latin cases —
while passing the same inputs under `Grammar`, whose prompt carries the identical rule
in two lines with no examples.

The demonstrations, not the rule, were being followed. The fix was to state that the
examples are illustrative only and do not set the output language, and to repeat the
language requirement *after* them: recency wins for a small model, and a rule buried
60 words upstream of contradicting evidence does not survive. That took the model from
14/18 to 18/18 with no change to the other two.

Generalizes: when a prompt contains few-shot-shaped examples, they are training signal.
Any invariant they appear to violate must be restated after them.

> **Corrected 2026-08-13 — the diagnosis held, the fix did not, and 18/18 was the
> reason nobody noticed.** Re-measured against a 100-case gold corpus (43 real history
> transcripts, 57 authored+damaged, balanced 42 en / 30 he / 28 ru), that "fixed"
> prompt still translated **23 of 100** inputs and scored **−0.788** on Russian —
> below the score for doing nothing at all. An 18-case suite with 4 non-Latin cases
> could not see a 23% failure rate; passing it was evidence of nothing.
>
> Disclaiming examples does not disarm them. Only *deleting* them does, and the
> deletion has a price paid in a different currency — see the two sections below.
> Treat "restate the invariant after the examples" as a mitigation, never a fix.

## Neither model reaches the 250–350 word overview band

The `overviewPrompt` used to demand 250–350 words across 2–4 paragraphs at every
tier. Measured on real meetings: Qwen2.5-1.5B produced 63 and 70 words, Qwen3.5-4B
produced 6 words on one and an 85-word repeat loop on the other ("The conversation
about budget, cost, translation model The conversation budget cost translation…")
that tripped `LLMPostProcessor`'s degeneration guard at 48 identical tokens.

Two things follow. The word-count target was aspirational for models this size and is
a warning in the benchmark rather than an assertion. And a *structural* quality gate —
parses, timestamps in range, non-empty — passes a degenerate summary, so it cannot be
the only check; the 4B scored 8/8 while emitting that loop.

## The one-sentence overview was a prompt defect, and EOS is how you know

Over 34 real meetings the shipped prompt produced a **median 18-word** overview at
**12%** of the token budget — 1484 words in → 91 tokens / 27 words out; 1251 → 192
tokens / 19 words; 208 → 20 tokens / a **2-word** overview. Every one of them
terminated on a clean EOS rather than a cap.

That distinction is the whole diagnosis and is cheap to log: a run that stops on the
cap is a budget problem, and a run that stops on EOS is the model believing it is
finished — which is the prompt's fault, not the decoder's. Reference overviews written
by a frontier model over the same library ran 70 / 146 / 183 / 318 words by tier
(n = 33 / 62 / 8 / 3), so this was a ~10× gap with the budget three-quarters unspent.

Four causes, all in the prompt text:

- **The FORMAT block demonstrated the wrong length.** It literally read
  `OVERVIEW: the summary` — a three-word value sitting above the rules, beside five
  genuinely one-line labels. Template shape beats a word count buried in a later
  bullet. Put the count in the format line where the model reads the shape.
- **Stop-directives beat length-directives.** "Say what it contained and stop", "do
  not pad", "padding it out is worse than a short answer" — anti-degeneration hedges
  written before the repetition penalty reached the MTP decoder. Against "write 140
  to 240 words" a greedy decoder resolves the conflict toward the instruction it can
  satisfy immediately, and stopping is that instruction. Once the penalty and
  `DegenerationGuard` exist, these belong in the decoder, not the prompt.
- **No worked example of density.** Added as a contrastive pair — one thin OVERVIEW
  marked wrong, one correct — kept short on purpose, since a full-length example
  biases every tier toward its own word count and triples the prefill.
- **"Write more" is not executable by a 4B; "cover these" is.** See below.

## Emitting the section list before the summary is a planning step

`MeetingOverviewParser.parse` dispatches each label in an independent branch, so
label order in the model's output is free — `TOPIC:` may precede `OVERVIEW:`. Moving
TOPIC first, and telling the model the TOPIC lines are its plan that the OVERVIEW
must then cover in order, converts an unenforceable length demand into a coverage
demand. Five named sections cannot be covered in eighteen words.

This is the same lever as the good/bad rewrite pair, one level up: give the model
something to *execute* rather than a quantity to hit.

Cost check before relying on it: `OVERVIEW:` is the only multi-line-absorbing label
(everything after it belongs to it until the next label appears), so it has to be
last among the fields it could swallow — putting TOPIC before it is safe, putting it
before DECISION/OPEN/NEXT/ACTION would not be.

## Name the alphabet, not the language

Telling a small model *"if it is Hebrew, answer in Hebrew; if it is Russian, answer in
Russian"* primes the languages it names. The one candidate built on `"Russian in,
Russian out. Hebrew in, Hebrew out."` was also the only one of 25 that translated
**Hebrew into Russian** — 6 of its drifts. Naming a language is a two-sided coin: a
nudge to preserve it, and a nudge to emit it.

Naming the three *alphabets* symmetrically has no such target:

> Whatever alphabet [INPUT] is written in, your output is written in that same
> alphabet: Cyrillic stays Cyrillic, Hebrew stays Hebrew, Latin stays Latin.

Latin is listed deliberately. Dropping it makes the sentence a rule about non-Latin
scripts and re-introduces an asymmetry the model can lean on.

**It is not a drop-in upgrade.** Swapping this triad into the *old* example-laden body,
in place of its "if it is Hebrew…" line, made drift **worse** — 23 → 33 of 100. That
much-maligned line was the only thing holding a prompt full of English demonstrations
together. The triad works in a prompt with no examples; it is not a patch for one that
has them.

## Transform-aggressiveness and language drift are the same dial

In Qwen2.5-1.5B, every intervention that made the model edit harder also made it
translate. Measured across 25 candidates on the same corpus (`xlat` = inputs
translated out of their own language, of 100):

| change | xlat | en | ru |
|---|---|---|---|
| body with no examples, alphabet triad | **0** | +0.38 | +0.25 |
| …plus a numbered checklist | 14 | +0.44 | +0.20 |
| …checklist with every English example deleted | 13 | +0.39 | +0.21 |
| …plus "fix clear grammatical errors even when the meaning is understandable" | 3 | +0.47 | +0.08 |
| shipping prompt before this work | 23 | +0.39 | −0.79 |

Deleting the examples from the checklist variant moved drift by one case (14 → 13):
the checklist *structure* drives both the best English score and the drift. So the
earlier "examples are the problem" story is half of it — examples are one lever, task
aggressiveness is another, and **both push the same way**. English recovery above
roughly +0.40 was not reachable at zero drift by any of the 25 candidates.

The one exception found: *"Every sentence must begin with a capital letter and end with
a punctuation mark."* Sentence mechanics are the least semantic edit there is, and it
bought en +0.25 → +0.38 and halved the do-nothing rate (49 → 30 of 76 damaged inputs
returned byte-identical) at zero drift. That line is the measured ceiling on how much
work this prompt may demand. Anything added past it must be re-measured, not reasoned
about.

## Scoring a correction prompt: three things that were wrong the first time

Built to optimize `AIMode.correct`; the mistakes generalize to any rewrite eval.

**1. Never score against the app's own stored output.** The obvious corpus is
`ZAIENHANCEDTEXT` from history — thousands of rows, free. It is the *old prompt's*
output, so scoring against it optimizes for reproducing the errors being removed. Gold
has to be authored: real transcripts corrected by hand, plus clean text deliberately
damaged so the target is known exactly.

**2. Recovery, not similarity.** `sim(out, gold)` ranks a prompt that changes nothing
above one that tries and half-succeeds, because raw transcripts already resemble their
corrections.

```
recovery = (sim(out,gold) − sim(in,gold)) / (1 − sim(in,gold))
```

0 = no-op, 1 = reached gold, **negative = moved away**, which is the discrimination
that matters: paraphrase and over-editing land below doing nothing. Inputs that were
already correct have no headroom, so they score as preservation (`sim(out,gold)`)
instead — rewriting clean text is a defect, not a neutral act.

**3. A gate must cap the score, not set it.** Setting gated cases to a flat 0.0 let a
gated case *outrank* the same case ungated: two finalists both degenerated into Latin
gibberish on one Hebrew input, and the one whose gibberish ran longer tripped the
length-ratio gate and collected 0.0, while the shorter, equally broken output stayed
under the gate and earned its true −1.0. Being more broken must never score better.
Gates cap at `min(0.0, recovery)`. Language drift is the exception — a flat −1.0, below
the do-nothing floor, because the user spoke Hebrew and got English back and their text
is simply gone.

Two further details that changed conclusions:

- **Script gate on presence, not majority.** `"Запусти docker run --rm -it ubuntu bash."`
  is majority-Latin because the command dominates. Under a majority test a genuine
  translation of its one Russian word passed clean, while a correct Cyrillic answer was
  flagged as drift — exactly backwards. Ask instead: the gold contains Cyrillic, so the
  output must contain Cyrillic.
- **Headline = mean of the three per-language means.** The corpus is 42/30/28, so a raw
  mean still lets a candidate buy the score with English. The shipping prompt's +0.39
  English was hiding −0.79 Russian.

Greedy decoding at `temperature=0` makes the whole thing replayable: outputs are saved,
so every scorer change is re-scored for free instead of re-running 2,500 model calls.

## Result of the `AIMode.correct` rewrite (2026-08-13)

| | before | after |
|---|---|---|
| inputs translated out of their language | 23 / 100 | **0 / 100** |
| balanced score | −0.066 | **+0.308** |
| Russian | −0.788 | **+0.246** |
| Hebrew | +0.200 | +0.298 |
| English | +0.391 | +0.380 |
| real user transcripts | +0.016 | **+0.371** |
| prompt length | 1481 chars | 1015 chars |

Latency is unchanged and nowhere near the `process()` ladder: 0.33s p50 / 1.23s max
against budgets of 5 / 10 / 15s. That matters because `AIMode.correct` is per-chunk
(`supportsChunkProcessing`) and sits on the visible stop→injection path, and a timeout
there silently returns the *uncorrected* text.

Verified on the real production path via `LLMModelComparisonTests` — Hebrew and Russian
dictation both come back in their own script. Note that `Grammar` and `Translate` were
left untouched and still carry the old example-laden body; on one Hebrew case the 1.5B
emitted a literal `[OUTPUT]` prefix under `Grammar`. Same treatment is available to
them, unmeasured so far.

## GEPA evolution of the Correct prompt (round 9 — Qwen2.5-1.5B, superseded)

> **Every number and every warning in this section is specific to Qwen2.5-1.5B.** Round 10
> re-measured the same prompts on Qwen3.5-4B MTP and two of the conclusions below invert
> outright. Read this section as "what the 1.5B did", never as "what prompts do".


Hand-authoring plateaued at `AA_P_PUNCT` (+0.178 balanced). Rounds 7 and 8 added eight more
candidates and every one scored below it. The bottleneck was not wording quality but the
authoring loop: I was guessing which correction the prompt failed to license. GEPA
(`gepa-ai/gepa`) replaces the guess — it reads the per-case failures and proposes the next
prompt from them. Setup: task model = the shipping Qwen2.5-1.5B, teacher = Claude Opus via the
`claude` CLI, feedback = three word-level diffs per case (input→gold "required", input→output
"made", output→gold "still wrong"), 24 iterations over a balanced 48-case train slice with 64
cases held out.

| prompt | balanced | en | he | ru | drift | train | **holdout** |
|---|---|---|---|---|---|---|---|
| `AA_P_PUNCT` (previous) | +0.178 | +0.317 | +0.000 | +0.218 | 0 | +0.136 | +0.207 |
| GEPA winner as returned | +0.290 | +0.405 | +0.083 | +0.383 | **4** | +0.325 | +0.250 |
| **de-memorized (shipped)** | **+0.244** | +0.202 | **+0.226** | +0.303 | 0 | +0.203 | **+0.272** |
| + run-on split rule | +0.178 | +0.147 | +0.168 | +0.219 | **2** | +0.120 | +0.222 |
| + rule-1 reword only | +0.170 | +0.144 | +0.219 | +0.146 | **2** | +0.158 | +0.170 |

### GEPA's own best score was inflated and its top prompt was unshippable

The winner it returned scored +0.325 on the train slice. Seven of its worked examples were
lifted **verbatim from train cases** — 8 of 9 memorization probes hit train, 0 hit holdout. It
had written the answer key into the prompt. Worse, it was disqualified outright: 4 Hebrew cases
translated (he→ru, he→en, he→he+ru). Deleting the examples and generalizing rule 7 from a
glossary of corpus-specific mishearings ("Plower → planner") to a general instruction cost
0.046 balanced and **gained** 0.022 on holdout.

**This is the reason for the held-out split, and it is not optional.** GEPA optimizes the number
you give it; if train and val are the same set, memorization is a valid strategy and it will
find it. Judge on cases the optimizer never saw.

### Transform-aggressiveness and language drift are one dial (now 5× confirmed)

Every attempt to make the prompt do more was paid for in language preservation:

- memorized examples → 4 Hebrew drifts
- a run-on sentence-split rule (with a multilingual conjunction list) → 2 English→Russian drifts
- **merely rewording rule 1** (no new capability, no new languages named) → the same 2 drifts

The last one is the striking result: a one-line edit that adds nothing tipped `en06` and `cs02`
into Russian, reproducibly, under greedy decoding. The shipped prompt sits at a real frontier,
not a local dip. Anything added must be re-measured over all three languages.

### What the rewrite actually bought

Hebrew, which was the complaint. The old prompt scored **exactly 0.000** on it: it returned 52%
of Hebrew inputs untouched and the edits it did make were net-destructive (+0.000 overall,
−0.124 on the cases where it edited). The new prompt drops the Hebrew no-op rate 52% → 15% and
scores +0.226. English pays 0.115 for it. That trade is deliberate — balanced score is the
headline precisely so English cannot buy the number on its own.

### Formatting is out of reach for this model — closed, do not retry by prompt

Given a prompt asking for *nothing but* paragraph breaks, Qwen2.5-1.5B emitted **zero newlines
with a byte-identical output length in 5 of 6 probes** (en/he/ru × 2 prompt styles; the sixth
produced 2 breaks). Every formatting-oriented candidate in rounds 7–8 also scored `STRUCT long
0.000` with 0 of 18 gold paragraph breaks produced, while re-opening translation. This is a model
capability limit, not a wording problem.

Separately, formatting could not reach the user on the live path even from a perfect prompt:
`AIMode.correct.supportsChunkProcessing == true`, so Correct runs per VAD chunk (measured p50 =
112 chars, p90 190, over 387 real chunks), and `ChunkLLMCoordinator.drain()` rejoins them with
`joined(separator: " ")` while `repairSeams()` strips LLM-added terminal punctuation at seams.
Paragraphs would need a deterministic Swift pass over the joined text, or a full-text pass that
does not fit `maxTokensCap: 256`.

### Operational notes

- Core GEPA has `dependencies = []`. When `pip` is unusable (corporate index, TLS interception),
  `git clone` it and `sys.path.insert` the `src/` directory. No install needed.
- A `GEPAAdapter` that simply omits the optional `propose_new_texts` hook silently drops **every**
  reflection: `reflective_mutation.py:210` reads the attribute before testing whether it exists,
  so the `AttributeError` is swallowed as "did not propose a new candidate". Declare it `None`.
- Teacher strength is load-bearing. Sonnet-as-teacher proposed a first candidate that drifted
  ~15 of 48 cases despite the language constraint being stated verbatim in the template.
- `skip_perfect_score=True` (default) means the already-clean preservation cases, which score
  exactly 1.0, are skipped in minibatches — reflection focuses on failures for free.

## Round 10 — re-optimizing Correct for Qwen3.5-4B MTP (2026-08-14, shipped)

Round 9 optimized against Qwen2.5-1.5B. The model behind Correct is Qwen3.5-4B MTP
(`Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed`), so round 9 tuned a prompt for a model that
does not run it. Round 10 re-ran every candidate on the 4B, same 112-case corpus, same
greedy decoding, same production parameters. Objective and acceptance criteria are written
down separately in [criteria.md](criteria.md).

| candidate | balanced | en | he | ru | **holdout(64)** | gates |
|---|---|---|---|---|---|---|
| `AA_P_PUNCT` (pre-round-9) | +0.298 | +0.406 | +0.128 | +0.361 | +0.286 | 0 |
| round 9's shipped prompt | +0.358 | +0.336 | +0.322 | +0.417 | +0.311 | **2** (1 drift, 1 echo) |
| same, examples removed | +0.366 | | | | +0.303 | 0 |
| GEPA's own 4B winner | +0.424 | | | | +0.389 | 0 |
| round 9's prompt + 7 examples | +0.455 | +0.467 | +0.431 | +0.469 | +0.401 | **3** (echo) |
| **shipped (examples reformatted)** | **+0.478** | +0.472 | +0.457 | +0.506 | **+0.442** | **0** |
| + anti-echo guard sentence | +0.482 | +0.470 | +0.426 | +0.549 | +0.448 | 0 |
| + guard, worded differently | +0.495 | +0.500 | +0.423 | +0.563 | +0.447 | 0 |

Best on the 1.5B was +0.244 balanced. The 4B nearly doubles it. Preservation is +1.000 on
the 10 already-clean inputs, latency p50/max 0.66s/5.39s against a 5/10/15s ladder.

### Prompt findings do not transfer between models — the expensive lesson

Same text, same corpus, same parameters, opposite conclusions:

| round 9 concluded, on the 1.5B | round 10 measured, on the 4B |
|---|---|
| worked examples → 4 Hebrew drifts, unshippable | worked examples → **0 drift, +0.11 balanced** |
| rule 7 naming specific mishearings hurt holdout | naming them is part of the leading candidate |
| rewording one rule tipped 2 English cases to Russian | no candidate drifted at all except round 9's own |

Two of the four "must not be cleaned up" warnings in `AIMode.swift` were therefore false for
the model actually running them. A prompt is a property of a (prompt, model) pair; changing
either invalidates the measurement. This is why model choice is documented alongside the
prompt in `criteria.md` rather than treated as an independent decision.

**It fails in the other direction too, and worse.** The shipped 4B prompt run unchanged on
Qwen2.5-1.5B scores +0.236 balanced (vs +0.478) and is **disqualified — 7 Hebrew cases
translated away** (`he_s2` he→ru, `he_s3` he→en, `he_s6` he→en, `he_s8` he→he+ru, `he_s9`
he→ru, `he_s12` he→he+ru, `he_s15` he→en), Hebrew mean −0.066, preservation down to +0.786,
and one case over its timeout ladder. So this is not "the prompt is merely suboptimal on the
smaller model" — pairing this prompt with the 1.5B is a Hebrew data-loss bug. Whichever model
`AppState.selectedLLMModel` points at must be the one the prompt was measured on.

### The `[INPUT]…[/INPUT]` echo was in-context format imitation, not reasoning leakage

Three Russian cases came back as `[INPUT]\n<input text>\n[/INPUT] → Бюджет 5` — the answer was
right and then truncated mid-word. Diagnosis, in order:

1. **Not `<think>`.** `enable_thinking: false` is already passed on every production path, and
   the failing outputs contain no think block. Qwen3.5's template does not *skip* thinking when
   that flag is false — it **prefills an empty one** (`{{- '<think>\n\n</think>\n\n' }}`), so the
   assistant turn always opens pre-closed. There is nothing left to disable.
2. **Dose-response identified the source.** 0 examples → 1 echo; 7 examples written as
   `[INPUT]x[/INPUT] → y` → 3 echoes. The model was copying the *shape* of the example block.
3. **Fix: reformat, do not forbid.** Rewriting the same seven examples as blank-line-separated
   `before:` / `after:` lines took echoes to 0 and *gained* 0.023 balanced / 0.041 holdout. An
   added "never emit [INPUT]" sentence also works but costs 0.03–0.04 of Hebrew, so the shipped
   prompt does not carry one.

The echo is not cosmetic. `LLMPostProcessor.process()` derives `maxTokens` from **input** length,
so echoed delimiters spend budget the real correction then loses.

### Levers that are unavailable or unsound here, and why

- **Logit bias** — `GenerateParameters` in the vendored `mlx-swift-lm`
  (`Libraries/MLXLMCommon/Evaluate.swift`) has no such field; it would mean patching the sampler.
- **Banning the input's opening token** — wrong on the common case: the correct output usually
  *does* start with that word (`нам нужно` → `Нам нужно`). The only safe ban target is `[`, which
  breaks dictated code (`./src/utils`, `docker run --rm -it`).
- **A content-bearing assistant prefill** — the first correct word is not knowable in advance.
  The prompt's own "your first word is the input's own first word" is false whenever the input
  opens with a filler (`um so i think…` → `So I think…`).
- **Whitespace isolation between scaffold and answer** — moot for a ChatML model:
  `<|im_end|>\n<|im_start|>assistant\n` plus the empty think block always sit in between.

### Examples carry the gain; their provenance was checked, not assumed

Stripping the seven examples costs 0.112 balanced and 0.139 holdout — more than any rule wording
change measured in ten rounds. All seven come from **train** cases (`lg_en5`, `lg_he0`, `he08`,
`ru_s6`, `cd03`, `cd01`, `he_s10`), verified case by case, so the 64 held-out cases are not an
answer key and holdout still leads every other candidate.

### Hand-built beat the optimizer this round

GEPA's 4B winner (8871 chars, markdown sections, an 11-rule list, a `# Never` block and a
`# Before you send` checklist) scored +0.424/+0.389 — below the 3033-char hand-built prompt at
+0.478/+0.442. GEPA was still what found the seven examples in round 9; what it could not do was
notice that their *formatting* was causing the failures, because echo shows up as a truncated
score, not as a distinct signal it optimizes against.

### Formatting is still out of reach — now confirmed on both models

`STRUCT long` is 0.000 for every candidate on the 4B as well: 18 paragraph breaks in the
reference across the 12 long-form cases, 0 produced. Same as the 1.5B. Closed on both.

## Batched decode — measured ceiling on M2 Pro (2026-08-16)

Full round-by-round tables: `docs/exec-plans/batched-llm-rounds.md`. The durable facts:

**Batching a 4-bit model on Apple silicon is worth ~4.5×, not ~25×.** Measured on
Qwen3.5-4B-MTP, M2 Pro/32 GB, real chunk text: 37.9 tok/s at B=1 → 172 tok/s at B=32.
Beyond B≈32 throughput is flat to B=96 while ms/step grows linearly.

**Why the usual "batching is nearly free" reasoning does not apply here.** It assumes
decode stays memory-bandwidth-bound, which holds for fp16 weights. With 4-bit weights MLX
switches above a small batch (the jump is visible between B=4 and B=8) from a narrow
matvec to dequantise-then-GEMM, and the dequantisation is arithmetic a batch-1 step never
pays. Decode is compute-bound from B≈8–16 onward. Expect the same shape for any quantised
model on this class of GPU.

**Prefill does not batch.** 341 tok/s at B=1 versus 274 tok/s at B=32 — a 150-token prefill
already saturates the GPU. On short-prompt/short-output work like dictation correction
prefill is roughly half of end-to-end wall-clock, so end-to-end gain is ~2.5–3× even where
decode gains 4.5×.

**Retiring finished rows is worth more than any other knob.** Ragged real chunks at B=32
average 15 live rows out of 32. Never compacting: 58.7 tok/s. Compacting: 112 tok/s (1.9×).
The threshold itself is worth 2% anywhere in 0.1–0.5.

**Chunk arrivals are too sparse to batch mid-stream.** 295 real chunks: inter-arrival p50
6.84s against a ~0.7s correction, only 18% of gaps ≤ 2s. Batching can only pay off at the
drain after key release (p90 11 chunks outstanding), on whole-text splitting, and on
meeting segments — never while the user is still speaking.

**Right-padded batching is not bit-exact, and cannot be made so.** Unpadded rows are exact
at any B (verified: identical-row B=8 == B=1, and the unpadded row of a ragged batch has a
logit delta of exactly 0.0). Padded rows drift ≤0.28 in logit space — one bf16 rounding
step on logits of magnitude tens — which flips the greedy pick on the ~11% of real chunks
where the top-two gap is small. Every observed flip was a comma or an article. Any plan
that assumes "greedy is deterministic so batched == serial" is wrong on this hardware.

### Where batching actually pays, measured end to end (2026-08-17)

**The streaming per-chunk path gains nothing, and that is a property of speech.** Real
recordings replayed at real arrival timing, release→text-ready: serial 7.1 s vs batched
6.9 s over six recordings (1.03×). The scheduler's widest real batch was 3, and on four of
six recordings every batch was width 1. With a 6.84 s median inter-arrival against a ~0.7 s
correction there is simply nothing co-resident to coalesce. The value of wiring the
scheduler into this path is that it *cannot* regress it (width 1 routes back to
single-stream MTP), not that it speeds it up.

**Whole-text correction is where the win is: 1.92× over serial segments** on the five
longest real recordings, 198 s vs 379 s, with word retention 100% vs 96%.

**And the bigger finding underneath it: the single whole-text pass was not correcting long
dictation at all.** `AIMode.correct` caps output at 256 tokens, so on a 12,000-character
transcript the model stops a fifth of the way through and the app returns the truncated
prefix or falls back to raw — 76% of words across the sample, 43% on one. Splitting applies
the cap per segment, so it stops binding. Any future measurement of "the whole-text path"
must check what fraction of the input it actually returned before comparing times; a
truncating baseline looks fast.

**A whole-batch timeout must scale with row count.** Rows past the planner's slice width run
sequentially, so one `processBatch` call with 87 rows is several generations sharing one
deadline. A fixed 30 s budget silently truncated the largest batches and presented as
53–74% word retention — indistinguishable from a batching correctness bug.
`defaultTimeout(rowCount:)` = `max(30, 1.5 × rows)`.

**Word-retention metrics need loop-free inputs.** Whisper hallucination loops ("it's okay,"
×40) are collapsed by the degeneration guard, which is correct and scores as ~98% of words
lost. Exclude fixtures whose *input* loops and print the exclusion count, or the metric
measures the guard.

**The throughput curve is stable to ≤1% run to run** (five runs per width, idle machine), so
a single reading of it is trustworthy — unusual enough to be worth recording.

### Is another model simply faster? Gemma-4-E2B vs the shipped Qwen3.5-4B (2026-08-17)

Cactus Compute publish `1294/64` prefill/decode for Gemma-4-E2B on an M3 Pro. That is one
single-stream run, not aggregate throughput, and their page states "no speculative decode or
MTP". Reproduced on this M2 Pro with **stock mlx-lm** and their MLX port
(`Cactus-Compute/gemma-4-e2b-it-hybrid-mlx`), 1k prefill / 100 decode: **gemma 2083 / 78.6**
against **Qwen3.5-4B 383 / 61.3**. Exceeding their published figure with the stock runtime
means there is no runtime magic in the number — it is the model. Note also that their MLX
port is ordinary affine 4-bit g64, not the proprietary quantisation the marketing describes.

On **our** workload — the shipping `Correct` system prompt read out of `AIMode.swift`, 24
real chunks from the corpus, `enable_thinking: false`, the app's own `maxTokens` estimator,
and the warm system prefix the app actually uses:

| | per chunk (median) | 24 chunks | e2e tok/s |
|---|---|---|---|
| gemma-4-e2b | 0.52 s | 12.3 s | 76.8 |
| Qwen3.5-4B-MTP, plain decode | 0.90 s | 21.4 s | 45.2 |
| Qwen3.5-4B-MTP, ×1.5 for MTP | ~0.60 s | ~14.3 s | — |

**So: ~1.75× on plain decode, ~1.16× against the MTP path the app really runs.** Output
quality on the sample is indistinguishable; both produce the same corrections. A 16% win does
not pay for a model swap that, per the provenance comment in `AIMode.swift`, obliges a full
re-run of the 100-case quality corpus, because prompt findings do not transfer between
models.

Three measurement traps, all of which produced confidently wrong numbers first:

- **Benchmark the warm prefix or benchmark nothing.** Charging a full ~930-token prefill per
  correction gave 3.22 s/chunk for Qwen and a 3.62× "win" for Gemma. The app prefills the
  ~881-token system prompt once and reuses it, so that measured a configuration no user has —
  and it happens to measure prefill speed, which is exactly the axis where the two models
  differ most (5.4×). With the warm prefix, Qwen's 0.90 s lines up with the app's own ~0.77 s.
- **`generate_step` computes one token ahead.** Breaking after its first yield leaves a
  *sampled* token appended to the cache that was never in the prompt. Every later chunk then
  decodes against a prefix one token off; Gemma responded with a line lifted out of the
  prompt's own examples for all 24 inputs. Prefill a cache with a plain `model(ids, cache=)`
  forward pass instead.
- **Both models emit chain-of-thought unless `enable_thinking: false` is passed** — which
  `LLMPostProcessor` does. Without it the reasoning eats the whole 256-token budget and the
  timing measures the cap, not the task.

Cloning a warm cache in Python needs `type(c).from_state(deep_copied_state, c.meta_state)`;
state alone is not enough. `RotatingKVCache` (Gemma's sliding-window layers) is a ring buffer
whose contents are meaningless without the `offset`/`_idx` in `meta_state`. Gemma's warm and
cold outputs then still diverge by roughly one word in 200 — the ring buffer holds the same
window in a different rotation, so the arithmetic differs slightly. Qwen's warm output is
byte-identical to cold.

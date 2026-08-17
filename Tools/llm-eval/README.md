# `Tools/llm-eval` — the LLM-polish evaluation harness

`docs/knowledge/llm/rules.md` closes with *"Never edit `AIMode.correct.prompt` and eyeball
the result."* Measurement is blocking, and the harness that produced the documented
numbers is not in the tree — only its results survive, in `docs/knowledge/llm/`. This is a
rebuild of the scorer from those written rules, run against the app's own history database.

**Read "What this cannot establish" before quoting any number from it.** The 112-case gold
corpus behind the `+0.478` baseline is gone, and no join over the surviving data
reconstructs it.

```bash
python3 Tools/llm-eval/selftest.py                  # scorer behaviour, synthetic cases
python3 Tools/llm-eval/build_corpus.py              # → corpus.json
python3 Tools/llm-eval/score.py                     # → results-A_shipped_correct.json + raw/
python3 Tools/llm-eval/report.py                    # the per-language table
```

---

## 1. Which database

`common.DB_CANDIDATES` mirrors `HistoryTestLoader.findDatabase()` exactly, **sandbox path
first**. This ordering is load-bearing and it is the first thing this harness found:

| database | rows | rows with `ZAIENHANCEDTEXT` | ids shared with `golden-set.json` |
|---|---:|---:|---:|
| `~/Library/Application Support/Whisperer/history.sqlite` (non-sandbox) | 590 | 44 | **0 of 400** |
| `~/Library/Containers/com.ivy.whisperer/…/history.sqlite` (**sandbox**) | 2825 | 804 | **400 of 400** |

`golden-set.json` was built from the sandboxed database — its `audioPath` values all sit
under `~/Library/Containers/com.ivy.whisperer/Data/`. The non-sandboxed database is a
different, smaller store from a different build configuration, and joining it to the golden
set yields the empty set. All numbers below come from the sandboxed database.

## 2. The corpus

`build_corpus.py` runs the same SQL as `HistoryTestLoader.query` — `hex(ZID)`,
`ZISINPROGRESS = 0`, `length(ZTRANSCRIPTION) > 20`, `ZTARGETAPPNAME != 'File Import'` — and
joins each row to `golden-set.json` on the uppercased id, matching `GoldenSet.load()`'s
`Dictionary(uniqueKeysWithValues: file.entries.map { ($0.id.uppercased(), $0) })`.

Each kept case is a triple:

| field | source | what it is |
|---|---|---|
| `input` | `ZTRANSCRIPTION` | raw whisper output — what the LLM was actually given |
| `outputs.A_shipped_correct.text` | `ZAIENHANCEDTEXT` | what the shipped Correct prompt returned in production |
| `gold` | `goldenTranscript` | a full-file whisper decode of the same audio |

`outputs` is a dict keyed by arm so a re-run of any prompt or model drops in without a
schema change — rule 11, *decode greedily and save every output*, is only worth obeying if
re-scoring is free.

### Attrition, and why each row was dropped

Every drop is recorded in `corpus.json` under `dropped`, with a reason.

| dropped | reason |
|---:|---|
| 1857 | `no-ai-output` — `ZAIENHANCEDTEXT` NULL or empty; no LLM ran |
| 350 | `wrong-ai-mode` — `ZAIMODENAME` is `Custom` (311), `Rewrite` (47) or `Translate` (5), not `Correct` |
| 340 | `no-golden-entry` — recording absent from the 400-entry golden set |
| 7 | `gold-script-mismatch` — the golden decode is in a different script from the input |
| **92** | **kept** |

Note the 7 `gold-script-mismatch` drops. `golden-set.json` is decoded with `-l auto`, and a
handful of entries are whisper language-detection failures — one English recording decodes
as Bulgarian (`В основном, хотим да видим…`). A gold in the wrong language is not a
correction target for any output, and left in it would have registered as language drift
against a correct answer.

There are also **0** `output-identical-to-input` drops among the Correct rows that reached
that check, which matters for gate 3 below.

### True composition, with n

| | en | he | ru | total |
|---|---:|---:|---:|---:|
| **all** | **89** | **2** | **1** | **92** |
| train | 41 | 2 | 0 | 43 |
| holdout | 48 | 0 | 1 | 49 |
| recovery cases | | | | 79 |
| preservation cases | | | | 13 |

Language is resolved **from the transcript's script**, not from `ZLANGUAGE`. `ZLANGUAGE` is
the router's decision and it does not describe the text: across all 441 Correct-mode paired
rows it declares 270 en / 151 he / 20 ru, while the actual scripts are 421 en / 10 he /
10 ru. Trusting the field would have produced a 42-case "Hebrew" column containing English.

The split is `sha1(id)`-hashed at the documented 48/112 = 0.4286 train fraction, so it is
stable across regeneration: adding a recording never moves an existing case across the
boundary.

## 3. Scoring — what each rule says, and how it is implemented

Quotations are from `docs/knowledge/llm/rules.md` and `criteria.md`.

### Recovery toward gold

> *"Score recovery toward gold, not similarity to gold. Raw transcripts already resemble
> their corrections, so similarity ranks a do-nothing prompt first."* (rule 7)
>
> `recovery = (sim(out,gold) − sim(in,gold)) / (1 − sim(in,gold))` (criteria.md §2)

Implemented verbatim in `score.score_case`. 0 = no-op, 1 = reached gold, negative = moved
away.

### Preservation

> *"Preservation for the 10 already-clean inputs: `sim(out,gold)`, headroom 0.02."*
> (criteria.md §2)

A case with `sim(in, gold) ≥ 0.98` is tagged `kind: preservation` at build time and scored
as `sim(out, gold)` rather than recovery — there is no headroom to recover.

### Headline

> *"Weight languages equally in the headline (mean of per-language means). A raw mean lets
> English hide a catastrophic non-Latin score — it hid −0.788 on Russian."* (rule 8)

`aggregate()` computes the mean over the per-language means of the languages actually
present, and reports `languagesInBalancedMean` so a mean over two languages is never read as
a mean over three. `rawMean` is printed beside it for contrast, never as the headline.

### Gates

> *"Gates cap the score at 0, they do not set it to 0. Otherwise a more-broken output can
> outrank a less-broken one. Language drift is the sole exception: flat −1.0, below the
> do-nothing floor."* (rule 9)

```python
if drifted:   score = -1.0            # flat
elif gates:   score = min(0.0, raw)   # cap, never set
else:         score = raw
```

The four hard gates, from criteria.md §3:

1. **Language drift** — on script **presence, not majority**. knowledge.md: *"the gold
   contains Cyrillic, so the output must contain Cyrillic."* A majority test flagged a
   correct Cyrillic answer to `"Запусти docker run --rm -it ubuntu bash."` as drift while
   passing a genuine translation, because the command dominates the character count. The
   implementation is `scripts_present(gold) ⊆ scripts_present(out)`, with a 3-character
   floor so a stray letter is not a script.
2. **Preamble / delimiter echo** — `[INPUT]` / `[/INPUT]` / `[OUTPUT]`, `Here is the
   corrected text:`-shaped openers, a `<think>` block, and a leaked ChatML special token
   (`<|im_start|>`). The last pattern was added because the corpus contains one: see §5.
3. **Timeout** — the `5s / 10s / 15s` ladder from `LLMPostProcessor.process()`. **Partly
   unmeasurable here.** `ZTRANSCRIPTIONENTITY` has no latency column, so the only
   observable form of the failure is its consequence — `process()` silently returns the
   *uncorrected* text on expiry, so `out == in`. `build_corpus.py` drops identical outputs
   (they are indistinguishable from a legitimate rule-4 no-op), which makes this gate
   **structurally 0 on arm A**. The `latencySec` field exists in the schema and a live re-run
   should populate it; until then, read `timeout: 0` as "not measured", not as "passed".
4. **Degeneration** — output/input length ratio outside `0.4 … 2.5`.

### Edit precision, recall, F0.5

Not in the old harness. `edit_ops(a, b)` takes `difflib` word-level opcodes anchored on the
source index, so an edit counts as the same edit only if it replaces the same source span
with the same words.

- `required = edit_ops(input, gold)` — what the text needed
- `made = edit_ops(input, output)` — what the model did
- `precision = |required ∩ made| / |made|`, `recall = |required ∩ made| / |required|`
- `F0.5 = 1.25·P·R / (0.25·P + R)`

β = 0.5 encodes the false-positive asymmetry that motivates the metric: criteria.md §1 calls
the job *"repair, not rewriting"*, and rule 4 makes the prompt's default *"change nothing"*.
An invented edit is worse than a missed one, so precision is weighted 4× recall.

### LLM invocation rate

The headline for the whole polish plan — the share of utterances reaching the generative
model at all, which starts near 100% for dictation and must trend to 0. Reported against
**two** denominators, because only one of them is a measurement:

- `overHistory` — every dictation row, AI mode on or off. This is user toggling behaviour,
  not routing logic. It is the pre-plan reference point.
- `overCorpus` — **1.000 by construction**. The corpus is *defined* as rows the LLM ran on
  and changed. Printed only so nobody reads it as a result.

### Similarity metric, and why character-level

`sim(a, b) = 1 − levenshtein(a, b) / max(len(a), len(b))` over NFC-normalised,
whitespace-collapsed text. Case and punctuation are **preserved**, because terminal
punctuation and capitalisation are two of the four error classes in criteria.md §1.

Character level rather than token level for three reasons specific to this corpus: the
dominant edit classes are punctuation, capitalisation and single-character morphology, which
a whitespace tokeniser either erases or inflates to a whole-token miss; Hebrew and Russian
are morphologically rich, so a token metric charges a whole token for a one-letter
inflection; and it is script-agnostic, which an English-tuned word tokeniser is not.

The same function computes both `sim(out,gold)` and `sim(in,gold)`. The recovery ratio is
only meaningful if its two terms are on one scale.

### `contentRecovery` — a secondary axis added by this harness

The same formula over case-folded, punctuation-stripped text. It exists because of the
defect described in §4: `gold` is a raw whisper decode, so its punctuation and casing are
model artefacts rather than a correction target. Folding both sides isolates word choices,
which is the one thing an ASR reference can legitimately adjudicate. Reported alongside the
headline, never instead of it.

---

## 4. What this **cannot** establish — read this before quoting a number

### The documented baseline does not reproduce, and cannot

| documented (knowledge.md, round 10) | reproducible here? |
|---|---|
| balanced `+0.478` | **no** |
| holdout(64) `+0.442` | **no** |
| en / he / ru `+0.472 / +0.457 / +0.506` | **no** |
| drift 0 | trivially yes, but on n = 92 with 3 non-English cases it means nothing |

Three independent reasons, any one of which is sufficient.

**(a) The 112-case corpus is gone.** criteria.md §2 defines it as *"43 real history
transcripts with authored corrections, 57 clean texts with injected ASR damage, 12
long-form"*. The 57 damaged texts were authored, never stored in any database, and are not
in the tree. At most the 43 history rows could be re-identified, and their *authored
corrections* — the actual gold — are equally absent. Nothing in the repository or the
databases reconstructs them.

**(b) `golden-set.json` is the wrong kind of gold, and the rules say so.** Its own header:
*"Full-file decodes by ggml-large-v3-turbo-q5_0 … Not human ground truth."* `GoldenSet.swift`
is explicit that *"where the model mishears a word it will mishear it here too,
identically"* — which is exactly the property that makes it a good ASR-regression reference
and a bad correction reference. It carries no filler deletion, no capitalisation repair, and
whisper's own punctuation rather than correct punctuation.

criteria.md §2 states the requirement this violates: *"Gold is authored, never the app's own
output."* The golden set is not `ZAIENHANCEDTEXT`, so it clears the letter of rule 6, but it
is still machine output rather than an authored correction, and it fails the same way.

The consequence is measurable, not theoretical. **Median headroom `1 − sim(in, gold)` is
0.038**, and 55 of the 92 cases have headroom under 0.05. The reference is within a few
characters of the input. Any legitimate correction — adding a terminal period, capitalising
a sentence, deleting an `um` — moves the output *away* from a reference that contains none of
those, and divides that movement by a denominator near zero. That is the mechanism behind
the large negative numbers in §5. They are a property of the reference, not a verdict on
`AIMode.correct.prompt`.

**(c) There is no multilingual corpus left.** The documented 47 en / 33 he / 32 ru is
balanced by design — criteria.md §1: *"It must do this in English, Hebrew and Russian, which
is the whole reason the corpus is balanced rather than the naturally English-heavy mix the
history database contains."* The joinable corpus is 89 en / 2 he / **1 ru**. rules.md rule 10
already rules this out: *"A ~20-case suite cannot validate a language-preservation claim …
Non-Latin cases need to be counted in the dozens before 'it preserves language' means
anything."* Three non-Latin cases is an order of magnitude short. The Hebrew and Russian
columns in §5 are printed with their n and must not be read as language scores.

Widening the join does not fix this. Dropping the golden-set requirement gives 441
Correct-mode paired rows (421 en / 10 he / 10 ru by script) — still nowhere near balanced,
and with no gold at all.

### What the harness **can** establish

1. **Gate behaviour on real production outputs.** Drift, echo and degeneration are computed
   from the output text alone and need no gold. On 92 real Correct-mode outputs: 0 drift,
   1 echo, 0 degeneration. The echo case is a genuine, previously unrecorded production
   failure (§5).
2. **Preservation.** `sim(out, gold)` on the 13 already-clean inputs needs only that the
   reference be a faithful decode, which it is. Measured **0.926**, against a documented
   `+1.000` and a criteria.md §4.3 requirement of *"Preservation stays at 1.000.
   Non-negotiable in practice."* This is the one comparison in §5 that is apples to apples,
   and it is below target.
3. **Edit precision and F0.5 as a *relative* instrument.** The absolute values are dragged
   down by the reference, but the same reference scores every arm, so two arms are
   comparable to each other.
4. **The invocation-rate denominator** — 789 of 2646 dictation rows reached the LLM over the
   life of this history.
5. **Scorer correctness**, via `selftest.py` (§6) rather than via baseline agreement.

### What has to happen for a real baseline to exist again

Author gold for the 92 joined cases — or better, re-author the balanced 47/33/32 corpus with
non-Latin cases deliberately over-sampled. Until then this harness measures gates,
preservation and arm-to-arm deltas, and its recovery column is a placeholder with a working
formula behind it.

---

## 5. Measured — arm A, the shipped Correct prompt, as it ran in production

Database: sandboxed `history.sqlite`. Arm A outputs are historical `ZAIENHANCEDTEXT`, so
these were produced by whichever model/prompt pair was live at the time each row was written
— **not necessarily the prompt currently in `AIMode.swift`**. History records no model
version, so the arm cannot be pinned to one. Treat it as "the production polish path over
this period", not as a measurement of the current prompt.

### ALL — n = 92

| lang | n | recovery | content | med. headroom | precision | recall | F0.5 | drift | gated |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| en | 89 | −1.155 | −3.103 | 0.038 | 0.190 | 0.310 | 0.192 | 0 | 0 |
| he | **2** | −0.105 | +0.000 | 0.208 | 0.000 | 0.000 | 0.000 | 0 | 0 |
| ru | **1** | −5.229 | −7.882 | 0.128 | 0.000 | 0.000 | 0.000 | 0 | 1 |
| **balanced** (mean of per-language means, rule 8) | | **−2.163** | −3.661 | | | | | | |
| raw mean over cases | | −1.176 | | | 0.183 | 0.300 | 0.186 | | |

Gates: `drift 0, echo 1, timeout 0 (not measured — see §3), degeneration 0`

### TRAIN — n = 43 · HOLDOUT — n = 49

| | n | balanced | en | he | ru | precision | F0.5 |
|---|---:|---:|---:|---:|---:|---:|---:|
| train | 43 | −0.793 | −1.482 (n=41) | −0.105 (n=2) | — (n=0) | 0.208 | 0.206 |
| holdout | 49 | −3.052 | −0.876 (n=48) | — (n=0) | −5.229 (n=1) | 0.161 | 0.168 |

The train/holdout gap here is **not** a generalisation signal. Each split contains a
different one of the two non-English languages, so the two balanced numbers average over
different language sets — `train` over {en, he}, `holdout` over {en, ru} — and the holdout
figure is half-determined by a single Russian case. The English column is the only
like-for-like comparison: −1.482 train vs −0.876 holdout, both meaningless in absolute terms
for the reasons in §4.

### Preservation — n = 13

**0.926** mean `sim(out, gold)`, against documented `+1.000` and a criteria.md §4.3
requirement that it *"stays at 1.000. Non-negotiable in practice."* This is the one figure
here that is measured the way the documentation measures it, and it is 0.074 short. Worth
following up on a live re-run before concluding anything — 13 cases, and the "already clean"
tag is itself derived from a machine reference.

### Invocation rate

| denominator | rate | |
|---|---:|---|
| `overHistory` | **0.298** | 789 of 2646 dictation rows reached the LLM |
| `overCorpus` | 1.000 | by construction; not a result |

### The one echo failure

The single Russian case (`holdout`) is a genuine production degeneration, and it is the most
useful thing in this table:

```
IN : おやすみなさい хорошая девочка отличница Такая Алена нам нужна Может подружиться…
OUT: おやすさいХшая,ница Такаялена Нам. подруиться вся вместе она покамтя.- уё тво…
     <|im_start|>
     INPUT
     やすさい девочканица А нам Можетж,кнуть, его уро
GOLD: Хорошая девочка, отличница. Такая Алена нам нужна. Может подружиться…
```

The output drops characters throughout, then reopens the chat scaffold with a raw
`<|im_start|>` token and re-emits a mangled copy of the input. It is the `[INPUT]…[/INPUT]`
echo of knowledge.md's round-10 section, one layer lower — the special token itself rather
than the prompt's text delimiters — and knowledge.md's claim that reformatting the examples
took echoes to **0** was measured on the 112-case corpus, not on this row.

Three caveats before anyone acts on it: the input is itself corrupt (it opens with Japanese),
n = 1, and the row's model/prompt version is unknown. It is a lead, not a regression.

Notably it does **not** trip the degeneration gate (length ratio 0.60, inside 0.4…2.5) and
does **not** trip the drift gate (Cyrillic survives). Only the echo pattern catches it —
which is rule 13 restated: *"A structural quality gate passes a degenerate output."*

---

## 6. `selftest.py` — how the scorer earns trust without the baseline

The documented numbers cannot validate this scorer, so 26 synthetic assertions with known answers
do instead. They pin exactly the behaviours the rules specify:

- recovery is 0 for a no-op, 1.0 at gold, negative for a paraphrase;
- a gate **caps** at 0 (a gated improvement scores 0.0, a gated regression keeps its negative
  score) — the concrete failure knowledge.md describes, two Hebrew junk outputs where the
  longer one tripped the length gate and collected a *better* score, is asserted not to
  happen;
- drift is a flat −1.0 for both;
- the drift gate is presence-based: on `"Запусти docker run --rm -it ubuntu bash."` a correct
  Cyrillic answer passes and a real translation is caught — the exact pair a majority test
  got backwards;
- preservation is 1.000 untouched and below 1.000 when clean text is rewritten;
- F0.5 ranks P=0.8/R=0.2 above P=0.2/R=0.8;
- the balanced mean exposes a 90-en/10-ru collapse (−0.200) that the raw mean hides (+0.280);
- the split is deterministic and lands within 0.05 of the documented 48/112 fraction.

All pass.

---

## 7. The capability-tier column

`report.py` prints a two-row matrix, `full` and `none`. The `none` row re-runs every case
with `ASRCapabilities = []` — the Nemotron-equivalent score, and the engine-independence
metric for the plan.

**This harness does not compute it.** That arm is produced by the Swift side
(`WhispererTests/PolishBenchmarkTests.swift`, currently measuring 0 divergences), which is
the only place with access to the capability plumbing. The schema carries `capabilityTier`
on both the result object and each arm's output block, so a Swift-produced
`results-<arm>.json` written in the same shape drops into `report.py` and fills the row. The
row currently prints `— not run`.

## 8. Files

| file | |
|---|---|
| `common.py` | similarity, script detection, word diffs, deterministic split, DB discovery |
| `build_corpus.py` | history + golden-set → `corpus.json`, with every drop and its reason |
| `score.py` | recovery, gates, precision/F0.5, invocation rate → `results-<arm>.json` + `raw/<arm>/<id>.json` |
| `report.py` | the per-language table, n beside every figure |
| `selftest.py` | scorer behaviour on synthetic cases with known answers |

Generated artefacts (`corpus.json`, `results-*.json`, `raw/`) are reproducible from the two
scripts and the database; they are not source.

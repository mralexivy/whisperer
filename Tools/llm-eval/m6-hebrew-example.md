# M6 — replacing the Hebrew mishearing example in the Correct prompt

Status: **edited, NOT gated.** The measurement gate for this change (holdout does not drop,
Hebrew stays within ~0.15 of en/ru, drift 0) has **not been run**. See "Gate" at the bottom.

## Why `טורף → טוב` had to go

It appeared twice in `Whisperer/Transcription/LLM/AIMode.swift`: inside rule 7's inline list of
mishearings and as the fourth worked `before:`/`after:` pair.

`טורף` (*toref*, "predator / tearing") and `טוב` (*tov*, "good") share only the initial `ט`.
They are three syllables vs two, and differ in the vowel and in the whole coda. No ASR confuses
them acoustically. What the example actually demonstrated was: *a word that looks odd in context
may be swapped for whatever word makes sense there* — i.e. a semantic substitution. That is the
precise failure mode rule 7 is fenced against ("Only that one word changes. Unsure? Leave it.")
and the one Hebrew is most exposed to.

It is also not attested. The utterance family it was authored from is real — the history DB has
`אני רוצה לראות נראות עד כמה טוב זה יכול לעבוד במשפט מורכב…` — but the actual ASR error in that
recording is a **self-correction/duplication** (`לראות נראות`), not `טורף`. No decode of that
phrase in either data source ever produced `טורף`; `1192DDED` in the golden set decodes the same
phrase (`בואי נראה עד כמה טוב זה עובד`) correctly. The pair was invented.

## Data searched

| Source | What is in it | Yield |
|---|---|---|
| `~/Library/Application Support/Whisperer/history.sqlite` | 8 rows with `ZLANGUAGE LIKE 'he%'` total; **4** have a non-empty `ZAIENHANCEDTEXT` that differs from `ZTRANSCRIPTION` | thin, and the gold is the app's own output, which criteria.md §2 forbids using as a reference |
| `WhispererTests/TestData/golden-set.json` | 400 entries, 93 tagged `he` — but only **10** are actually Hebrew-script (the other 83 are English/Russian speech routed through the Hebrew model). Of those 10, 9 differ between `storedTranscript` (streaming) and `goldenTranscript` (whole-file decode) | the usable source |
| `Tools/llm-eval/corpus.json` (M0 corpus) | 92 cases, `he = 2` (`12CF2018`, `BA4FD46C`, both **train**) | used only to check that the chosen example is not an answer key |

Note on direction: `storedTranscript` and `goldenTranscript` are two decodes of the *same* audio,
neither is human ground truth (the file says so). A pair is only usable when one side is a
non-word or is impossible in context and the other is the obvious intended word — then the wrong
side is a real, in-domain mishearing regardless of which pass produced it.

The 4 history rows are reproduced here for completeness; none yielded a usable single-word pair:

1. `…איך אני מתכי אני מטה וכה` → `…איך אני מתכנן וכו'` — real, but a multi-word garble, not one word.
2. `אנחנו נסתכל…` → output wrapped in `[INPUT]…[/INPUT]` — no correction at all; this is the
   delimiter-echo failure mode from scoreboard note 2, observed in production. Corroborates
   keeping the bare `before:`/`after:` format.
3. `…זה לא רואה שזה יחלט לצער` → `…זה לא. רואים שזה יחלט לצער` — punctuation + verb form.
4. `די-בי-אמס, פיק פורט…` — a repetition-loop degenerate decode (`אז,` ×90).

## Candidates

### 1. `הטקס → הטקסט` — **chosen**

- **Recording**: golden-set entry `93825790` (14.6 s, he).
- **What the ASR said**: `goldenTranscript` — `בואו אני אדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקס שלנו…`
- **What was meant**: `הטקסט`. The streaming pass on the same audio got it right
  (`storedTranscript`: `…מציגה את הטקסט שלנו…`), so both the error and its correction come from
  the same 14.6 s of real speech.
- **Acoustics**: *ha-tékes* vs *ha-tekst* — identical up to the elided final `ט`/t. Dropping a
  final unreleased stop is one of the most common Hebrew ASR errors there is.
- **Semantics**: `טקס` = "ceremony". "the software displays our ceremony" is impossible in
  context; `טקסט` = "text" is the only reading. Exactly the shape rule 7 describes: *a word that
  cannot mean anything where it stands*.
- **Answer-key check**: `93825790` is **not in the M0 corpus at all** — it is in
  `corpus.json.dropped` with reason `no-ai-output`. It is neither train nor holdout, so it cannot
  inflate either number. This is a stronger position than the pair it replaces (`he_s10`, a train
  case).
- One word, one change, short, and the carrier sentence is the same recording's own words.

### 2. `המחודה → המכונה`

- **Recording**: golden-set entry `7BB79BFD` (23.8 s, he).
- `storedTranscript`: `…אני כאילו לקהלי רץ בתוך המחודה עם privacy מלא…`
  `goldenTranscript`: `…אני כאילו לקל לרץ בתוך המכונה עם פרייבסי מלא…`
- `המחודה` (*ha-mchuda*) is not a Hebrew word; `המכונה` (*ha-mechona*, "the machine") is, and
  "runs inside the machine, fully private" is the obvious meaning.
- **Acoustics**: good — *m-ch-u-da* vs *m-ch-o-na*, same onset, same syllable count.
- **Rejected because**: the surrounding clause is itself badly damaged on both sides
  (`יוצא לאינטרס` / `אצל`, `לקהלי רץ` / `לקל לרץ`), so any short quotation of it either drags in a
  second unfixed error or has to be stitched from words the recording never said in that order.
  An example whose "after" line still contains a visible error teaches the model to leave errors.
- `7BB79BFD` is also dropped from the M0 corpus (`wrong-ai-mode`), so provenance would have been
  fine — the carrier was the problem.

### 3. `ה-9 → הצ'אנל`

- **Recording**: golden-set entry `12CF2018` (14.8 s, he) — the only real Hebrew **question** in
  the corpus, which is why it was considered.
- `storedTranscript`: `…בסוף אופנסלט אחראים על ה-9 אז כן…` vs `goldenTranscript`: `…על הצ'אנל…`
- **Rejected because**: *ha-tésha* ("the 9") and *ha-tshanel* are not close enough to call an
  acoustic confusion, and `12CF2018` is a **train** case in the M0 corpus, so quoting it puts a
  scored case's answer in the prompt. The other diffs in that entry
  (`אינטגרישנס → אינטגרישן`, `אופנסלט → אופנסלית`) are transliteration/plural noise where the
  "wrong" side is arguably right.

Also considered and rejected as not-mishearings: `בואי → בוא` (gender agreement, `9994F189`),
`הבין → יבין` (tense, `BA4FD46C`), `נראה → אני אראה` (`810BC66C`, the golden side is the worse
one).

## The edit — both sites

Site 1, rule 7's inline list:

```diff
-7. … the word actually meant (Plower → planner, rounds → routes, טורף → טוב). Only that one word changes. Unsure? Leave it.
+7. … the word actually meant (Plower → planner, rounds → routes, הטקס → הטקסט). Only that one word changes. Unsure? Leave it.
```

Site 2, the fourth worked pair:

```diff
-before: בוא ננסה לדבר בעברית, אני רוצה לראות עד כמה טורף זה יכול לעבוד?
-after: בוא ננסה לדבר בעברית, אני רוצה לראות עד כמה טוב זה יכול לעבוד?
+before: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקס שלנו
+after: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקסט שלנו.
```

Unchanged: **7** examples, blank-line separated, bare `before:` / `after:` lines, no
`[INPUT]…[/INPUT]` shape (scoreboard note 2 — that form echoed on 3 Russian cases and scored
+0.455 vs +0.478). Before-line length is 66 → 62 characters, so the example block does not grow.

The carrier is `93825790`'s own words (its `storedTranscript` prefix, truncated at `שלנו`), with
`הטקסט` swapped for the attested `הטקס` on the before line.

### One property was lost, deliberately

The old pair ended in `?` and was the only example showing that a final question mark survives
and is not turned into a period (rule 1 says so in prose, but no other example demonstrates it).
The new pair demonstrates rule 1's other half instead — a missing terminal period is added. It
could not demonstrate both: there is no real Hebrew question in either data source that also
contains a real single-word mishearing. Note that the old pair's `?` was itself authored — the
underlying utterance is not a question either. **Hebrew questions are the thing to watch in the
re-run.**

Also updated: the scoreboard comment at the top of `AIMode.swift` — note 3's case list no longer
names `he_s10`, and a new `UNMEASURED CHANGE (M6)` block records the swap, the evidence, and the
pending gate.

### Out-of-scope duplicate

`docs/knowledge/llm/criteria.md` §1 lists `טורף → טוב` in its error-class table as *the* Hebrew
ASR-mishearing example. That file is not owned by this milestone's edit and was left alone; it
needs the same one-line correction once the gate passes.

## Gate — PENDING, not passed

This change is **unmeasured**. The M0 harness is being built in parallel and the 4B model run is
not this agent's to make; no build was run either (`xcodebuild` is out of bounds here). The
change was verified by reading only: both sites replaced, example count 7, `"""` delimiters
balanced (22 in the file = 11 prompts × 2), no `\(` interpolation and no backslash escapes
anywhere in the file, `{transcript}` still present in every prompt, and no Unicode bidi control
characters (LRM/RLM/LRE/RLO/FSI…) introduced by the RTL text.

When the harness is available, the change ships only if all three hold:

1. balanced **holdout** does not drop below the pre-change number,
2. Hebrew stays within ~0.15 of English and Russian,
3. language drift is **0**.

If it fails, the plan's instruction is explicit: **delete the pair from both sites** rather than
restore `טורף → טוב` or ship another authored example. Deleting one of seven examples is expected
to cost a fraction of the 0.11 balanced / 0.14 holdout that removing all seven costs.

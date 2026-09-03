# Dictionary — knowledge

Facts and confirmed patterns for the correction dictionary and the cross-session learner.

## What a learner should actually store

**Wispr Flow's learner stores vocabulary, not rewrite rules.** Read-only inspection of
`~/Library/Application Support/Wispr Flow/flow.sqlite` (1,779 dictations, 18 `Dictionary` rows):
all 9 auto-learned rows have `observedSource` populated (the mishearing) and `replacement`
**empty**. The rows with a non-empty `replacement` are all `manualEntry = 1` — snippets the user
authored (`btw → by the way`). The learned artifact is a term, not a substitution.

Whisperer applies its learned terms through the existing text-level `CorrectionEngine` instead,
because decoder-side biasing is a closed road here: a richer `initial_prompt` cost +0.0142 WER and
still leaked (`3e343fc`).

## The three promotion gates, and why each exists

A mined pair auto-applies only if all three hold. Each was added because a real pair got through
without it.

1. **Observed form ≥ 4 characters.** Not redundant with gate 2:
   `SpellValidator.isValidEnglishWord` returns `false` for words under 4 characters *without
   consulting NSSpellChecker*, so gate 2 is vacuous below 4. Without this, `fan → FN`
   (soundex F500 = F500) and `SI → CI` auto-promote.
2. **Observed form is not valid English.** Blocks the user rewriting a thought — `the → our`,
   `size → image`, `sink → cost`.
3. **The pair is phonetically equal (soundex).** Blocks `backend → firebase` (B253 ≠ F612),
   `teams → Antti`, `KVEN → QwEN`, `YouTube → YT`.

Everything that fails a gate but is well-formed becomes a **suggestion**, not a discard.

## Measured behaviour

Replaying every `pastedText != editedText` row in the local Wispr corpus through the shipped
extractor and the shipped gates (`CorrectionLearnerReplayTests`):

| | |
|---|---|
| real edit pairs | 410 |
| auto-promotions | 3 (`glyn → Glean`, `orcid → Orkit`, `in-stream → instream`) |
| promotion rate | 0.7% |
| false auto-promotions | **0** |

Per benchmarking rule 13 this does not certify a precision percentage at this n; the bar it
enforces is zero false auto-promotions reported with its n, plus a rate guard at 2%.

Against the golden corpus, the learned entries repair 4 transcripts (whisper wrote `Glyn` where
the speaker said `Glean`) and touch no word they were not taught. **Byte-for-byte identity was the
wrong bar for that metric** — an unchanged reference corpus would have meant the feature does
nothing, because the reference contains the very mishearing the learner exists to repair.

## The two automatic sources

| Source | Build | What it knows |
|---|---|---|
| History edit | all | inference — you changed a word in a transcript, we guess why |
| Post-paste AX observer | `#if !APP_STORE` | inference, plus a focus/field-identity boundary |

The correction card ("Got a word wrong?") was removed 2026-09-03. It appeared unconditionally after
every dictation, whether or not anything was wrong. The Wispr Flow teardown (`competitor.md §12`)
confirmed the right design is fully silent: the observer watches the field for 60 s, mines any
isolated 1:1 word substitution once the region is stable across two polls, and fires the
"Learned: X — heard as Y" toast *only when something was actually learned*. The only visible
artifact of auto-learning is that toast with its Undo button and the Dictionary tab slowly filling.

For App Store builds (no AX) the only automatic source is `historyEdit`; borderline pairs surface in
the Dictionary tab review list. Hand-authored entries can always be added from there.

Implementation notes carried forward:
  silently eats keystrokes is the worst failure available to a feature whose whole job is to
  capture a typed word.

## The 3-distinct-session gate is inert

Across 1,779 dictations, **zero** candidate pairs recur even twice. A gate requiring 3 sightings
would never fire. Promotion is single-sighting by necessity, which is why provenance, the toast,
and tombstones carry the safety instead.

## Provenance is the discriminator

`CorrectionEngine.applyCorrections` reads
`(!entry.isBuiltIn && !entry.isAutoLearned) || !isValidEnglishAlias(word)` — before
`observedSource` existed, this was `!entry.isBuiltIn || ...`, meaning **any user-created entry
always fires**. An auto-learned `backend → firebase` would have rewritten all 87 dictations
containing "backend".

Auto-learned entries are also **excluded from the SymSpell and PhoneticMatcher indexes**: a pair
promoted from one observed mishearing is only trustworthy for that exact string. Feeding
`glyn → Glean` to the fuzzy indexes also pulls in `glynn`, `glyns` and every soundex neighbour.
Confirming an entry clears `observedSource`, which is what admits it to those indexes.

## Tombstones key on the observed form alone

Not on the pair. Rejecting `glyn → Glean` must also block `glyn → Gleen`, or the learner re-offers
a trivially different version of what the user just rejected.

## Wispr's dictionary schema, for reference

`Dictionary(id, phrase, replacement, teamDictionaryId, lastUsed, frequencyUsed,
remoteFrequencyUsed, manualEntry, createdAt, modifiedAt, isDeleted, source, isSnippet,
observedSource, isStarred, replacementHtml)`. Edit pairs live in `History(pastedText, editedText)`.
Open it `file:...?immutable=1` with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` — never disturb a
running install.

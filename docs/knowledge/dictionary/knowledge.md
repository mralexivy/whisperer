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

## The three sources, and what the explicit one is for

| Source | Build | What it knows |
|---|---|---|
| History edit | all | inference — you changed a word, we guess why |
| Post-paste AX observer | `#if !APP_STORE` | inference, plus a focus/field-identity boundary |
| Correction card (HUD) | all | **statement** — you clicked the word and typed the fix |

The card is the only source that works in the App Store build *and* carries unambiguous intent.
It still commits through `CorrectionLearningService.observe`, so the gates cannot be bypassed by
being explicit — but a pair the gates refuse is offered as a one-click **"Always fix"** rather than
being demoted to a review list. Accepting that offer writes a **hand-authored** entry
(`observedSource == nil`), not an auto-learned one: the user authored it, so it takes the
hand-authored trust level and joins the fuzzy indexes immediately.

The card's behaviour is asserted rather than eyeballed — 11 tests over the tokenizer and commit
path (`CorrectionPopoverTests`), the panel's focus contract (`CorrectionCardFocusTests`), its
lifetime and dismissal (`CorrectionPromptLifecycleTests`) and its two outcomes
(`CorrectionCardOutcomeTests`). The lifetime tests exist because "a stale card fought the recording
HUD" is exactly the kind of defect nobody catches reliably by looking.

Implementation facts worth keeping:

- **Replace the clicked token by index, never by string.** "the report says the report is late"
  with a string replace changes both, which the miner reads as a two-substitution diff and
  discards — the user's correction vanishes with no error anywhere.
- **The chips must use the extractor's own word pattern.** A chip the miner cannot learn from is a
  chip that should never have been clickable.
- **A `[.borderless, .nonactivatingPanel]` window does take keystrokes — measured, not assumed.**
  With `canBecomeKey = true` / `canBecomeMain = false`, `makeKeyAndOrderFront` makes the panel key,
  `makeFirstResponder(field)` installs the field editor as first responder, `NSEvent.keyEvent`s
  dispatched through `sendEvent` land in `stringValue`, and the panel never becomes main — so the
  app is not activated and the user is not pulled out of whatever they were dictating into
  (`CorrectionCardFocusTests`, 4 assertions). This is why the editor is an AppKit `NSTextField`
  rather than a SwiftUI `TextField`: the *window* is fine, SwiftUI's focus plumbing in a borderless
  panel is the soft spot. `NSApp.activate` is never an option here. The card still re-checks
  `isKeyWindow` one runloop later and closes itself with a logged warning, because a field that
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

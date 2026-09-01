# Dictionary — rules

Confirmed. Apply by default.

1. **Never auto-promote a learned correction without all three gates.** Length ≥ 4, observed form
   not valid English, pair phonetically equal. Dropping any one of them admits a destructive pair
   that was observed in the real corpus. See [knowledge](knowledge.md).

2. **An entry the user did not author must carry `observedSource`, and provenance must gate
   behaviour, not just decorate the row.** Auto-learned entries are exact-match only and never
   rewrite a valid English word; confirming clears provenance and admits the entry to the fuzzy
   indexes.

3. **Every automatic change to the dictionary is announced and undoable in the same moment.**
   Silent learning is indistinguishable from a bug the first time it surprises the user. Undo
   must tombstone, not just delete.

4. **Tombstone on the observed form, never on the pair.**

5. **A bulk import never enters the dictionary directly.** Imported pairs land in the suggestion
   list even when they would clear the automatic gates: a bulk import is not a correction the
   user just made, so it has not earned a live correction's trust.

6. **Do not measure a learner by asserting the reference corpus is unchanged.** If the corpus
   contains the errors the learner exists to fix, an unchanged corpus proves the feature is
   inert. Assert *no collateral*: every changed token must be one the learner was taught.

7. **Explicit intent buys a different offer, never a weaker gate.** Every source commits through
   `CorrectionLearningService.observe`. When the gates refuse a pair the user stated outright, the
   answer is a one-click confirmation that writes a *hand-authored* entry — not a bypass, and not
   a silent demotion to a list nobody opens.

8. **A learning affordance the user has to remember to open is a learning affordance nobody
   uses.** The correction card is offered unasked for ~7 s after each dictation, extends itself
   while hovered or being typed into, and disappears the moment the next recording starts.

9. **AX polling after a paste must be front-loaded and bounded, and must abandon on focus
   change.** Each poll is a synchronous main-actor AX round-trip with a 100 ms messaging timeout;
   a flat 500 ms × 60 s schedule is 120 of them, up to 12 s of potential main-thread stall.
   The shipped schedule is 400 ms × 15 then 2 s × 12.

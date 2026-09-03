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

7. **Correction learning must not add any latency to text insertion.** The pre-paste AX snapshot
   was removed 2026-09-03: the observer now builds its anchor from the first post-paste read (400 ms
   after paste), so `insertText` does zero AX work before the clipboard paste. Verified by
   inspection: no AX call appears between `enterViaClipboardPaste` and `return` in `insertText`.

8. **AX polling after a paste must be front-loaded and bounded, and must abandon on focus change,
   divergence, and after a correction is mined.** Schedule: 400 ms × 15 (6 s), 2 s × 12 (24 s),
   5 s × 6 (30 s) = 33 reads at most over 60 s. Each poll is 50 ms AX timeout (polls, not a
   blocking dependency). Early exit: frontmost-PID check before every AX call, divergence bail-out
   at 35%, and immediate exit once a correction is mined and stable. The budget is asserted in
   `CorrectionObservationScheduleBudgetTests`.

9. **Insertion verification is anchoring.** The first post-paste AX read locates `pastedText` as a
   unique substring of the field. Zero occurrences means the paste silently failed (end-reason
   `notVerified`); two or more means attribution is ambiguous (`ambiguousAnchor`). Both bail with
   nothing learned. This is exactly what Wispr calls "insertion verification" (`competitor.md:1436`).

10. **End reasons are logged for threshold tuning.** Every observation exit logs
    `Logger.event(.dictLearn, .textInjection, [endReason:, polls:, learned:])`. The `0.35`
    divergence threshold is a **hypothesis** — tune it against real `endReason=editDistanceExceeded`
    frequency in the logs before treating it as a rule.

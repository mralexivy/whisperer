# W2 — Correction learning

Status: active, collection arm only. Automatic promotion is not authorised by this plan.

## Claim under test

A user edit made inside the exact region Whisperer pasted can provide useful dictionary
candidates without changing output, monitoring keys, or reading unrelated text.

The competitive teardown is evidence that another product attempts this. It is not evidence that
the same policy is safe in Whisperer: several observed Wispr entries (`backend` → `firebase`,
`teams` → `Antti`) would be destructive as unconditional global rewrite rules.

## Arm boundary

- Control: current shipping path, byte-for-byte.
- Candidate arm: off by default. With explicit opt-in and Accessibility permission, snapshot the
  focused field immediately before paste, poll that same field for at most 60 seconds, and retain
  an edited region only while the text outside the original selection remains byte-identical.
- Extract only isolated one-token substitutions. Ignore punctuation-only, case-only, script-changing,
  insertion, deletion, multi-token, and more-than-four-candidate edits.
- Refuse regions above 12,000 characters or 1,000 tokens so the LCS diff has a fixed memory/time
  ceiling.
- Persist provenance and distinct-session evidence. Do not add a `DictionaryEntry` and do not alter
  transcription, prompt vocabulary, CTC boosting, or correction output.
- No keyboard monitor, event tap, OCR, screen scrape, or network call.

## Pre-registered verdict

Collection may remain behind its off-by-default toggle only if:

1. Both app configurations build and the extraction/anchoring/store tests pass.
2. The control path does not start an observer and remains byte-identical.
3. No candidate is produced when either outside anchor changes, the edit is not an isolated
   one-token substitution, case alone changes, script changes, or the field cannot be read.
4. Repeated polls in one dictation count as one piece of evidence; three different dictations are
   required before a candidate is merely marked `eligibleForReview`.
5. `CorrectionNegativeCorpusTests` remains green. Candidate collection is not allowed to change
   that suite's output because promotion is absent.

A later promotion arm requires an authored positive corpus containing real audio/text corrections.
Its fixed bar is precision >= 0.99 for every auto-applied class, zero changes across
`CorrectionNegativeCorpusTests`, zero protected-token changes, and better > worse on authored gold.
A tie is not a win. Failure means promotion is deleted; collection may remain only as a review queue.

## Current verification

The extractor, anchor, persistent distinct-session evidence counter, third-session review marker,
reload, size ceiling, and user deletion path compile and pass in a standalone production-source
smoke harness. Both ordinary and `APP_STORE` source paths parse, and `git diff --check` is clean.
The control path remains the existing paste path because collection defaults off and its observer is
cancelled at the start of every subsequent paste.

The full Xcode attempt first hit SwiftPM's nested manifest sandbox. After temporarily disabling that
Xcode manifest sandbox, package resolution completed and the build advanced until the pre-existing
MLX dependency tried to compile `.metal` sources; this host has no Xcode Metal Toolchain installed
(`cannot execute tool 'metal'`). The temporary Xcode preference was restored immediately. Therefore
the collection arm remains active/off-by-default rather than being described as shipped. Automatic
promotion remains absent regardless of that infrastructure blocker.

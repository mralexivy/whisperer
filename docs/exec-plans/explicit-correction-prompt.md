# W1 retry — explicit-correction prompt

**Status:** BLOCKED / UNMEASURED (2026-09-01). No runtime code, setting, or benchmark harness is
landed. The previously rejected history-mining arm remains reverted.

## Why this is a different premise

The failed W1 arm inferred vocabulary from transcription history and destination-app context. This
retry may use only an explicit correction the user deliberately created. Built-in dictionary packs,
history frequency, app names, screen text, W2 collection-only candidates, and anything marked
`Learned` / `Auto Learned` are ineligible. A canonical spelling may enter `initial_prompt` only after
an unprompted hypothesis for the current recording contains the correction's alias or passes a
strict phonetic-neighbour test. The prompt is capped at six terms / 96 characters.

This prompt may be used only by committed VAD/tail decoding. It must not be added to the short live
preview path: the existing `StreamingTranscriber` carve-out that withholds vocabulary prompt words
from ambiguous preview windows is a measured safety boundary, not an implementation detail.

## Pre-registered population

Before implementation, author gold transcripts by listening to real recordings selected because an
eligible explicit correction is actually spoken. The set must contain at least 20 positive
recordings across at least five distinct corrections, plus 40 negative-control recordings where no
eligible term is spoken. Selection, gold, and the correction snapshot are frozen before either arm
is decoded. Same-model stored transcripts and AI-enhanced history text are not gold.

The current local database has **zero** non-built-in dictionary entries, so no recording can be tied
to explicit correction evidence. Proper nouns in history (`MCP`, `Parakeet`, `Linkerd`, and others)
do not repair that provenance gap. Inventing aliases or treating the stored decode as the reference
would repeat the exact benchmark error called out in transcription rule 1.

## Fixed A/B verdict

Decode every frozen recording through the real `StreamingTranscriber`. Arm A is current production;
arm B differs only by the evidenced explicit-correction prompt. Alternate A/B and B/A ordering by
fixture, and report positive and negative populations separately. **Every** bar must clear:

| Metric | Bar |
|---|---:|
| Mean WER delta, B − A, against authored gold | ≤ +0.005 |
| Prompt leakage on negative controls | 0 |
| Positive target recovery | recordings better > recordings worse |
| Decode p50 delta | ≤ +5% |

A tie is the floor, not a win. Any leakage is a rejection. If the population minimum is not met,
the result is UNMEASURED and no runtime arm lands. One independently diagnosed implementation bug
may receive one bounded fix and an unchanged rerun; further tuning on the frozen set is prohibited.

## Unblock condition

W2 must first produce user-reviewed/promoted dictionary corrections and real subsequent recordings
containing those terms. Once the minimum population exists, add the two fields needed by the bench
(`targetAppName` in `RecordingFixture` and its SQLite select), freeze authored gold, implement the
minimal arm behind an off-by-default rollback flag, and run the verdict above. Delete the arm again
unless all four bars clear.

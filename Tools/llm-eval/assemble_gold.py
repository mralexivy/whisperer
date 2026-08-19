#!/usr/bin/env python3
"""Assemble the authored gold into two corpora, one per metric.

`check_authored_gold.py` applies one gate to every case and writes one corpus. That was the
wrong shape, and the numbers showed it: of 149 authored pairs, 21 survived, which is below the
n=20 reporting floor in two of three languages. Reading the failure histogram is what explains
why — 73 of the 128 drops were *headroom* failures, meaning the author changed almost nothing at
the character level. Almost all of those are cases where the raw transcript was already clean
prose and the only thing gold added was punctuation.

That is a fatal defect for one metric and the ideal reference for the other:

  recovery (rule 4)  — `(sim(out,gold) - sim(in,gold)) / (1 - sim(in,gold))`. The denominator is
                       the headroom. At headroom 0.005 the score is a ratio of two rounding
                       errors, so the gate is real and stays.

  boundary F1 (3b)   — counts sentence terminators in reference-word index space. A gold that
                       differs from its input by nothing except added periods carries a complete,
                       uncontaminated boundary annotation. Requiring char-level headroom here
                       would systematically discard the *cleanest* references and keep only the
                       ones where the author also rewrote words — the opposite of what the metric
                       wants.

So this script emits both, from the same authored material and the same checker, differing in
exactly which gates apply. Neither corpus is human truth and neither may be used for an absolute
claim; both are good enough to detect damage between two arms scored against the same reference,
which is all rules 3b and 4 ask.

Gates by corpus:

  gold-corpus.json              b_script, c_multiset, d_headroom, e_length   (recovery)
  gold-corpus-punctuation.json  b_script, c_multiset, e_length               (boundary F1)
                                + gold must contain at least one sentence terminator
                                + gold must not be byte-identical to its input

Both corpora additionally drop every id the independent semantic review flagged. Those are
violations a mechanical check cannot see — a negation flipped, profanity paraphrased away, a fact
added — and per the plan flagged cases are dropped, never repaired.
"""

import glob
import json
import os
import sys

import check_authored_gold as checker

HERE = os.path.dirname(os.path.abspath(__file__))
AUTHORING_DIR = os.path.join(HERE, "authoring")
ARTIFACTS_DIR = os.path.join(HERE, "artifacts")

RECOVERY_PATH = os.path.join(AUTHORING_DIR, "gold-corpus.json")
PUNCTUATION_PATH = os.path.join(AUTHORING_DIR, "gold-corpus-punctuation.json")

# The same set `SentenceStructure.terminators` holds on the Swift side. Kept as a literal rather
# than parsed out of the Swift source: a silent drift here would quietly shrink the corpus, and a
# literal that disagrees is at least visible in a diff.
TERMINATORS = set(".!?׃…")

MIN_N = 20  # the reporting floor; below it a language column is `unmeasured`, never a point estimate


def flagged_ids() -> set:
    """Ids the independent semantic reviewers rejected. Empty if no review has been run.

    Reviews arrive as shards — `gold_semantic_review.json` from round 1, then one file per
    reviewer per round. Globbing rather than naming one file means a new round's findings take
    effect by existing, instead of by someone remembering to merge them into a master file;
    a forgotten merge silently readmits every violation that round found.
    """
    rejected = set()
    for path in sorted(glob.glob(os.path.join(ARTIFACTS_DIR, "gold_semantic_review*.json"))):
        with open(path, encoding="utf-8") as handle:
            review = json.load(handle)
        found = {entry["id"] for entry in review.get("flagged", [])}
        rejected |= found
        print(f"semantic review {os.path.basename(path)}: {len(found)} flagged")
    return rejected


def build() -> int:
    # `load_pairs` returns (cases, id_set_errors); the id errors are the checker's own report and
    # are already written to artifacts/gold_check.json, so only the cases are needed here.
    loaded, _ = checker.load_pairs(AUTHORING_DIR)
    pairs = {case["id"]: case for case in loaded}
    rejected = flagged_ids()

    recovery, punctuation, dropped = [], [], []
    for case_id, pair in pairs.items():
        verdict = checker.check_pair(case_id, pair["input"], pair["gold"])
        failed = {failure["check"] for failure in verdict["failures"]}
        language = checker.script_of(pair["input"])
        row = {
            "id": case_id,
            "language": language,
            "batch": pair.get("batch"),
            "input": pair["input"],
            "gold": pair["gold"],
        }

        if case_id in rejected:
            dropped.append({**row, "reason": "semantic review"})
            continue

        if not failed:
            recovery.append(row)

        blocking = failed - {"d_headroom"}
        has_boundary = any(character in TERMINATORS for character in pair["gold"])
        if not blocking and has_boundary and pair["gold"].strip() != pair["input"].strip():
            punctuation.append(row)
        elif blocking:
            dropped.append({**row, "reason": ",".join(sorted(blocking))})

    write(RECOVERY_PATH, recovery, "recovery (rule 4)",
          "Gated on b_script, c_multiset, d_headroom, e_length. The headroom gate is what makes "
          "the recovery denominator meaningful and is not negotiable for this metric.")
    write(PUNCTUATION_PATH, punctuation, "sentence-boundary F1 (rule 3b)",
          "Gated on b_script, c_multiset, e_length — deliberately NOT on headroom, because a gold "
          "whose only difference from its input is punctuation is the ideal boundary reference "
          "rather than a defective one. Every case carries at least one terminator.")

    report(recovery, "gold-corpus.json (recovery)")
    report(punctuation, "gold-corpus-punctuation.json (boundary F1)")
    print(f"\ndropped: {len(dropped)}  ({len(rejected)} of them by semantic review)")
    report_scoreable(recovery)
    return 0


def report_scoreable(recovery: list) -> None:
    """How much of the recovery corpus `score.py --gold` can actually score.

    Recovery needs an arm output as well as a gold, and arm A's output is not synthesisable —
    it is `ZAIENHANCEDTEXT`, what the shipped 4B returned, and it exists only for the rows
    `corpus.json` holds. A gold for an id outside that set is silently skipped by `score.py`,
    which is how rule 4 came to be reported as "unmeasured" while a 21-case corpus sat on disk.
    Printing the intersection here makes that failure visible at build time rather than as a
    zero-case summary later.
    """
    corpus_path = os.path.join(HERE, "corpus.json")
    if not os.path.exists(corpus_path):
        return
    with open(corpus_path, encoding="utf-8") as handle:
        have_output = {case["id"] for case in json.load(handle)["cases"]}

    scoreable = [case for case in recovery if case["id"] in have_output]
    print(f"\nrule 4 scoreable (recovery gold ∩ ids with an arm-A output): {len(scoreable)}")
    for language, count in sorted(composition(scoreable).items()):
        status = "ok" if count >= MIN_N else f"BELOW n={MIN_N} — column unreportable"
        print(f"  {language}: {count:3d}  {status}")


def write(path: str, cases: list, purpose: str, gate_note: str) -> None:
    document = {
        "purpose": purpose,
        "gates": gate_note,
        "provenance": "LLM-authored from raw `storedTranscript` rows in the local recordings "
                      "history, verified by check_authored_gold.py and by an independent "
                      "semantic reviewer. This is not human truth. It is adequate for comparing "
                      "two arms against the same reference and for nothing else — no absolute "
                      "claim may be made from a figure computed on it.",
        "reportingFloor": MIN_N,
        "composition": composition(cases),
        "cases": cases,
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=2)


def composition(cases: list) -> dict:
    counts = {}
    for case in cases:
        counts[case["language"]] = counts.get(case["language"], 0) + 1
    return counts


def report(cases: list, label: str) -> None:
    print(f"\n{label}: {len(cases)} cases")
    for language, count in sorted(composition(cases).items()):
        status = "ok" if count >= MIN_N else f"BELOW n={MIN_N} — column unreportable"
        print(f"  {language}: {count:3d}  {status}")


if __name__ == "__main__":
    sys.exit(build())

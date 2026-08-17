#!/usr/bin/env python3
"""Rebuild the LLM-polish corpus from the app's own history database.

Extracts (input, arm-A output, gold) triples:

    input  = ZTRANSCRIPTION            (raw whisper output, what the LLM was given)
    output = ZAIENHANCEDTEXT           (what the shipped Correct prompt returned)
    gold   = golden-set.json goldenTranscript, joined on the recording id

The SQL mirrors `HistoryTestLoader.query` — same `hex(ZID)`, same `ZISINPROGRESS = 0`,
same `File Import` exclusion — so a case here is the same case a Swift test would see.

Read the README before trusting the numbers this feeds: the join is sound, but
`goldenTranscript` is an ASR reference, not an authored correction, and that limits
what recovery-toward-gold can mean here.

Usage:  python3 Tools/llm-eval/build_corpus.py [--out corpus.json] [--mode Correct]
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import (  # noqa: E402
    dominant_script,
    find_database,
    normalize,
    scripts_present,
    sim,
    split_bucket,
)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
GOLDEN_SET = os.path.join(REPO, "WhispererTests", "TestData", "golden-set.json")

# criteria.md §2: preservation cases are the already-clean inputs, "headroom 0.02".
PRESERVATION_HEADROOM = 0.02

SQL = """
    SELECT hex(ZID), ZDURATION, ZTRANSCRIPTION, ZWORDCOUNT, ZLANGUAGE,
           ZAUDIOFILEURL, ZAIENHANCEDTEXT, ZAIMODENAME, ZTARGETAPPNAME
    FROM ZTRANSCRIPTIONENTITY
    WHERE ZISINPROGRESS = 0
      AND ZTRANSCRIPTION IS NOT NULL
      AND length(ZTRANSCRIPTION) > 20
      AND (ZTARGETAPPNAME IS NULL OR ZTARGETAPPNAME != 'File Import')
"""


def load_golden() -> dict[str, dict]:
    with open(GOLDEN_SET, encoding="utf-8") as handle:
        payload = json.load(handle)
    # GoldenSet.load() keys on id.uppercased(); hex(ZID) is already uppercase but
    # uppercasing both sides keeps the join honest if either format ever changes.
    return {entry["id"].upper(): entry for entry in payload["entries"]}


def build(mode_filter: str | None) -> dict:
    db_path = find_database()
    golden = load_golden()

    connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = connection.execute(SQL).fetchall()
    connection.close()

    total_rows = len(rows)
    ai_rows = 0
    cases: list[dict] = []
    dropped: list[dict] = []

    def drop(case_id, reason, detail=""):
        dropped.append({"id": case_id, "reason": reason, "detail": detail})

    for (case_id, duration, transcript, word_count, language, audio, enhanced,
         mode, target_app) in rows:
        transcript = transcript or ""
        enhanced = enhanced or ""

        if not enhanced.strip():
            drop(case_id, "no-ai-output", "ZAIENHANCEDTEXT empty or NULL")
            continue
        ai_rows += 1

        if mode_filter and mode != mode_filter:
            drop(case_id, "wrong-ai-mode", f"ZAIMODENAME={mode!r}")
            continue

        if normalize(transcript) == normalize(enhanced):
            # A byte-identical pass is a real Correct-mode outcome (rule 4: the default
            # is to change nothing), but it is indistinguishable in history from a
            # timeout no-op, which `process()` returns silently as the original text.
            drop(case_id, "output-identical-to-input", "no-op or invisible timeout")
            continue

        entry = golden.get(case_id.upper())
        if entry is None:
            drop(case_id, "no-golden-entry", "id absent from golden-set.json")
            continue

        gold = entry["goldenTranscript"] or ""
        if len(normalize(gold)) < 20:
            drop(case_id, "gold-too-short", f"{len(normalize(gold))} chars")
            continue

        in_scripts = scripts_present(transcript)
        gold_scripts = scripts_present(gold)
        if in_scripts and gold_scripts and not (in_scripts & gold_scripts):
            # golden-set.json is decoded with `-l auto`; a handful of entries are
            # whisper language-detection failures (an English recording decoded as
            # Bulgarian). Such a gold cannot be a correction target for any output.
            drop(
                case_id,
                "gold-script-mismatch",
                f"input={sorted(in_scripts)} gold={sorted(gold_scripts)}",
            )
            continue

        sim_in_gold = sim(transcript, gold)
        cases.append(
            {
                "id": case_id,
                "language": dominant_script(transcript),
                "declaredLanguage": language,
                "durationSec": duration,
                "wordCount": word_count,
                "targetApp": target_app,
                "aiModeName": mode,
                "split": split_bucket(case_id),
                "kind": "preservation" if sim_in_gold >= 1.0 - PRESERVATION_HEADROOM else "recovery",
                "simInputGold": round(sim_in_gold, 6),
                "input": transcript,
                "gold": gold,
                "audioFile": audio,
                # Arm A is the shipped Correct prompt as it ran in production. Arm keys
                # are open-ended so a re-run of any prompt/model can be added without a
                # schema change (rule 11: save every raw output, re-score for free).
                "outputs": {
                    "A_shipped_correct": {
                        "text": enhanced,
                        "source": "ZAIENHANCEDTEXT (production, historical)",
                        "capabilityTier": "full",
                        "latencySec": None,
                    }
                },
            }
        )

    reasons = Counter(d["reason"] for d in dropped)
    return {
        "database": db_path,
        "goldenSet": GOLDEN_SET,
        "modeFilter": mode_filter,
        "provenance": {
            "rowsMatchingLoaderSQL": total_rows,
            "rowsWithAIOutput": ai_rows,
            "casesKept": len(cases),
            "dropReasons": dict(reasons),
        },
        "composition": {
            "byLanguage": dict(Counter(c["language"] for c in cases)),
            "bySplit": dict(Counter(c["split"] for c in cases)),
            "byKind": dict(Counter(c["kind"] for c in cases)),
            "byLanguageSplit": {
                f"{c}/{s}": n
                for (c, s), n in Counter((c["language"], c["split"]) for c in cases).items()
            },
        },
        "cases": cases,
        "dropped": dropped,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=os.path.join(HERE, "corpus.json"))
    parser.add_argument(
        "--mode",
        default="Correct",
        help="ZAIMODENAME to keep; pass '' to keep every AI mode",
    )
    args = parser.parse_args()

    corpus = build(args.mode or None)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(corpus, handle, ensure_ascii=False, indent=2)

    provenance = corpus["provenance"]
    print(f"database                  {corpus['database']}")
    print(f"rows matching loader SQL  {provenance['rowsMatchingLoaderSQL']}")
    print(f"rows with an AI output    {provenance['rowsWithAIOutput']}")
    print(f"cases kept                {provenance['casesKept']}")
    print("\ndropped:")
    for reason, count in sorted(provenance["dropReasons"].items(), key=lambda kv: -kv[1]):
        print(f"  {count:5d}  {reason}")
    print("\ncomposition:")
    for key, value in corpus["composition"].items():
        print(f"  {key}: {value}")
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()

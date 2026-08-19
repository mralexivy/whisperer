#!/usr/bin/env python3
"""Emit authoring batches over `corpus.json`'s own inputs — the inputs rule 4 can actually use.

Rounds 1 and 2 sampled from `history-golden.json`, which was right for rule 3b and wrong for
rule 4. Recovery is `(sim(out,gold) - sim(in,gold)) / (1 - sim(in,gold))`: it needs an **arm
output** as well as a gold. Arm A's output is not something this repo can synthesise — it is
`ZAIENHANCEDTEXT`, what the shipped Qwen3.5-4B actually returned when the user ran that
recording through Correct mode, and it exists only for the rows `corpus.json` holds. The
history pool is mostly rows that were never sent to the LLM, so the two id sets are almost
disjoint (5 of 92) and `score.py --gold` scores nothing.

Re-running the 4B over the history inputs would close the gap the other way, but it would be a
re-simulation rather than the shipped arm, and it would make rule 4 a measurement of today's
model against yesterday's reference. Authoring gold for the inputs whose genuine arm-A output
is already recorded is both cheaper and more faithful.

The ceiling this inherits is `corpus.json`'s composition — 89 en / 2 he / 1 ru. English clears
the n=20 reporting floor with room to spare; Hebrew and Russian cannot be measured for rule 4
at all and must be reported `unmeasured`, never as a point estimate off n=2.
"""

import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus.json")
OUT_DIR = os.path.join(HERE, "authoring")
PREFIX = "batch3"
BATCH_SIZE = 18


def script_of(text):
    hebrew = sum(1 for c in text if "֐" <= c <= "׿")
    cyrillic = sum(1 for c in text if "Ѐ" <= c <= "ӿ")
    latin = sum(1 for c in text if c.isascii() and c.isalpha())
    top = max(hebrew, cyrillic, latin)
    if top == 0:
        return "other"
    if top == hebrew:
        return "he"
    return "ru" if top == cyrillic else "en"


def main():
    with open(CORPUS, encoding="utf-8") as handle:
        cases = json.load(handle)["cases"]

    # Ids already authored in rounds 1/2 keep their existing gold — re-authoring a case is not a
    # second data point, and a second gold for one id would make the corpus ambiguous.
    authored = set()
    for path in glob.glob(os.path.join(OUT_DIR, "batch*.gold.json")):
        with open(path, encoding="utf-8") as handle:
            authored.update(row["id"] for row in json.load(handle))

    rows = [
        {"id": case["id"], "language": script_of(case["input"]),
         "durationSec": case.get("durationSec"), "input": case["input"]}
        for case in sorted(cases, key=lambda case: case["id"])
        if case["id"] not in authored
    ]

    manifest = []
    for start in range(0, len(rows), BATCH_SIZE):
        chunk = rows[start : start + BATCH_SIZE]
        name = f"{PREFIX}-mixed-{start // BATCH_SIZE:02d}.json"
        path = os.path.join(OUT_DIR, name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(chunk, handle, ensure_ascii=False, indent=1)
        manifest.append({"path": path, "count": len(chunk)})
        print(f"{path}  {len(chunk)} cases")

    with open(os.path.join(OUT_DIR, f"manifest-{PREFIX}.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=1)
    print("total:", sum(row["count"] for row in manifest))


if __name__ == "__main__":
    main()

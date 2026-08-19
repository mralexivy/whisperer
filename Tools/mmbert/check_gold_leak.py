#!/usr/bin/env python
"""
check_gold_leak.py -- fail loudly if the calibration holdout reached training.

Run AFTER build_corpus.py and BEFORE train.py. Exits non-zero on any hit, which
aborts the chain (`set -e`), because a chain that trains on its own calibration
set produces numbers that look like a pass and are not one.

Checks the holdout's input side AND its reconstructed reference side against
both the input side and the reconstructed reference side of every row of
train.jsonl / val.jsonl. `render_target` undoes the synthetic corruption, so a
holdout reference used as a corruption seed is caught even though no two
corrupted copies are byte-identical. Keys are `norm_key`: case-, punctuation-
and filler-insensitive, i.e. blind to exactly the differences a legitimate
(input, reference) pair is allowed to have.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from build_corpus import norm_key  # noqa: E402
from build_eval_large import render_target  # noqa: E402


def keys_of(path: Path) -> set:
    ks = set()
    with path.open() as f:
        for line in f:
            d = json.loads(line)
            ks.add(norm_key(" ".join(d["words"])))
            ks.add(norm_key(render_target(d)))
    ks.discard("")
    return ks


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--holdout", action="append", required=True)
    ap.add_argument("--train", action="append", required=True)
    args = ap.parse_args()

    train_keys = set()
    for t in args.train:
        p = Path(t)
        if not p.exists():
            raise SystemExit(f"[leak-check] missing train file: {p}")
        k = keys_of(p)
        train_keys |= k
        print(f"[leak-check] {p.name}: {len(k)} keys")

    bad = 0
    for h in args.holdout:
        p = Path(h)
        if not p.exists():
            raise SystemExit(f"[leak-check] missing holdout file: {p}")
        hk = keys_of(p)
        hit = hk & train_keys
        print(f"[leak-check] {p.name}: {len(hk)} keys, {len(hit)} in train")
        if hit:
            bad += len(hit)
            for x in sorted(hit)[:5]:
                print(f"[leak-check]   LEAKED: {x[:120]}")
    if bad:
        raise SystemExit(f"[leak-check] FAILED: {bad} holdout keys present in training data")
    print("[leak-check] OK -- no holdout key appears in training data")


if __name__ == "__main__":
    main()

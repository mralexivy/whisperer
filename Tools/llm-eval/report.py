#!/usr/bin/env python3
"""Print the per-language table for one or more scored arms.

Every figure carries its n. Russian is 1 case in the joinable corpus and Hebrew is
2; a per-language mean without its n reads exactly like the 32-case Russian column
in the documented baseline, and it is not that.

Usage:  python3 Tools/llm-eval/report.py [results-*.json ...]
"""

from __future__ import annotations

import argparse
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))

LANGUAGES = ("en", "he", "ru")
# The Nemotron-equivalent / engine-independence column. Produced by the Swift side
# (WhispererTests/PolishBenchmarkTests.swift) by re-running each case with
# ASRCapabilities = []; the schema carries `capabilityTier` so both runs land in one
# table. This harness scores whatever tier it is handed and does not compute it.
CAPABILITY_TIERS = ("full", "none")


def fmt(value, width=8, places=3):
    if value is None:
        return "—".rjust(width)
    return f"{value:+.{places}f}".rjust(width)


def n_of(block, language=None):
    if language is None:
        return block["n"]
    return block["perLanguage"][language]["n"]


def print_arm(result: dict) -> None:
    summary = result["summary"]
    composition = result["composition"]

    print("=" * 78)
    print(f"ARM: {result['arm']}    capability tier: {result.get('capabilityTier', 'full')}")
    print(f"database: {result['database']}")
    print(f"similarity: {result['similarity']}")
    print("=" * 78)

    print("\nCORPUS COMPOSITION")
    print(f"  cases          {composition['byLanguage']}  (total {summary['all']['n']})")
    print(f"  split          {composition['bySplit']}")
    print(f"  kind           {composition['byKind']}")
    print(f"  lang × split   {composition['byLanguageSplit']}")

    rate = result["invocationRate"]
    print("\nLLM INVOCATION RATE   (headline for the polish plan: must trend to 0)")
    for key, block in rate.items():
        print(
            f"  {key:<12} {block['rate']:.4f}  "
            f"({block['invoked']} / {block['eligible']})  — {block['note']}"
        )

    for scope in ("all", "train", "holdout"):
        block = summary[scope]
        print(f"\n{scope.upper()}   n={block['n']}   "
              f"balanced={fmt(block['balanced'])} (mean of per-language means, rule 8)   "
              f"rawMean={fmt(block['rawMean'])}")
        print("  lang    n   recovery   content   medHeadroom   precision   recall     F0.5    drift  gated")
        print("  " + "-" * 84)
        for language in LANGUAGES:
            per = block["perLanguage"][language]
            n = per["n"]
            if n == 0:
                print(f"  {language:<5} {n:>4}   {'—':>8}   {'—':>7}   {'—':>11}   "
                      f"{'—':>9}   {'—':>6}   {'—':>7}   {'—':>4}   {'—':>4}")
                continue
            print(
                f"  {language:<5} {n:>4}  {fmt(per['mean'])}  {fmt(per['contentRecovery'], 7)}  "
                f"{per['medianHeadroom']:>11.4f}  {per['precision']:>9.3f}  "
                f"{per['recall']:>6.3f}  {per['f05']:>7.3f}  {per['drift']:>4}  {per['gated']:>4}"
            )
        print(f"  overall (n={block['n']}):  precision {block['precision']:.3f}   "
              f"recall {block['recall']:.3f}   F0.5 {block['f05']:.3f}")
        print(f"  gates: {block['gates']}   "
              f"balanced content-recovery {fmt(block['balancedContentRecovery'])}")
        print(f"  languages in the balanced mean: {block['languagesInBalancedMean']}")

    preservation = summary["preservation"]
    print(f"\nPRESERVATION   n={preservation['n']}   mean sim(out,gold)={preservation['mean']}")
    print("  (criteria.md §2: already-clean inputs, headroom 0.02. "
          "Target is 1.000; rewriting clean text is a defect.)")


def print_capability_matrix(results: list[dict]) -> None:
    by_tier = {r.get("capabilityTier", "full"): r for r in results}
    print("\n" + "=" * 78)
    print("CAPABILITY-TIER MATRIX   (the engine-independence metric)")
    print("=" * 78)
    print("  tier    n     balanced   holdout    drift")
    for tier in CAPABILITY_TIERS:
        result = by_tier.get(tier)
        if result is None:
            print(f"  {tier:<6} {'—':>4}   {'—':>8}   {'—':>8}   {'—':>5}"
                  f"   not run — produced by PolishBenchmarkTests.swift")
            continue
        summary = result["summary"]
        print(f"  {tier:<6} {summary['all']['n']:>4}  "
              f"{fmt(summary['all']['balanced'])}  {fmt(summary['holdout']['balanced'])}  "
              f"{summary['all']['gates']['drift']:>5}")
    print("  The `none` column re-runs every case with ASRCapabilities = []. Its score is")
    print("  the Nemotron-equivalent number; a gap between the columns is engine dependence.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="*", default=None)
    args = parser.parse_args()

    paths = args.results or sorted(glob.glob(os.path.join(HERE, "results-*.json")))
    if not paths:
        raise SystemExit("no results-*.json found — run score.py first")

    results = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            result = json.load(handle)
        results.append(result)
        print_arm(result)

    print_capability_matrix(results)


if __name__ == "__main__":
    main()

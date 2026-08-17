#!/usr/bin/env python3
"""Scorer self-test on synthetic cases with known answers.

The documented +0.478 baseline cannot be reproduced (see README, "What cannot be
reproduced"), so the harness has to earn trust some other way. These cases pin the
behaviours the rules actually specify: recovery is 0 for a no-op and 1 at gold,
negative for a paraphrase; a gate caps rather than sets; drift is a flat -1.0 and a
more-broken output never outranks a less-broken one; and the balanced headline is
the mean of per-language means, not the mean over cases.

Usage:  python3 Tools/llm-eval/selftest.py
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import edit_ops, f_beta, sim, split_bucket  # noqa: E402
from score import aggregate, score_case  # noqa: E402

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    status = "ok  " if condition else "FAIL"
    if not condition:
        FAILURES.append(f"{name}: {detail}")
    print(f"  [{status}] {name}{('  — ' + detail) if detail else ''}")


def case(cid, language, text_in, text_out, gold, kind="recovery", split="train"):
    return score_case(
        {
            "id": cid,
            "language": language,
            "split": split,
            "kind": kind,
            "input": text_in,
            "gold": gold,
            "outputs": {"A": {"text": text_out, "latencySec": None}},
        },
        "A",
    )


GOLD_EN = "So I think we should ship this tomorrow."
IN_EN = "so i think we should um ship this tomorrow"


def main() -> None:
    print("recovery formula")
    noop = case("t-noop", "en", IN_EN, IN_EN, GOLD_EN)
    check("no-op scores 0 (rule: 0 = do nothing)",
          abs(noop["rawScore"]) < 1e-9, f"raw={noop['rawScore']}")
    check("no-op trips the timeout gate (process() returns input on timeout)",
          "timeout" in noop["gates"], str(noop["gates"]))

    perfect = case("t-perfect", "en", IN_EN, GOLD_EN, GOLD_EN)
    check("reaching gold scores 1.0", abs(perfect["score"] - 1.0) < 1e-9,
          f"score={perfect['score']}")
    check("reaching gold trips no gate", perfect["gates"] == [], str(perfect["gates"]))

    paraphrase = case("t-para", "en", IN_EN,
                      "Tomorrow, in my view, is when this ought to be released.", GOLD_EN)
    check("a paraphrase scores negative", paraphrase["score"] < 0,
          f"score={paraphrase['score']}")

    print("\ngates cap, they do not set (rule 9)")
    # Two Hebrew-gold cases whose outputs are both Latin gibberish; the longer one
    # trips degeneration. Being more broken must never score better.
    gold_he = "אני רוצה לראות עד כמה טוב זה יכול לעבוד."
    in_he = "אני רוצה לראות עד כמה טורף זה יכול לעבוד"
    short_junk = "asdf qwer zxcv asdf"
    long_junk = short_junk + " " + " ".join(["asdf qwer zxcv"] * 12)
    a = case("t-junk-short", "he", in_he, short_junk, gold_he)
    b = case("t-junk-long", "he", in_he, long_junk, gold_he)
    check("both junk outputs are language drift", "drift" in a["gates"] and "drift" in b["gates"])
    check("drift is a flat -1.0, not a capped recovery",
          a["score"] == -1.0 and b["score"] == -1.0, f"{a['score']} / {b['score']}")
    check("the longer junk also trips degeneration", "degeneration" in b["gates"],
          f"ratio={b['lengthRatio']}")
    check("more-broken never outranks less-broken", b["score"] <= a["score"])

    # A non-drift gate on an output that genuinely improved: cap at 0, do not set 0.
    # A long input so the echoed delimiters cost less similarity than the fixes gain
    # — otherwise the echo alone makes the output a regression and there is nothing
    # to cap. That is itself the point of gate 2: the echo is never free.
    long_gold = " ".join([GOLD_EN] * 8)
    long_in = " ".join([IN_EN] * 8)
    echoed = case("t-echo", "en", long_in, "[INPUT] " + long_gold + " [/INPUT]", long_gold)
    check("delimiter echo is gated", "echo" in echoed["gates"], str(echoed["gates"]))
    check("a gated improvement caps at 0, not below",
          echoed["rawScore"] > 0 and echoed["score"] == 0.0,
          f"raw={echoed['rawScore']} score={echoed['score']}")
    worse = case("t-echo-bad", "en", IN_EN, "[INPUT] totally different sentence [/INPUT]", GOLD_EN)
    check("a gated regression keeps its negative score (min(0, raw))",
          worse["score"] < 0, f"score={worse['score']}")

    print("\nlanguage drift is presence, not majority (knowledge.md)")
    gold_ru = "Запусти docker run --rm -it ubuntu bash."
    correct_ru = case("t-ru-ok", "ru", "запусти docker run dash dash rm dash it ubuntu bash",
                      gold_ru, gold_ru)
    translated = case("t-ru-drift", "ru", "запусти docker run dash dash rm dash it ubuntu bash",
                      "Run docker run --rm -it ubuntu bash.", gold_ru)
    check("majority-Latin Cyrillic gold: a correct Cyrillic answer is NOT drift",
          "drift" not in correct_ru["gates"], str(correct_ru["gates"]))
    check("majority-Latin Cyrillic gold: a real translation IS drift",
          "drift" in translated["gates"], str(translated["gates"]))

    print("\npreservation (criteria.md §2)")
    clean = case("t-clean", "en", GOLD_EN, GOLD_EN, GOLD_EN, kind="preservation")
    check("untouched clean text scores 1.000 preservation", clean["rawScore"] == 1.0)
    mangled = case("t-clean-mangled", "en", GOLD_EN,
                   "We ought to release this the following day.", GOLD_EN, kind="preservation")
    check("rewritten clean text scores below 1.000", mangled["rawScore"] < 1.0,
          f"{mangled['rawScore']}")

    print("\nedit precision / F0.5")
    both_edits = edit_ops(IN_EN, GOLD_EN)
    check("gold requires >= 2 word-level edits on the sample", len(both_edits) >= 2,
          str(sorted(both_edits)))
    check("F0.5 weights precision above recall",
          f_beta(0.8, 0.2) > f_beta(0.2, 0.8),
          f"{f_beta(0.8, 0.2):.4f} vs {f_beta(0.2, 0.8):.4f}")
    over = case("t-overedit", "en", IN_EN,
                "So I honestly think that we really should ship this tomorrow.", GOLD_EN)
    check("an over-editing output has precision < 1", over["precision"] < 1.0,
          f"P={over['precision']} made={over['editsMade']} correct={over['editsCorrect']}")

    print("\nheadline = mean of per-language means (rule 8)")
    skewed = [
        {"language": "en", "split": "train", "kind": "recovery", "score": 0.4,
         "precision": 0, "recall": 0, "f05": 0, "gates": [], "headroom": 0.5,
         "contentRecovery": 0.0}
        for _ in range(90)
    ] + [
        {"language": "ru", "split": "train", "kind": "recovery", "score": -0.8,
         "precision": 0, "recall": 0, "f05": 0, "gates": [], "headroom": 0.5,
         "contentRecovery": 0.0}
        for _ in range(10)
    ]
    summary = aggregate(skewed)["all"]
    check("a raw mean would hide the Russian collapse", summary["rawMean"] > 0.2,
          f"rawMean={summary['rawMean']}")
    check("the balanced mean exposes it", abs(summary["balanced"] - (-0.2)) < 1e-6,
          f"balanced={summary['balanced']}")

    print("\nsimilarity + split")
    check("sim is symmetric", abs(sim(IN_EN, GOLD_EN) - sim(GOLD_EN, IN_EN)) < 1e-12)
    check("sim(x, x) == 1.0", sim(GOLD_EN, GOLD_EN) == 1.0)
    check("sim is in [0, 1]", 0.0 <= sim(IN_EN, gold_he) <= 1.0)
    buckets = [split_bucket(f"{i:032X}") for i in range(2000)]
    fraction = buckets.count("train") / len(buckets)
    check("split is deterministic", split_bucket("ABC") == split_bucket("ABC"))
    check("split lands near the documented 48/112 train fraction",
          abs(fraction - 48 / 112) < 0.05, f"train fraction={fraction:.3f}")

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for failure in FAILURES:
            print(f"  - {failure}")
        raise SystemExit(1)
    print("all scorer self-tests passed")


if __name__ == "__main__":
    main()

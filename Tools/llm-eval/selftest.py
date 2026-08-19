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

import collections
import json
import os
import pathlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import edit_ops, f_beta, filler_strip, script_of, sim, split_bucket  # noqa: E402
from score import aggregate, score_case  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    status = "ok  " if condition else "FAIL"
    if not condition:
        FAILURES.append(f"{name}: {detail}")
    print(f"  [{status}] {name}{('  — ' + detail) if detail else ''}")


def case(cid, language, text_in, text_out, gold, kind="recovery", split="train",
         latency=None):
    return score_case(
        {
            "id": cid,
            "language": language,
            "split": split,
            "kind": kind,
            "input": text_in,
            "gold": gold,
            "outputs": {"A": {"text": text_out, "latencySec": latency}},
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

    print("\ntimeout is a latency measurement; identity is only its fallback proxy")
    # `output == input` means "timed out" ONLY when no latency was recorded. When the
    # arm measured its own latency and it is inside the ladder, the ladder demonstrably
    # did not expire, and the no-op is rule 4's "the default is to change nothing".
    noop_measured = case("t-noop-fast", "en", IN_EN, IN_EN, GOLD_EN, latency=1.4)
    check("an inside-budget no-op is NOT a timeout",
          "timeout" not in noop_measured["gates"], str(noop_measured["gates"]))
    check("...but it is still recorded as a no-op", noop_measured["noOp"])
    slow = case("t-slow", "en", IN_EN, GOLD_EN, GOLD_EN, latency=99.0)
    check("an over-budget latency IS a timeout even when the text changed",
          "timeout" in slow["gates"], str(slow["gates"]))
    check("the identity proxy still applies when latency is unrecorded",
          "timeout" in noop["gates"], str(noop["gates"]))

    print("\ndrift is not adjudicated on a truncated output")
    # A Hebrew input whose tail carries Latin words, cut off before reaching them.
    # The surviving prefix is correct Hebrew: that is truncation, not language drift.
    gold_mixed = "אני רוצה לראות עד כמה טוב זה עובד עם expand collapse ועוד דברים כאלה בכלל"
    in_mixed = "אני רוצה לראות עד כמה טוב זה עובד עם expand collapse ועוד דברים כאלה בכלל"
    cut = case("t-cut", "he", in_mixed, "אני רוצה לראות עד", gold_mixed)
    check("a truncated prefix is degeneration, not drift",
          "degeneration" in cut["gates"] and "drift" not in cut["gates"], str(cut["gates"]))
    check("the unjudgeable verdict is recorded, not silently dropped",
          cut["driftUnjudgeable"] and cut["missingScripts"] == ["en"],
          f"{cut['driftUnjudgeable']} {cut['missingScripts']}")
    full_drift = case("t-full-drift", "he", in_mixed,
                      "I want to see how well this works with expand collapse and such",
                      gold_mixed)
    check("a full-length answer in the wrong language IS still drift",
          "drift" in full_drift["gates"] and full_drift["score"] == -1.0,
          str(full_drift["gates"]))

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
         "contentRecovery": 0.0, "noOp": False, "driftUnjudgeable": False,
         "latencySec": None}
        for _ in range(90)
    ] + [
        {"language": "ru", "split": "train", "kind": "recovery", "score": -0.8,
         "precision": 0, "recall": 0, "f05": 0, "gates": [], "headroom": 0.5,
         "contentRecovery": 0.0, "noOp": False, "driftUnjudgeable": False,
         "latencySec": None}
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

    print("\nscript_of() — same logic as sample_authoring_batches.py")
    check("script_of: Latin text → en", script_of("hello world") == "en",
          script_of("hello world"))
    # Majority-Cyrillic text: must have more Cyrillic than Latin characters.
    # "мы используем Redis для очереди" → 23 Cyrillic, 5 Latin (Redis) → Cyrillic wins.
    _ru_text = "мы используем Redis для очереди"
    check("script_of: majority-Cyrillic text → ru",
          script_of(_ru_text) == "ru",
          f"result={script_of(_ru_text)!r} (text={_ru_text!r})")
    check("script_of: Hebrew text → he",
          script_of("אני רוצה לראות") == "he",
          script_of("אני רוצה לראות"))
    check("script_of: empty → other", script_of("") == "other", script_of(""))
    # Majority Latin in a Cyrillic context: more Latin chars → en.
    # "run docker Ѐ" repeated: "run docker " = 9 Latin chars, "Ѐ" = 1 Cyrillic → Latin wins.
    # For Cyrillic to win we need more Cyrillic than Latin.
    _cyrillic_majority = "мы мы мы мы мы run"  # 10 Cyrillic, 3 Latin
    check("script_of: majority wins (more Cyrillic than Latin → ru)",
          script_of(_cyrillic_majority) == "ru",
          f"result={script_of(_cyrillic_majority)!r} (text={_cyrillic_majority!r})")

    print("\nfiller_strip() and authored-gold unit checks (synthetic)")
    # Verify filler_strip removes declared fillers and preserves content.
    stripped = filler_strip("um so i think we should uh ship this")
    check("filler_strip removes 'um' and 'uh'",
          "um" not in stripped.split() and "uh" not in stripped.split(),
          stripped)
    check("filler_strip preserves content words",
          "think" in stripped.split() and "ship" in stripped.split(),
          stripped)

    # Synthetic corpus entries that exercise the three gold authoring constraints:
    # (1) script identity, (2) content-word similarity after filler strip, (3) headroom.
    _GOLD_CASES: list[dict] = [
        {
            "id": "synth-en-ok",
            "language": "en",
            "durationSec": 5.0,
            "input": "um so i think we should uh ship this tomorrow",
            "gold": "So I think we should ship this tomorrow.",
        },
        {
            "id": "synth-ru-ok",
            "language": "ru",
            "durationSec": 5.0,
            "input": "ну мы используем редис для очереди но он иногда падает",
            "gold": "Мы используем Redis для очереди, но он иногда падает.",
        },
        {
            "id": "synth-he-ok",
            "language": "he",
            "durationSec": 5.0,
            "input": "אה אני רוצה לראות עד כמה טוב זה יכול לעבוד",
            "gold": "אני רוצה לראות עד כמה טוב זה יכול לעבוד.",
        },
    ]

    def _check_gold_case(c: dict) -> None:
        cid = c["id"]
        text_in, gold = c["input"], c["gold"]
        script_in = script_of(text_in)
        script_gold = script_of(gold)
        check(
            f"synth {cid}: script identity (input={script_in}, gold={script_gold})",
            script_in == script_gold,
            f"input script={script_in}  gold script={script_gold}",
        )
        content_sim = sim(filler_strip(text_in), filler_strip(gold))
        check(
            f"synth {cid}: content-word similarity >= 0.70 after filler strip",
            content_sim >= 0.70,
            f"sim={content_sim:.3f}",
        )
        headroom = 1.0 - sim(text_in, gold)
        check(
            f"synth {cid}: headroom 1-sim(input,gold) >= 0.05",
            headroom >= 0.05,
            f"headroom={headroom:.4f}",
        )

    for _c in _GOLD_CASES:
        _check_gold_case(_c)

    # Also check that a bad case fails the constraints (verifies the checks fire).
    _same = {
        "id": "synth-same", "language": "en", "durationSec": 5.0,
        "input": "hello world",
        "gold": "hello world",   # identical → headroom 0, should fail constraint 3
    }
    _headroom_same = 1.0 - sim(_same["input"], _same["gold"])
    check(
        "synth sanity: identical input/gold has headroom < 0.05 (verifies check fires)",
        _headroom_same < 0.05,
        f"headroom={_headroom_same:.4f}",
    )
    _drifted = {
        "id": "synth-drift", "language": "en", "durationSec": 5.0,
        "input": "hello world how are you today",
        "gold": "שלום עולם",  # Hebrew gold for English input — script mismatch
    }
    check(
        "synth sanity: Hebrew gold for English input fails script identity",
        script_of(_drifted["input"]) != script_of(_drifted["gold"]),
        f"input={script_of(_drifted['input'])} gold={script_of(_drifted['gold'])}",
    )

    # There are two authored corpora, and each is checked against the gates *it* claims —
    # not against one merged gate set. `assemble_gold.py` emits them from the same material
    # for two different metrics: the recovery corpus is headroom-gated because recovery
    # divides by that headroom, and the punctuation corpus deliberately is not, because a gold
    # whose only difference from its input is punctuation is the ideal boundary reference
    # rather than a defective one. Applying the headroom gate to both was what made this block
    # exit 1 on nine cases that were doing exactly what their corpus asks of them.
    _AUTHORING_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "authoring")
    _TERMINATORS = set(".!?׃…")

    for _name, _needs_headroom, _needs_boundary in (
        ("gold-corpus.json", True, False),
        ("gold-corpus-punctuation.json", False, True),
    ):
        print(f"\nauthored-gold corpus constraints ({_name} if present)")
        _path = os.path.join(_AUTHORING_DIR, _name)
        if not os.path.exists(_path):
            print(f"  SKIP — {_path} not found; "
                  f"run the authoring pipeline to produce it, then re-run selftest.")
            continue

        with open(_path, encoding="utf-8") as _fh:
            _cases = json.load(_fh).get("cases", [])
        print(f"  loaded {len(_cases)} cases from {_name}")

        _n_fail_script = _n_fail_content = _n_fail_headroom = _n_fail_boundary = 0
        for _c in _cases:
            _cid = _c["id"]
            _in, _gld = _c["input"], _c["gold"]
            _s_in, _s_gld = script_of(_in), script_of(_gld)
            if _s_in != _s_gld:
                _n_fail_script += 1
                FAILURES.append(f"{_name} {_cid}: script mismatch input={_s_in} gold={_s_gld}")

            _csim = sim(filler_strip(_in), filler_strip(_gld))
            if _csim < 0.70:
                _n_fail_content += 1
                FAILURES.append(
                    f"{_name} {_cid}: content-word sim={_csim:.3f} < 0.70 after filler strip"
                )

            if _needs_headroom:
                _hdroom = 1.0 - sim(_in, _gld)
                if _hdroom < 0.05:
                    _n_fail_headroom += 1
                    FAILURES.append(
                        f"{_name} {_cid}: headroom={_hdroom:.4f} < 0.05 "
                        f"(nothing to recover toward)"
                    )

            if _needs_boundary and not any(_ch in _TERMINATORS for _ch in _gld):
                # A boundary reference with no boundary in it contributes nothing but a zero
                # denominator to the F1, so its presence in this corpus is itself the defect.
                _n_fail_boundary += 1
                FAILURES.append(f"{_name} {_cid}: gold carries no sentence terminator")

        check(f"{_name}: script identity for all {len(_cases)} cases",
              _n_fail_script == 0, f"{_n_fail_script} violation(s)")
        check(f"{_name}: content-word similarity >= 0.70 for all {len(_cases)} cases",
              _n_fail_content == 0, f"{_n_fail_content} violation(s)")
        if _needs_headroom:
            check(f"{_name}: headroom >= 0.05 for all {len(_cases)} cases",
                  _n_fail_headroom == 0, f"{_n_fail_headroom} violation(s)")
        if _needs_boundary:
            check(f"{_name}: >= 1 sentence terminator in all {len(_cases)} golds",
                  _n_fail_boundary == 0, f"{_n_fail_boundary} violation(s)")

    # --- chunk corpus -------------------------------------------------------
    #
    # `chunk-corpus.json` is the only source of chunk timings any test has, and it is generated
    # once by a GPU run and then committed — so a corruption in it would be invisible and would
    # silently mis-score every interior-boundary measurement made afterwards. These checks are
    # structural only: they cannot say the spans are *right*, just that they are spans.
    _corpus_path = HERE / "chunk-corpus.json"
    if _corpus_path.exists():
        _corpus = json.loads(_corpus_path.read_text())
        _records = _corpus["records"]
        check("chunk corpus: non-empty", len(_records) > 0, f"{len(_records)} record(s)")

        _bad_order = _overlap = _no_reference = 0
        _joins = 0
        for _record in _records:
            _chunks = _record["chunks"]
            _joins += max(0, len(_chunks) - 1)
            for _chunk in _chunks:
                if _chunk["end"] < _chunk["start"]:
                    _bad_order += 1
            for _left, _right in zip(_chunks, _chunks[1:]):
                # Consecutive chunks must not overlap: the pause at a join is `next.start -
                # current.end`, so an overlap makes it negative and `SentenceTerminator` would be
                # asked about a silence that ran backwards.
                if _right["start"] < _left["end"]:
                    _overlap += 1
            if not _record["goldenTranscript"].strip() and not _record.get("hasAuthoredGold"):
                _no_reference += 1

        check(f"chunk corpus: end >= start in all {len(_records)} records",
              _bad_order == 0, f"{_bad_order} chunk(s) with end < start")
        check("chunk corpus: consecutive chunks do not overlap",
              _overlap == 0, f"{_overlap} overlapping join(s)")
        check("chunk corpus: every record has at least one reference",
              _no_reference == 0, f"{_no_reference} record(s) with neither")
        check("chunk corpus: has joins to measure", _joins > 0, f"{_joins} join(s)")

        _scripts = collections.Counter(_r["script"] for _r in _records)
        print(f"  chunk corpus: {len(_records)} records, {_joins} joins, "
              + ", ".join(f"{_k} {_v}" for _k, _v in sorted(_scripts.items())))

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILURE(S):")
        for failure in FAILURES:
            print(f"  - {failure}")
        raise SystemExit(1)
    print("all scorer self-tests passed")


if __name__ == "__main__":
    main()

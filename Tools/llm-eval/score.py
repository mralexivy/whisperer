#!/usr/bin/env python3
"""Score an arm of the LLM-polish corpus.

Implements, exactly as written down in docs/knowledge/llm/:

  recovery = (sim(out,gold) - sim(in,gold)) / (1 - sim(in,gold))     criteria.md §2
  preservation = sim(out,gold) for already-clean inputs               criteria.md §2
  headline = mean of the per-language means                           rule 8
  gates cap the score at 0, they do not set it                        rule 9
  language drift is the exception: a flat -1.0                        rule 9
  four hard gates: drift / echo / timeout / degeneration              criteria.md §3
  every raw output is written to disk                                 rule 11

Plus three metrics the old harness lacked: edit precision, F0.5, and the LLM
invocation rate.

Usage:  python3 Tools/llm-eval/score.py [--corpus corpus.json] [--arm A_shipped_correct]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import (  # noqa: E402
    edit_ops,
    f_beta,
    fold,
    mean,
    normalize,
    script_of,
    scripts_present,
    sim,
)

HERE = os.path.dirname(os.path.abspath(__file__))

# criteria.md §3.4
DEGENERATION_MIN_RATIO = 0.4
DEGENERATION_MAX_RATIO = 2.5

# criteria.md §3.3 — the ladder LLMPostProcessor.process() applies.
def timeout_budget(input_chars: int) -> float:
    if input_chars < 30:
        return 5.0
    if input_chars < 200:
        return 10.0
    return 15.0


# criteria.md §3.2. `[INPUT]`/`[/INPUT]` is the measured failure (3 Russian cases);
# the preamble list is the shapes rule 5 and knowledge.md name explicitly.
ECHO_PATTERNS = [
    re.compile(r"\[/?INPUT\]", re.IGNORECASE),
    re.compile(r"\[/?OUTPUT\]", re.IGNORECASE),
    re.compile(r"^\s*(here (is|'s) the (corrected|fixed)|corrected text|output|answer|result)\s*[:\-]", re.IGNORECASE),
    re.compile(r"^\s*(sure|certainly|of course)[,!]", re.IGNORECASE),
    re.compile(r"<\s*/?think\s*>", re.IGNORECASE),
    # A leaked ChatML special token is the same failure one layer down: the model
    # reopened the scaffold instead of answering. Found on the single Russian case
    # in this corpus, which emitted `<|im_start|>\nINPUT` mid-output.
    re.compile(r"<\|im_(start|end)\|>"),
    re.compile(r"(?m)^\s*/?INPUT\s*$"),
]


def score_case(case: dict, arm: str) -> dict | None:
    arm_data = case["outputs"].get(arm)
    if arm_data is None:
        return None

    text_in = case["input"]
    text_out = arm_data["text"]
    gold = case["gold"]

    sim_in = sim(text_in, gold)
    sim_out = sim(text_out, gold)

    # --- gates ------------------------------------------------------------
    gates: list[str] = []

    # Length ratio is computed first: two gates below depend on it.
    len_in = max(len(normalize(text_in)), 1)
    ratio = len(normalize(text_out)) / len_in
    truncated = ratio < DEGENERATION_MIN_RATIO

    # 1. Language drift, on script PRESENCE not majority (knowledge.md).
    #    "the gold contains Cyrillic, so the output must contain Cyrillic".
    #
    #    BUT presence is only judgeable on a COMPLETE output. A generation cut off
    #    part-way through cannot be said to have "left the input's language"
    #    (criteria.md §3.1) — it never reached the part of the sentence carrying the
    #    other script. Measured here on case BA4FD46C: a Hebrew input whose tail
    #    contains the Latin words `expand collapse`, truncated at 28% of input
    #    length. The surviving prefix is entirely correct Hebrew, yet the gate
    #    charged it the flat -1.0 for "losing" Latin it was cut off before emitting.
    #    That is a truncation failure, which `degeneration` below already catches;
    #    scoring it as drift too both double-counts and mislabels the cause. Drift is
    #    therefore not adjudicated on a truncated output — the outcome is recorded as
    #    `driftUnjudgeable` so the case is never silently treated as clean.
    gold_scripts = scripts_present(gold)
    out_scripts = scripts_present(text_out)
    missing_scripts = gold_scripts - out_scripts if gold_scripts else set()
    drift_unjudgeable = bool(missing_scripts) and truncated
    drifted = bool(missing_scripts) and not truncated
    if drifted:
        gates.append("drift")

    # 2. Preamble / delimiter echo.
    if any(pattern.search(text_out) for pattern in ECHO_PATTERNS):
        gates.append("echo")

    # 3. Timeout. `process()` silently returns the UNCORRECTED text when the ladder
    #    expires (criteria.md §3.3), so an over-budget case is an invisible no-op in
    #    production.
    #
    #    The DIRECT observation is a recorded latency over budget. `output ==
    #    input` is only a PROXY for it, and one that is valid solely when no latency
    #    was recorded — the historical `ZAIENHANCEDTEXT` rows of arm A, where
    #    build_corpus.py has already dropped identical outputs anyway.
    #
    #    Applying the proxy to a live arm that DID record its latency is a scorer
    #    bug, and it fired: all 6-7 "timeouts" on arms B/C ran in 0.93-2.64s against
    #    a 10-15s budget. Every one of them is the model correctly deciding the input
    #    needed no change — rules.md rule 4, "the default is to change nothing" —
    #    relabelled as a production failure. A measured, inside-budget latency is
    #    positive evidence that the ladder did NOT expire, so it settles the question
    #    and the proxy must not override it.
    latency = arm_data.get("latencySec")
    budget = timeout_budget(len(normalize(text_in)))
    if latency is not None:
        timed_out = latency > budget
    else:
        timed_out = normalize(text_out) == normalize(text_in)
    if timed_out:
        gates.append("timeout")

    # A no-op that is NOT a timeout is still worth counting: it is the "changed
    # nothing" outcome, which scores a clean 0 recovery and is a legitimate result.
    no_op = normalize(text_out) == normalize(text_in)

    # 4. Degeneration: output/input length ratio outside 0.4…2.5.
    if not (DEGENERATION_MIN_RATIO <= ratio <= DEGENERATION_MAX_RATIO):
        gates.append("degeneration")

    # --- score ------------------------------------------------------------
    if case["kind"] == "preservation":
        raw = sim_out                      # criteria.md §2: preservation, not recovery
    else:
        headroom = 1.0 - sim_in
        raw = (sim_out - sim_in) / headroom if headroom > 1e-9 else 0.0

    if drifted:
        score = -1.0                        # rule 9: the sole flat value
    elif gates:
        score = min(0.0, raw)               # rule 9: gates CAP, they do not SET
    else:
        score = raw

    # --- content-only recovery (secondary axis) ---------------------------
    # Same formula over case-folded, punctuation-stripped text. `gold` is a raw
    # whisper decode, so its punctuation and casing are model artefacts rather than
    # a correction target; recovery against them charges the prompt for doing its
    # job. Folding both sides isolates the word choices, which an ASR reference can
    # legitimately adjudicate. Reported alongside, never instead of, the headline.
    sim_in_folded = sim(fold(text_in), fold(gold))
    sim_out_folded = sim(fold(text_out), fold(gold))
    folded_headroom = 1.0 - sim_in_folded
    content_recovery = (
        (sim_out_folded - sim_in_folded) / folded_headroom
        if folded_headroom > 1e-9
        else 0.0
    )

    # --- edit precision / recall / F0.5 -----------------------------------
    required = edit_ops(text_in, gold)      # what the input needed
    made = edit_ops(text_in, text_out)      # what the model did
    correct = required & made
    precision = len(correct) / len(made) if made else (1.0 if not required else 0.0)
    recall = len(correct) / len(required) if required else 1.0

    return {
        "id": case["id"],
        "language": case["language"],
        "split": case["split"],
        "kind": case["kind"],
        "simInputGold": round(sim_in, 6),
        "simOutputGold": round(sim_out, 6),
        "rawScore": round(raw, 6),
        "score": round(score, 6),
        "headroom": round(1.0 - sim_in, 6),
        "simInputGoldFolded": round(sim_in_folded, 6),
        "simOutputGoldFolded": round(sim_out_folded, 6),
        "contentRecovery": round(content_recovery, 6),
        "gates": gates,
        "driftUnjudgeable": drift_unjudgeable,
        "missingScripts": sorted(missing_scripts),
        "noOp": no_op,
        "latencySec": latency,
        "timeoutBudgetSec": budget,
        "lengthRatio": round(ratio, 4),
        "editsRequired": len(required),
        "editsMade": len(made),
        "editsCorrect": len(correct),
        "precision": round(precision, 6),
        "recall": round(recall, 6),
        "f05": round(f_beta(precision, recall, 0.5), 6),
        "input": text_in,
        "output": text_out,
        "gold": gold,
    }


def aggregate(scored: list[dict], languages=("en", "he", "ru")) -> dict:
    def block(subset: list[dict]) -> dict:
        by_language = {
            language: [row for row in subset if row["language"] == language]
            for language in languages
        }
        per_language = {
            language: {
                "n": len(rows),
                "mean": round(mean(r["score"] for r in rows), 4) if rows else None,
                "medianHeadroom": round(
                    sorted(r["headroom"] for r in rows)[len(rows) // 2], 4
                ) if rows else None,
                "contentRecovery": round(
                    mean(r["contentRecovery"] for r in rows), 4
                ) if rows else None,
                "precision": round(mean(r["precision"] for r in rows), 4) if rows else None,
                "recall": round(mean(r["recall"] for r in rows), 4) if rows else None,
                "f05": round(mean(r["f05"] for r in rows), 4) if rows else None,
                "drift": sum(1 for r in rows if "drift" in r["gates"]),
                "gated": sum(1 for r in rows if r["gates"]),
            }
            for language, rows in by_language.items()
        }
        # rule 8 / criteria.md §2 — mean of the per-language means, over the
        # languages that are actually represented.
        present = [v["mean"] for v in per_language.values() if v["n"]]
        return {
            "n": len(subset),
            "balanced": round(mean(present), 4) if present else None,
            "rawMean": round(mean(r["score"] for r in subset), 4) if subset else None,
            "balancedContentRecovery": round(
                mean(v["contentRecovery"] for v in per_language.values() if v["n"]), 4
            ) if present else None,
            "languagesInBalancedMean": [k for k, v in per_language.items() if v["n"]],
            "perLanguage": per_language,
            "precision": round(mean(r["precision"] for r in subset), 4) if subset else None,
            "recall": round(mean(r["recall"] for r in subset), 4) if subset else None,
            "f05": round(mean(r["f05"] for r in subset), 4) if subset else None,
            "gates": {
                gate: sum(1 for r in subset if gate in r["gates"])
                for gate in ("drift", "echo", "timeout", "degeneration")
            },
            "noOps": sum(1 for r in subset if r["noOp"]),
            "driftUnjudgeable": sum(1 for r in subset if r["driftUnjudgeable"]),
            "maxLatencySec": round(
                max((r["latencySec"] for r in subset if r["latencySec"] is not None), default=0.0), 3
            ),
        }

    return {
        "all": block(scored),
        "train": block([r for r in scored if r["split"] == "train"]),
        "holdout": block([r for r in scored if r["split"] == "holdout"]),
        "preservation": {
            "n": sum(1 for r in scored if r["kind"] == "preservation"),
            "mean": round(
                mean(r["score"] for r in scored if r["kind"] == "preservation"), 4
            )
            if any(r["kind"] == "preservation" for r in scored)
            else None,
        },
    }


def invocation_rate(corpus: dict) -> dict:
    """The share of utterances that reached the generative model at all.

    The headline for the whole polish plan: it starts near 100% for dictation with
    AI mode on, and must trend to 0 as the deterministic path takes the work.

    Two denominators, because they answer different questions:
      - `overHistory`: every dictation row, AI mode on or off. This is the
        user-behaviour number, not a property of the routing logic.
      - `overCorpus`: 1.000 by construction — the corpus is *defined* as rows the
        LLM ran on and changed. Recorded so nobody reads it as a result.
    """
    provenance = corpus["provenance"]
    return {
        "overHistory": {
            "invoked": provenance["rowsWithAIOutput"],
            "eligible": provenance["rowsMatchingLoaderSQL"],
            "rate": round(
                provenance["rowsWithAIOutput"] / provenance["rowsMatchingLoaderSQL"], 4
            ),
            "note": "AI mode was user-toggled over this history; not a routing measurement",
        },
        "overCorpus": {
            "invoked": provenance["casesKept"],
            "eligible": provenance["casesKept"],
            "rate": 1.0,
            "note": "1.000 by construction — corpus selection requires an LLM call",
        },
    }


# ---------------------------------------------------------------------------
# Authored-gold scoring path — selected by --gold.
# Replaces the corpus-embedded gold (a same-model decode, median headroom 0.038)
# with an authored reference.  Language grouping uses script_of() over the text,
# never the declared field.  Old invocations (no --gold) are unchanged.
# ---------------------------------------------------------------------------

_MIN_N_MEASURED = 20  # below this, per-language figures are unmeasured


def _gold_composition(scored: list[dict]) -> dict:
    """Composition summary for the intersection that was actually scored."""
    by_lang: dict[str, int] = {}
    by_split: dict[str, int] = {}
    by_kind: dict[str, int] = {}
    by_lang_split: dict[str, int] = {}
    for row in scored:
        lang, split, kind = row["language"], row["split"], row["kind"]
        by_lang[lang] = by_lang.get(lang, 0) + 1
        by_split[split] = by_split.get(split, 0) + 1
        by_kind[kind] = by_kind.get(kind, 0) + 1
        key = f"{lang}:{split}"
        by_lang_split[key] = by_lang_split.get(key, 0) + 1
    return {
        "byLanguage": by_lang,
        "bySplit": by_split,
        "byKind": by_kind,
        "byLanguageSplit": by_lang_split,
        "note": "language grouping by Unicode script_of(input), not declared field",
    }


def score_against_gold(corpus: dict, gold_corpus: dict, arm: str) -> list[dict]:
    """Score cases where arm output exists AND an authored gold reference is available.

    Intersection is by case id.  For each matched case:
      - ``case["gold"]`` is replaced with the authored reference.
      - ``case["language"]`` is replaced with ``script_of(input)`` so the per-
        language means in ``aggregate()`` reflect script, not the declared field.

    Cases absent from the gold corpus are silently skipped (they cannot be scored
    against an authored reference).  Cases absent from the arm are also skipped.
    """
    gold_index = {c["id"]: c["gold"] for c in gold_corpus["cases"]}
    scored: list[dict] = []
    for case in corpus["cases"]:
        authored_gold = gold_index.get(case["id"])
        if authored_gold is None:
            continue
        if case["outputs"].get(arm) is None:
            continue
        # Shadow gold and language — do not mutate the original dict.
        modified = dict(case)
        modified["gold"] = authored_gold
        modified["language"] = script_of(case["input"])
        row = score_case(modified, arm)
        if row is not None:
            scored.append(row)
    return scored


def _fmt_measured(value, n: int, width: int = 8, places: int = 3) -> str:
    """Format a per-language figure, replacing point estimates when n is too small."""
    if value is None:
        return "—".rjust(width)
    if n < _MIN_N_MEASURED:
        return f"unmeasured(n={n})".rjust(width)
    return f"{value:+.{places}f}".rjust(width)


def print_gold_summary(scored: list[dict], arm: str, gold_path: str) -> None:
    """Print recovery summary for the authored-gold path.

    Every figure carries its n.  Per-language figures with n < 20 are labelled
    ``unmeasured`` rather than shown as a point estimate.
    """
    if not scored:
        print(f"authored-gold: no cases scored for arm {arm} (intersection is empty)")
        return

    summary = aggregate(scored)
    block = summary["all"]
    holdout_block = summary["holdout"]

    print(f"\nAUTHORED-GOLD SCORING   gold={gold_path}")
    print(f"arm: {arm}   n_intersection={block['n']}   "
          f"(language grouped by Unicode script of input text)")
    print(f"  note: per-language figures with n < {_MIN_N_MEASURED} are labelled unmeasured")
    print()

    for scope, sb in (("all", block), ("holdout", holdout_block)):
        n_total = sb["n"]
        balanced = sb["balanced"]
        balanced_str = (
            f"{balanced:+.4f}" if balanced is not None else "—"
        )
        print(f"{scope.upper()}  n={n_total}   balanced={balanced_str}  "
              f"rawMean={sb['rawMean']:+.4f}" if sb["rawMean"] is not None
              else f"{scope.upper()}  n={n_total}   balanced={balanced_str}  rawMean=—"
        )
        print(f"  {'lang':<5} {'n':>5}  {'recovery':>20}  {'content':>20}  "
              f"{'medHeadroom':>12}  {'drift':>5}  {'gated':>5}")
        print("  " + "-" * 75)
        for lang in ("en", "he", "ru"):
            per = sb["perLanguage"][lang]
            n = per["n"]
            if n == 0:
                print(f"  {lang:<5} {n:>5}  {'—':>20}  {'—':>20}  {'—':>12}  {'—':>5}  {'—':>5}")
                continue
            rec_str = _fmt_measured(per["mean"], n, width=20)
            con_str = _fmt_measured(per["contentRecovery"], n, width=20)
            head_str = (
                f"{per['medianHeadroom']:>12.4f}"
                if n >= _MIN_N_MEASURED else f"{'unmeasured':>12}"
            )
            print(f"  {lang:<5} {n:>5}  {rec_str}  {con_str}  {head_str}  "
                  f"{per['drift']:>5}  {per['gated']:>5}")
        print(f"  gates: {sb['gates']}   noOps={sb['noOps']}")
        print()


def merge_extra_arm(corpus: dict, dump_path: str) -> None:
    """Attach a Swift-produced arm dump to the in-memory corpus.

    The deterministic arm's output cannot be read out of the history the way arm A's can — it
    is computed by `DeterministicPolisher`, so it has to arrive from the Swift side. Merging in
    memory rather than writing it into `corpus.json` keeps that file what it is: a record of
    what the shipped model actually returned for these recordings, which is the one thing here
    that cannot be regenerated.

    Ids in the dump that are not in the corpus are ignored — the dump is keyed by whatever the
    test was pointed at, and a superset is not an error. Ids in the corpus with no dump entry
    keep `None` for this arm and are skipped by the scorer, as any missing arm output is.
    """
    with open(dump_path, encoding="utf-8") as handle:
        dump = json.load(handle)

    arm = dump["arm"]
    outputs = dump["outputs"]
    attached = 0
    for case in corpus["cases"]:
        entry = outputs.get(case["id"])
        if entry is None:
            continue
        # The corpus stores each arm as a record, not a bare string — `score_case` reads
        # `arm_data["text"]` and `arm_data.get("latencySec")`. Writing the string directly is
        # what made the scorer raise `string indices must be integers`; the shape is the
        # contract, so it is constructed here rather than assumed.
        case["outputs"][arm] = {
            "text": entry["text"],
            "latencySec": entry.get("latencySec"),
            "capabilityTier": dump.get("capabilityTier", "full"),
            "source": dump.get("source", dump_path),
        }
        attached += 1
    print(f"merged arm {arm} from {dump_path}: {attached}/{len(corpus['cases'])} cases")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", default=os.path.join(HERE, "corpus.json"))
    parser.add_argument("--arm", default="A_shipped_correct")
    parser.add_argument("--out", default=None)
    parser.add_argument(
        "--raw-dir",
        default=os.path.join(HERE, "raw"),
        help="rule 11: every raw output is written here, one file per case",
    )
    parser.add_argument(
        "--gold",
        default=None,
        metavar="GOLD_CORPUS",
        help=(
            "path to an authored gold corpus (e.g. Tools/llm-eval/authoring/gold-corpus.json). "
            "When present, recovery is scored against the authored reference instead of the "
            "same-model decode embedded in corpus.json. Language grouping switches to "
            "script_of(input). Old invocations without --gold are unchanged."
        ),
    )
    parser.add_argument(
        "--extra-arm",
        default=None,
        metavar="ARM_DUMP",
        help=(
            "path to an arm dump written by a Swift test (e.g. arm-D_deterministic.json, from "
            "WhispererTests/PolishCorpusDumpTests). Its outputs are merged into the corpus in "
            "memory under its declared arm name so --arm can select it. corpus.json is never "
            "rewritten: it is the record of what the shipped LLM returned and nothing computed "
            "later belongs in it."
        ),
    )
    args = parser.parse_args()

    with open(args.corpus, encoding="utf-8") as handle:
        corpus = json.load(handle)

    if args.extra_arm is not None:
        merge_extra_arm(corpus, args.extra_arm)

    # ------------------------------------------------------------------
    # Authored-gold path  (--gold supplied)
    # ------------------------------------------------------------------
    if args.gold is not None:
        with open(args.gold, encoding="utf-8") as handle:
            gold_corpus = json.load(handle)

        scored = score_against_gold(corpus, gold_corpus, args.arm)

        raw_dir = os.path.join(args.raw_dir, f"{args.arm}-authored-gold")
        os.makedirs(raw_dir, exist_ok=True)
        for row in scored:
            with open(os.path.join(raw_dir, f"{row['id']}.json"), "w",
                      encoding="utf-8") as handle:
                json.dump(row, handle, ensure_ascii=False, indent=2)

        result = {
            "arm": args.arm,
            "goldCorpus": args.gold,
            "corpus": args.corpus,
            "database": corpus["database"],
            "capabilityTier": "full",
            "similarity": "normalized character-level edit similarity (see common.sim)",
            "languageGrouping": "script_of(input) — Unicode script, not declared field",
            "goldSource": "authored",
            "composition": _gold_composition(scored),
            "invocationRate": invocation_rate(corpus),
            "summary": aggregate(scored),
            "cases": scored,
            "rawOutputDir": raw_dir,
        }

        out_path = args.out or os.path.join(HERE, f"results-{args.arm}-authored-gold.json")
        with open(out_path, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)

        print_gold_summary(scored, args.arm, args.gold)
        print(f"wrote {out_path} and {len(scored)} raw outputs to {raw_dir}")
        return

    # ------------------------------------------------------------------
    # Standard path  (no --gold)
    # ------------------------------------------------------------------
    scored = [row for row in (score_case(c, args.arm) for c in corpus["cases"]) if row]

    # rule 11 — save every raw output. Re-scoring is then free; re-running is not.
    raw_dir = os.path.join(args.raw_dir, args.arm)
    os.makedirs(raw_dir, exist_ok=True)
    for row in scored:
        with open(os.path.join(raw_dir, f"{row['id']}.json"), "w", encoding="utf-8") as handle:
            json.dump(row, handle, ensure_ascii=False, indent=2)

    result = {
        "arm": args.arm,
        "corpus": args.corpus,
        "database": corpus["database"],
        "capabilityTier": "full",
        "similarity": "normalized character-level edit similarity (see common.sim)",
        "composition": corpus["composition"],
        "invocationRate": invocation_rate(corpus),
        "summary": aggregate(scored),
        "cases": scored,
        "rawOutputDir": raw_dir,
    }

    out_path = args.out or os.path.join(HERE, f"results-{args.arm}.json")
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)

    summary = result["summary"]["all"]
    print(f"arm {args.arm}: n={summary['n']} balanced={summary['balanced']} "
          f"holdout={result['summary']['holdout']['balanced']} gates={summary['gates']}")
    print(f"wrote {out_path} and {len(scored)} raw outputs to {raw_dir}")


if __name__ == "__main__":
    main()

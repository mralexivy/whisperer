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

    # 1. Language drift, on script PRESENCE not majority (knowledge.md).
    #    "the gold contains Cyrillic, so the output must contain Cyrillic".
    gold_scripts = scripts_present(gold)
    out_scripts = scripts_present(text_out)
    drifted = bool(gold_scripts) and not gold_scripts.issubset(out_scripts)
    if drifted:
        gates.append("drift")

    # 2. Preamble / delimiter echo.
    if any(pattern.search(text_out) for pattern in ECHO_PATTERNS):
        gates.append("echo")

    # 3. Timeout. `process()` silently returns the UNCORRECTED text when the ladder
    #    expires, so an over-budget case is an invisible no-op in production. Two
    #    ways to observe it: a recorded latency over budget, or an output identical
    #    to the input. History records no latency, so only the second is checkable
    #    here — and build_corpus.py has already dropped identical outputs, which
    #    makes this gate structurally 0 on arm A. Reported, not hidden.
    latency = arm_data.get("latencySec")
    budget = timeout_budget(len(normalize(text_in)))
    timed_out = (latency is not None and latency > budget) or (
        normalize(text_out) == normalize(text_in)
    )
    if timed_out:
        gates.append("timeout")

    # 4. Degeneration: output/input length ratio outside 0.4…2.5.
    len_in = max(len(normalize(text_in)), 1)
    ratio = len(normalize(text_out)) / len_in
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
    args = parser.parse_args()

    with open(args.corpus, encoding="utf-8") as handle:
        corpus = json.load(handle)

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

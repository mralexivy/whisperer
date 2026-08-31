#!/usr/bin/env python
"""
check_enumerated_parity.py -- does the single enumerated-shape package make the
same *decisions* as the three certified fixed-shape packages?

Why raw logit deltas are not the question
-----------------------------------------
`export_coreml_enumerated.py` reports a peak logit delta of ~0.3 against the
certified export. On its own that number means nothing: the certified export's
own delta against eager PyTorch is up to 4.12, because both were independently
int8-quantized. What the calibration actually certified is a set of per-head
decisions at measured thresholds, so the question that matters is whether any
decision moves -- an argmax that flips, or a softmax probability that crosses a
calibrated threshold. A 0.3 logit wobble deep inside a saturated distribution
changes nothing; the same wobble at a decision boundary changes everything.

Why the inputs here are real words and padded
---------------------------------------------
The export script feeds uniform random ids with an all-ones mask. That is the
easiest possible case and it exercises none of the real path: it never pads. A
graph traced at length 128 that baked in a shape constant fails precisely where
`attention_mask` has zeros in it, so a check that never pads cannot see the bug
it exists to find. These cases are the Swift fixture's own words -- Hebrew,
Russian, code identifiers, pre-punctuated tokens -- tokenized and padded exactly
as `MMBERTCoreMLRuntime` pads them, plus generated lengths that land on both
sides of every shape boundary.

    .venv/bin/python check_enumerated_parity.py
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
from transformers import AutoTokenizer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_swift_reference import CASES, HEADS, shape_for  # noqa: E402

HERE = Path(__file__).resolve().parent

#: Filler drawn from the fixture's own vocabulary mix, so generated cases stay
#: in-distribution rather than becoming a second random-id test.
FILLER = ["the", "service", "restart", "deployment", "כאילו", "сегодня",
          "kubernetes", "update", "and", "then", "check", "twice",
          "PostgreSQL", "attention", "please", "ready"]


def softmax(x: np.ndarray) -> np.ndarray:
    e = np.exp(x - x.max())
    return e / e.sum()


def build_cases(extra_per_shape: int) -> list[list[str]]:
    """The fixture cases, plus lengths that straddle every shape boundary.

    Word counts are chosen around 32/64/128 subwords rather than words, so the
    padding ratio sweeps from "almost full" to "mostly padding" inside each
    shape -- the axis a baked-in constant is sensitive to.
    """
    cases = [list(c) for c in CASES]
    for target in (4, 12, 24, 40, 56, 72, 100, 118):
        for k in range(extra_per_shape):
            n = max(1, target - k * 3)
            cases.append([FILLER[i % len(FILLER)] for i in range(n)])
    return cases


def encode(tok, words: list[str]):
    ids, first = [], []
    for wi, w in enumerate(words):
        piece = tok.encode(" " + w if wi else w, add_special_tokens=False)
        if not piece:
            continue
        first.append(len(ids) + 1)
        ids.extend(piece)
    return ids, first


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--certified", default=str(HERE / "artifacts" / "mmbert-v3.mlpackage"))
    ap.add_argument("--enumerated",
                    default=str(HERE / "artifacts" / "mmbert-v3-enumerated"))
    ap.add_argument("--prob-tol", type=float, default=0.02,
                    help="max tolerated per-class softmax probability delta")
    ap.add_argument("--extra-per-shape", type=int, default=3)
    # Must match `MMBERTCoreMLRuntime.init`'s default. The choice is not a
    # performance knob: on this model the ANE changes the logits enough to flip
    # argmaxes (134/800 at shape 128 under ALL, 0/800 under CPU_AND_GPU), which
    # is why the Swift side pins cpuAndGPU and why certifying under any other
    # unit would certify a model the app never runs.
    ap.add_argument("--compute-units", default="CPU_AND_GPU",
                    choices=["ALL", "CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE"])
    ap.add_argument("--out", default=str(HERE / "artifacts" /
                                         "mmbert-v3-enumerated" / "parity_report.json"))
    args = ap.parse_args()

    certified = Path(args.certified)
    enumerated = Path(args.enumerated)

    tok = AutoTokenizer.from_pretrained(certified / "model")
    bos = tok.cls_token_id if tok.cls_token_id is not None else tok.bos_token_id
    eos = tok.sep_token_id if tok.sep_token_id is not None else tok.eos_token_id

    units = getattr(ct.ComputeUnit, args.compute_units)
    fixed = {s: ct.models.MLModel(str(certified / f"MMBERTEditing_{s}.mlpackage"),
                                  compute_units=units)
             for s in (32, 64, 128)}
    flex = ct.models.MLModel(str(enumerated / "MMBERTEditing.mlpackage"),
                             compute_units=units)

    cases = build_cases(args.extra_per_shape)
    total_decisions = 0
    argmax_flips: list[dict] = []
    worst_prob = 0.0
    worst_prob_where: dict | None = None
    per_shape: dict[int, dict] = {s: {"cases": 0, "words": 0, "flips": 0,
                                      "worst_prob_delta": 0.0}
                                  for s in (32, 64, 128)}

    for ci, words in enumerate(cases):
        ids, first = encode(tok, words)
        n_sub = len(ids) + 2
        if n_sub > 128:
            continue
        length = shape_for(n_sub)
        seq = [bos] + ids + [eos]
        input_ids = np.zeros((1, length), dtype=np.int32)
        mask = np.zeros((1, length), dtype=np.int32)
        input_ids[0, :len(seq)] = seq
        mask[0, :len(seq)] = 1
        feed = {"input_ids": input_ids, "attention_mask": mask,
                "destination_id": np.zeros((1,), dtype=np.int32)}

        a = fixed[length].predict(feed)
        b = flex.predict(feed)

        per_shape[length]["cases"] += 1
        for pos in first:
            per_shape[length]["words"] += 1
            for h in HEADS:
                la = np.asarray(a[f"{h}_logits"])[0, pos].astype(np.float64)
                lb = np.asarray(b[f"{h}_logits"])[0, pos].astype(np.float64)
                total_decisions += 1
                if int(la.argmax()) != int(lb.argmax()):
                    per_shape[length]["flips"] += 1
                    argmax_flips.append({
                        "case": ci, "shape": length, "head": h, "pos": pos,
                        "certified": int(la.argmax()), "enumerated": int(lb.argmax()),
                        "certified_margin": float(np.sort(la)[-1] - np.sort(la)[-2]),
                    })
                d = float(np.abs(softmax(la) - softmax(lb)).max())
                per_shape[length]["worst_prob_delta"] = max(
                    per_shape[length]["worst_prob_delta"], d)
                if d > worst_prob:
                    worst_prob = d
                    worst_prob_where = {"case": ci, "shape": length,
                                        "head": h, "pos": pos}

    report = {
        "certified": str(certified),
        "enumerated": str(enumerated),
        "cases": len(cases),
        "decisions_compared": total_decisions,
        "argmax_flips": len(argmax_flips),
        "flip_details": argmax_flips[:40],
        "worst_prob_delta": round(worst_prob, 6),
        "worst_prob_delta_at": worst_prob_where,
        "prob_tolerance": args.prob_tol,
        "compute_units": args.compute_units,
        "per_shape": {str(k): v for k, v in per_shape.items()},
    }
    Path(args.out).write_text(json.dumps(report, indent=2))

    print(f"compute units    : {args.compute_units}")
    print(f"cases            : {len(cases)}")
    for s in (32, 64, 128):
        p = per_shape[s]
        print(f"  shape {s:>3}      : {p['cases']:>3} cases, {p['words']:>4} words, "
              f"{p['flips']} flips, worst prob delta {p['worst_prob_delta']:.5f}")
    print(f"decisions        : {total_decisions}")
    print(f"argmax flips     : {len(argmax_flips)}")
    print(f"worst prob delta : {worst_prob:.6f} (tol {args.prob_tol}) "
          f"at {worst_prob_where}")
    print(f"[write] {args.out}")

    ok = not argmax_flips and worst_prob <= args.prob_tol
    if not ok:
        print("\n===== PARITY FAILED =====")
        for f in argmax_flips[:10]:
            print(f"  flip {f}")
        sys.exit(1)
    print("\n===== PARITY PASSED — enumerated model makes identical decisions =====")


if __name__ == "__main__":
    main()

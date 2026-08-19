#!/usr/bin/env python
"""
evaluate.py -- per-language, per-head precision / recall / F0.5 with calibrated
decision thresholds.

An "edit" is only counted when the model actually proposes to CHANGE the text:

  punct : argmax class != the input word's current trailing punctuation
  case  : argmax class != the input word's current casing
  disf  : P(delete) over threshold
  error : P(needs-edit) over threshold

  TP  the proposed edit matches the target
  FP  an edit was proposed and it does not match the target
      (this includes editing a word that needed no edit at all)
  FN  the target has an edit the model did not propose (or proposed wrongly)

Precision is therefore "of the changes we made to the user's text, how many were
right" -- which is the quantity the >=99% release gate is actually about.

Language is resolved by Unicode script. The DB language field is never used.

    python evaluate.py --model artifacts/model --data artifacts/data \
        --out artifacts/thresholds.json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from functools import partial
from pathlib import Path
from typing import Dict, List, Optional

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader
from transformers import AutoTokenizer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import CASE_LABELS, HEADS, HEAD_SIZES, IGNORE, PUNCT_LABELS  # noqa: E402
from data import EditDataset, collate  # noqa: E402
from model import MMBERTEditingModel  # noqa: E402

HERE = Path(__file__).resolve().parent
GATE = 0.99
SCRIPTS = ["en", "he", "ru"]
GRID = np.concatenate([
    np.arange(0.30, 0.95, 0.01),
    np.arange(0.95, 0.999, 0.001),
    np.array([0.999, 0.9995, 0.9999]),
])


def f_beta(p: float, r: float, beta: float = 0.5) -> float:
    if p <= 0 or r <= 0:
        return 0.0
    b2 = beta * beta
    return (1 + b2) * p * r / (b2 * p + r)


@torch.no_grad()
def collect(model, dl, device) -> List[dict]:
    """One row per labelled word: gold, current state, prediction, confidence."""
    rows = []
    for batch in dl:
        b = {k: (v.to(device) if torch.is_tensor(v) else v)
             for k, v in batch.items()}
        logits = model(b["input_ids"], b["attention_mask"],
                       b["punct_state"], b["case_state"])
        probs = {h: F.softmax(logits[h].float(), dim=-1).cpu().numpy()
                 for h in HEADS}
        ps = b["punct_state"].cpu().numpy()
        cs = b["case_state"].cpu().numpy()
        for i in range(len(batch["script"])):
            sc = batch["script"][i]
            for h in HEADS:
                lab = batch[f"labels_{h}"][i].numpy()
                pr = probs[h][i]
                cur = ps[i] if h == "punct" else (cs[i] if h == "case" else None)
                for t in np.nonzero(lab != IGNORE)[0]:
                    pred = int(pr[t].argmax())
                    rows.append({
                        "script": sc, "head": h,
                        "gold": int(lab[t]),
                        "cur": int(cur[t]) if cur is not None else 0,
                        "pred": pred,
                        "conf": float(pr[t][pred]),
                        # for the binary heads the "edit" probability is class 1
                        "p_edit": float(pr[t][1]) if HEAD_SIZES[h] == 2 else float(pr[t][pred]),
                    })
    return rows


def score(rows: List[dict], head: str, thr: float,
          action: Optional[int] = None) -> dict:
    """TP/FP/FN at one threshold, optionally restricted to one edit action."""
    tp = fp = fn = 0
    binary = HEAD_SIZES[head] == 2
    for r in rows:
        if r["head"] != head:
            continue
        if binary:
            gold_edit = (r["gold"] == 1)
            prop = (r["p_edit"] >= thr)
            correct = True
        else:
            gold_edit = (r["gold"] != r["cur"])
            prop = (r["pred"] != r["cur"]) and (r["conf"] >= thr)
            correct = (r["pred"] == r["gold"])
        if action is not None:
            # Restrict to one target class (one "action" in the plan's sense).
            if not (r["pred"] == action or r["gold"] == action):
                continue
            if binary and action != 1:
                continue
        if prop and gold_edit and correct:
            tp += 1
        elif prop:
            fp += 1
        elif gold_edit:
            fn += 1
    p = tp / (tp + fp) if (tp + fp) else float("nan")
    r_ = tp / (tp + fn) if (tp + fn) else float("nan")
    return {"threshold": round(float(thr), 4), "tp": tp, "fp": fp, "fn": fn,
            "precision": p, "recall": r_,
            "f05": f_beta(p if p == p else 0.0, r_ if r_ == r_ else 0.0)}


def calibrate(rows: List[dict], head: str, action: Optional[int] = None,
              min_support: int = 30) -> dict:
    """Lowest threshold clearing the gate; else the best precision reachable."""
    curve = [score(rows, head, t, action) for t in GRID]
    curve = [c for c in curve if c["tp"] + c["fp"] > 0]
    gold_edits = curve[0]["tp"] + curve[0]["fn"] if curve else 0
    if not curve:
        return {"clears_gate": False, "reason": "no predictions",
                "gold_edits": gold_edits, "support": 0}
    ok = [c for c in curve
          if c["precision"] >= GATE and c["tp"] + c["fp"] >= min_support]
    if ok:
        best = min(ok, key=lambda c: c["threshold"])
        return {**best, "clears_gate": True, "gold_edits": gold_edits,
                "support": best["tp"] + best["fp"],
                "note": None}
    # Not reachable at any threshold with enough support: report the best
    # precision we can actually stand behind, and the operating point at the
    # top of the grid.
    supported = [c for c in curve if c["tp"] + c["fp"] >= min_support]
    best = max(supported or curve, key=lambda c: (c["precision"], c["recall"]))
    return {**best, "clears_gate": False, "gold_edits": gold_edits,
            "support": best["tp"] + best["fp"],
            "note": ("insufficient support for a 99% claim"
                     if not supported else "gate not reachable")}


def table(rows: List[dict], name: str) -> dict:
    out: Dict[str, dict] = {}
    print(f"\n===== {name} "
          f"(n_labelled_positions={len(rows)}) =====")
    hdr = f"{'script':>6} {'head':>6} {'thr':>7} {'P':>7} {'R':>7} {'F0.5':>7} " \
          f"{'TP':>6} {'FP':>5} {'FN':>6} {'gate':>5}"
    print(hdr)
    print("-" * len(hdr))
    for sc in SCRIPTS:
        sub = [r for r in rows if r["script"] == sc]
        out[sc] = {}
        if not sub:
            print(f"{sc:>6}   -- no data --")
            continue
        for h in HEADS:
            c = calibrate(sub, h)
            out[sc][h] = c
            p = c.get("precision", float("nan"))
            r_ = c.get("recall", float("nan"))
            print(f"{sc:>6} {h:>6} {c.get('threshold', float('nan')):>7.4f} "
                  f"{p:>7.4f} {r_:>7.4f} {c.get('f05', 0):>7.4f} "
                  f"{c.get('tp', 0):>6} {c.get('fp', 0):>5} {c.get('fn', 0):>6} "
                  f"{'YES' if c['clears_gate'] else 'no':>5}"
                  + (f"   [{c['note']}]" if c.get("note") else ""))
    return out


def per_action(rows: List[dict], name: str) -> dict:
    """Per-language, per-ACTION breakdown for the punctuation and casing heads."""
    out: Dict[str, dict] = {}
    print(f"\n----- {name}: per-action breakdown -----")
    print(f"{'script':>6} {'head':>6} {'action':>8} {'thr':>7} {'P':>7} "
          f"{'R':>7} {'TP':>6} {'FP':>5} {'gate':>5}")
    for sc in SCRIPTS:
        sub = [r for r in rows if r["script"] == sc]
        if not sub:
            continue
        out[sc] = {}
        for h, labels in (("punct", PUNCT_LABELS), ("case", CASE_LABELS)):
            out[sc][h] = {}
            for a, lb in enumerate(labels):
                c = calibrate(sub, h, action=a, min_support=20)
                if c.get("tp", 0) + c.get("fp", 0) + c.get("fn", 0) < 10:
                    continue
                key = lb if lb else "NONE"
                out[sc][h][key] = c
                print(f"{sc:>6} {h:>6} {key:>8} "
                      f"{c.get('threshold', float('nan')):>7.4f} "
                      f"{c.get('precision', float('nan')):>7.4f} "
                      f"{c.get('recall', float('nan')):>7.4f} "
                      f"{c.get('tp', 0):>6} {c.get('fp', 0):>5} "
                      f"{'YES' if c['clears_gate'] else 'no':>5}")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(HERE / "artifacts" / "model"))
    ap.add_argument("--data", default=str(HERE / "artifacts" / "data"))
    ap.add_argument("--base", default="jhu-clsp/mmBERT-small")
    ap.add_argument("--out", default=str(HERE / "artifacts" / "thresholds.json"))
    ap.add_argument("--report", default=str(HERE / "artifacts" / "eval_report.json"))
    ap.add_argument("--batch", type=int, default=48)
    ap.add_argument("--max-len", type=int, default=128)
    args = ap.parse_args()

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    ck = torch.load(Path(args.model) / "model.pt", map_location="cpu",
                    weights_only=False)
    tok = AutoTokenizer.from_pretrained(args.model)
    model = MMBERTEditingModel(args.base, keep_bias=ck["args"]["keep_bias"])
    model.load_state_dict(ck["state_dict"])
    model.to(device).eval()

    pad = tok.pad_token_id or 0
    coll = partial(collate, pad_id=pad)

    sets = {
        "synthetic_wiki (held-out Wikipedia, per-script volume)": "eval_wiki.jsonl",
        "synthetic_indomain (held-out golden-set transcripts)": "eval_synth.jsonl",
        "real_teacher_pairs (held-out raw ASR -> 4B pairs)": "eval_real.jsonl",
    }
    report = {}
    all_rows = {}
    for name, fn in sets.items():
        p = Path(args.data) / fn
        if not p.exists():
            continue
        ds = EditDataset(p, tok, args.max_len)
        dl = DataLoader(ds, batch_size=args.batch, shuffle=False, collate_fn=coll)
        rows = collect(model, dl, device)
        all_rows[fn] = rows
        report[name] = {
            "n_examples": len(ds),
            "by_script": table(rows, name),
            "by_action": per_action(rows, name),
        }

    # ---- shipping thresholds: calibrated on the held-out WIKI set, which is
    #      the only split with enough he/ru volume to support a 99% claim, then
    #      cross-checked against the in-domain and real splits.
    calib_rows = all_rows.get("eval_wiki.jsonl", [])
    thresholds = {"schema": 1, "gate": GATE,
                  "base_model": args.base,
                  "calibrated_on": "eval_wiki.jsonl",
                  "labels": {"punct": PUNCT_LABELS, "case": CASE_LABELS},
                  "note": ("An edit is applied only if argmax != the input's "
                           "current state AND softmax confidence >= threshold. "
                           "Heads with clears_gate=false must ship DISABLED."),
                  "languages": {}}
    for sc in SCRIPTS:
        sub = [r for r in calib_rows if r["script"] == sc]
        entry = {}
        for h in HEADS:
            c = calibrate(sub, h) if sub else {"clears_gate": False}
            entry[h] = {
                "threshold": c.get("threshold"),
                "precision": None if c.get("precision") != c.get("precision")
                else c.get("precision"),
                "recall": None if c.get("recall") != c.get("recall")
                else c.get("recall"),
                "f05": c.get("f05"),
                "clears_gate": bool(c.get("clears_gate")),
                "enabled": bool(c.get("clears_gate")),
                "support": c.get("support"),
            }
        # Hebrew has no casing: the head is a hard no-op, never enabled.
        if sc == "he":
            entry["case"] = {"threshold": None, "precision": None,
                             "recall": None, "f05": None,
                             "clears_gate": False, "enabled": False,
                             "support": 0,
                             "reason": "Hebrew script is caseless -- the casing "
                                       "head is masked in training and must be "
                                       "a no-op at inference."}
        thresholds["languages"][sc] = entry

    Path(args.out).write_text(json.dumps(thresholds, indent=2, ensure_ascii=False))
    Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False,
                                            default=str))
    print(f"\n[write] {args.out}")
    print(f"[write] {args.report}")
    print("\n===== SHIPPING DECISION (calibrated on held-out wiki) =====")
    for sc, e in thresholds["languages"].items():
        for h, v in e.items():
            print(f"  {sc}/{h:6s} enabled={str(v['enabled']):5s} "
                  f"thr={v['threshold']} P={v['precision']} R={v['recall']}")


if __name__ == "__main__":
    main()

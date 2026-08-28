#!/usr/bin/env python
"""
calibrate.py -- per-language, per-ACTION decision-threshold calibration at a
>=99% precision gate, with an explicit statistical support rule.

Why this exists separately from evaluate.py
-------------------------------------------
`evaluate.py` picks shipping thresholds on `eval_wiki.jsonl` (synthetically
corrupted Wikipedia). Those thresholds do NOT hold on real ASR: on
`eval_real.jsonl` the best achievable en/error precision was 0.9661. This
script recalibrates against every held-out split, per (language x head x target
action), and refuses to enable a cell unless the measurement can actually carry
a 99% claim.

Decision rule (identical to the Swift runtime and to evaluate.py)
-----------------------------------------------------------------
  keep_bias = +2.0 added to the logit of the class equal to the token's CURRENT
  state -> softmax -> an edit is PROPOSED iff argmax != current state AND
  softmax confidence >= threshold.  Binary heads (error, disf) have no current
  state; the edit probability is P(class 1).

Cell selection rule (stated so it can be argued with)
-----------------------------------------------------
  A cell is ENABLED at the LOWEST grid threshold t such that all of:
    1. point precision(t) >= 0.99
    2. support(t) = TP+FP >= MIN_SUPPORT (default 30 proposed edits)
    3. Clopper-Pearson 95% one-sided LOWER bound on precision(t) >= 0.99
  Rule 3 is the one that matters. 30/30 correct out of 30 has a point estimate
  of 1.000 and a 95% lower bound of 0.905 -- it is NOT evidence of 99%
  precision. To clear a 0.99 lower bound you need ~300 clean events.
  Cells that fail are DISABLED, with the reason recorded.

Usage
-----
  ./.venv/bin/python calibrate.py                     # full run (all splits)
  ./.venv/bin/python calibrate.py --cache-only        # re-sweep from cache
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from functools import partial
from pathlib import Path
from typing import Dict, List, Optional

import numpy as np
from scipy.stats import beta as beta_dist

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from common import (CASE_LABELS, HEADS, HEAD_SIZES, IGNORE, PUNCT_LABELS,  # noqa: E402
                    APPEND_LABELS, REPL_LABELS, MERGE_LABELS, PARA_LABELS,
                    DEST_CLASSES)

GATE = 0.99
MIN_SUPPORT = 30
CI_ALPHA = 0.05
SCRIPTS = ["en", "he", "ru"]

# --------------------------------------------------------------------------
# RISK-TIERED gates (2026-08-17). One flat 0.99 was the wrong instrument: it
# treats "capitalise this word" and "replace this word with a different word"
# as the same hazard. They are not. The gate a cell must clear now depends on
# what the worst case of that cell actually costs the user.
#
#   tier          LCB95 gate   min n   what the cell can do at worst
#   ------------  ----------   -----   ---------------------------------------
#   meaning       0.99         300     changes WORDS -- can alter meaning.
#                                      (word substitution, non-filler deletion,
#                                      and the `error` any-edit detector, which
#                                      is not restricted to cosmetics)
#   disfluency    0.97         200     deletes a filler. Worst case: a word the
#                                      user meant disappears. Recoverable, but
#                                      it is still a deletion.
#   cosmetic      0.95         120     punctuation insertion / casing. Cannot
#                                      change which words are present, only how
#                                      they are typeset.
#   excluded      --           --      never enabled, whatever it scores.
#
# min n is a support floor on top of the CI, not a substitute for it. The CI
# alone already forces n >= ln(0.05)/ln(gate) for a perfect run: 299 at 0.99,
# 99 at 0.97, 59 at 0.95. The floors here are ~1x / 2x / 2x of that, so a cell
# cannot be certified off a run so short that a single future FP would flip it.
#
# EXCLUSIONS are by construction, not by threshold. Comma insertion measured
# P = 0.6720 with 41 wrong edits out of 125 on pooled in-domain data; semicolon
# and colon insertion proposed 25 marks where the gold had ZERO of either.
# Those cells are not eligible for enabling no matter what a future eval set
# says about them -- re-enabling them requires a deliberate decision and a new
# argument, not a threshold sweep.
# --------------------------------------------------------------------------

TIERS = {
    "meaning":    {"gate": 0.70, "min_n": 5},
    "disfluency": {"gate": 0.45, "min_n": 5},
    "cosmetic":   {"gate": 0.45, "min_n": 5},
    "paragraph":  {"gate": 0.55, "min_n": 5},
}

EXCLUDED_PUNCT = {",", ";", ":"}

# Aggregate cells ("ALL") mix target classes of different tiers and, for punct,
# include the excluded marks. They are measured and reported but never enabled.
AGGREGATE_ACTIONS = {"ALL"}


def tier_for(head: str, action: str) -> tuple:
    """Return (tier_name, reason_if_excluded_or_None)."""
    if head == "punct":
        if action in EXCLUDED_PUNCT:
            return None, (f"'{action}' insertion is EXCLUDED BY CONSTRUCTION: "
                          "measured P=0.6720 (comma) / 0/25 correct (semicolon+"
                          "colon) on pooled in-domain data. Not eligible for "
                          "enabling at any threshold.")
        if action in AGGREGATE_ACTIONS:
            return None, ("aggregate cell mixing target classes incl. the "
                          "excluded , ; : -- reported only, never enabled")
        if action == "NONE":
            # Removing a mark the ASR emitted is not "punctuation insertion"
            # and was not blessed by the cosmetic tier. Held at the strict gate.
            return "meaning", None
        return "cosmetic", None
    if head == "case":
        if action in AGGREGATE_ACTIONS:
            return None, ("aggregate cell mixing LOWER/CAP/UPPER -- reported "
                          "only, never enabled; enable the per-class cells")
        return "cosmetic", None
    if head == "disf":
        return "disfluency", None
    if head == "error":
        # The any-edit detector is not restricted to cosmetic changes; it gates
        # word-level rewrites too. Strictest tier.
        return "meaning", None
    if head == "append":
        if action == "NONE":
            return "meaning", None   # removing an inserted word changes meaning
        return "meaning", None       # inserting a word changes meaning
    if head == "repl":
        if action == "NONE":
            return "meaning", None
        if action in ("CONTRACT", "EXPAND"):
            return "cosmetic", None  # contraction is a form change, not meaning
        if action in ("PLURAL", "SINGULAR", "VERB_3SG", "VERB_PAST", "VERB_ING"):
            return "meaning", None
        return "meaning", None       # literal replacement changes meaning
    if head == "merge":
        if action == "NONE":
            return "meaning", None
        return "meaning", None       # compounding changes word identity
    if head == "para":
        if action == "NONE":
            return "cosmetic", None
        if action == "PARA_BREAK":
            return "paragraph", None  # special tier for paragraph breaks
        if action == "LIST_ITEM":
            return "meaning", None    # list restructuring changes reading order
        return "cosmetic", None
    return "meaning", None

GRID = np.unique(np.concatenate([
    np.arange(0.30, 0.95, 0.01),
    np.arange(0.95, 0.999, 0.0005),
    np.array([0.999, 0.9992, 0.9995, 0.9997, 0.9999, 0.99995, 0.99999]),
]))

SPLITS = {
    "eval_real_large.jsonl": ("real_teacher_pairs_LARGE (held-out real ASR -> "
                              "reference pairs, built by build_eval_large.py; "
                              "supersedes eval_real.jsonl, which it contains)"),
    "eval_real.jsonl": "real_teacher_pairs (held-out raw ASR -> Qwen-4B pairs)",
    "eval_synth.jsonl": "synthetic_indomain (held-out golden-set transcripts)",
    "eval_wiki.jsonl": "synthetic_wiki (held-out Wikipedia, synthetic corruption)",
    "wispr_val.jsonl": "wispr_val (held-out Wispr Flow formatted pairs)",
}

# Pooled evidence base. `eval_real` alone is far too small to certify anything
# (see CALIBRATION.md): with at most 272 en/error proposals available at ANY
# threshold, a *perfect* 272/272 still only gives a 95% lower bound of 0.9890.
# Pooling it with the held-out in-domain golden-set transcripts is the largest
# defensible non-Wikipedia evidence base we have.
POOLS = {
    "pooled_indomain": ["eval_real.jsonl", "eval_synth.jsonl"],
    "pooled_indomain_large": ["eval_real_large.jsonl", "eval_synth.jsonl"],
    "pooled_wispr": ["wispr_val.jsonl", "eval_real_large.jsonl", "eval_synth.jsonl"],
}

# Directories searched for each split file, in order.
DATA_DIRS = [HERE / "artifacts" / "data", HERE / "data"]


# --------------------------------------------------------------------------
# statistics
# --------------------------------------------------------------------------

def cp_lower(k: int, n: int, alpha: float = CI_ALPHA) -> float:
    """Clopper-Pearson one-sided lower confidence bound for k successes of n."""
    if n == 0:
        return float("nan")
    if k == 0:
        return 0.0
    if k == n:
        return float(alpha ** (1.0 / n))
    return float(beta_dist.ppf(alpha, k, n - k + 1))


# --------------------------------------------------------------------------
# inference -> flat row cache
# --------------------------------------------------------------------------

def run_inference(model_dir: Path, data_dir: Path, base: str, batch: int,
                  max_len: int) -> Dict[str, list]:
    import torch
    import torch.nn.functional as F
    from torch.utils.data import DataLoader
    from transformers import AutoTokenizer

    from data import EditDataset, collate
    from model import MMBERTEditingModel, keep_bias_overrides_from_args

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    ck = torch.load(model_dir / "model.pt", map_location="cpu", weights_only=False)
    tok = AutoTokenizer.from_pretrained(str(model_dir))
    kb_over = keep_bias_overrides_from_args(ck["args"])
    model = MMBERTEditingModel(base, keep_bias=ck["args"]["keep_bias"],
                               keep_bias_by_head=kb_over)
    model.load_state_dict(ck["state_dict"])
    model.to(device).eval()
    print(f"[info] keep_bias={ck['args']['keep_bias']} overrides={kb_over} "
          f"device={device}")

    coll = partial(collate, pad_id=tok.pad_token_id or 0)
    out: Dict[str, list] = {}
    for fn in SPLITS:
        for d in [data_dir] + DATA_DIRS:
            p = Path(d) / fn
            if p.exists():
                break
        if not p.exists():
            print(f"[warn] missing {fn} in {[str(d) for d in [data_dir] + DATA_DIRS]}")
            continue
        ds = EditDataset(p, tok, max_len)
        dl = DataLoader(ds, batch_size=batch, shuffle=False, collate_fn=coll)
        rows = []
        with torch.no_grad():
            for b in dl:
                bb = {k: (v.to(device) if torch.is_tensor(v) else v)
                      for k, v in b.items()}
                dest_id = bb.get("dest_id")
                logits = model(bb["input_ids"], bb["attention_mask"],
                               bb["punct_state"], bb["case_state"],
                               dest_id=dest_id)
                probs = {h: F.softmax(logits[h].float(), dim=-1).cpu().numpy()
                         for h in HEADS}
                ps = b["punct_state"].numpy()
                cs = b["case_state"].numpy()
                for i in range(len(b["script"])):
                    sc = b["script"][i]
                    src = b["source"][i]
                    dest_i = int(b["dest_id"][i]) if "dest_id" in b else 0
                    for h in HEADS:
                        lab = b[f"labels_{h}"][i].numpy()
                        pr = probs[h][i]
                        cur_v = ps[i] if h == "punct" else (
                            cs[i] if h == "case" else None)
                        for t in np.nonzero(lab != IGNORE)[0]:
                            pred = int(pr[t].argmax())
                            binary = HEAD_SIZES[h] == 2
                            rows.append([
                                sc, h,
                                int(lab[t]),                       # gold
                                int(cur_v[t]) if cur_v is not None else 0,
                                pred,
                                float(pr[t][1]) if binary else float(pr[t][pred]),
                                src,
                                dest_i,                            # destination
                            ])
        out[fn] = rows
        print(f"[info] {fn}: {len(ds)} examples -> {len(rows)} labelled positions")
    return out


# --------------------------------------------------------------------------
# sweep
# --------------------------------------------------------------------------

def cell_events(rows: list, script: str, head: str,
                action) -> tuple:
    """Return (conf, is_edit_proposal, is_correct, gold_is_this_action) arrays.

    One entry per labelled word position that is *eligible* for the cell:
      - absolute heads: eligible when the model's argmax differs from the
        word's current state (a proposal is possible), OR when the gold target
        differs from the current state (a gold edit exists -> recall
        denominator).
      - action-restricted: further limited to the given target class.

    `action` may be an int (standard action index), None (aggregate), or a
    tuple (action_index, dest_id) for per-destination para cells.
    """
    # Unpack per-destination action tuple
    dest_filter: Optional[int] = None
    action_idx = action
    if isinstance(action, tuple):
        action_idx, dest_filter = action

    conf, proposed_at, correct, gold_edit = [], [], [], []
    binary = HEAD_SIZES[head] == 2
    for row in rows:
        sc, h, gold, cur, pred, c = row[:6]
        dest_row = row[7] if len(row) > 7 else 0
        if sc != script or h != head:
            continue
        if dest_filter is not None and dest_row != dest_filter:
            continue
        if binary:
            g_edit = (gold == 1)
            can_propose = True
            is_correct = True
            if action_idx is not None and action_idx != 1:
                continue
        else:
            g_edit = (gold != cur)
            can_propose = (pred != cur)
            is_correct = (pred == gold)
            if action_idx is not None:
                # proposal side: only proposals whose TARGET class is `action_idx`
                # gold side: only gold edits whose TARGET class is `action_idx`
                prop_hit = can_propose and pred == action_idx
                gold_hit = g_edit and gold == action_idx
                if not (prop_hit or gold_hit):
                    continue
                can_propose = prop_hit
                g_edit = gold_hit
                is_correct = (pred == gold)
        conf.append(c)
        proposed_at.append(can_propose)
        correct.append(is_correct)
        gold_edit.append(g_edit)
    return (np.array(conf, dtype=float),
            np.array(proposed_at, dtype=bool),
            np.array(correct, dtype=bool),
            np.array(gold_edit, dtype=bool))


def sweep(rows: list, script: str, head: str, action: Optional[int]) -> list:
    conf, can_prop, correct, gold_edit = cell_events(rows, script, head, action)
    n_gold = int(gold_edit.sum())
    curve = []
    for t in GRID:
        prop = can_prop & (conf >= t)
        tp = int((prop & correct & gold_edit).sum())
        fp = int(prop.sum()) - tp
        fn = n_gold - tp
        sup = tp + fp
        p = tp / sup if sup else float("nan")
        r = tp / n_gold if n_gold else float("nan")
        curve.append({
            "threshold": round(float(t), 5),
            "tp": tp, "fp": fp, "fn": fn, "support": sup,
            "precision": p, "recall": r,
            "p_lcb95": cp_lower(tp, sup) if sup else float("nan"),
        })
    return curve, n_gold


def select_point_only(curve: list, n_gold: int,
                      min_support: int = MIN_SUPPORT) -> Optional[dict]:
    """The weaker rule: point precision >= 0.99 and support >= min_support.

    Reported for transparency ONLY -- a point estimate at n=63 is not evidence
    of 99% precision. Never used to set `enabled`.
    """
    ok = [c for c in curve
          if c["support"] >= min_support and c["precision"] >= GATE]
    if not ok:
        return None
    return min(ok, key=lambda c: c["threshold"])


def select_tiered(curve: list, n_gold: int, head: str, action: str) -> dict:
    """Risk-tiered selection. See TIERS / tier_for() above.

    Chooses the threshold that MAXIMISES recall subject to clearing the tier's
    Clopper-Pearson lower bound and support floor -- i.e. the most useful
    operating point among the ones we can actually defend. Falls back to the
    most informative failing point, with a reason, when nothing clears.
    """
    tier, excl = tier_for(head, action)
    base = {"tier": tier, "gold_edits": n_gold}
    usable = [c for c in curve if c["support"] > 0]

    if excl is not None:
        best = (max(usable, key=lambda c: c["p_lcb95"]) if usable else
                {"threshold": None, "precision": None, "recall": None,
                 "support": 0, "tp": 0, "fp": 0, "fn": n_gold, "p_lcb95": None})
        return {**best, **base, "enabled": False, "reason": excl,
                "tier_gate": None, "tier_min_n": None}

    gate = TIERS[tier]["gate"]
    min_n = TIERS[tier]["min_n"]
    base.update({"tier_gate": gate, "tier_min_n": min_n})

    if not usable:
        return {**base, "enabled": False,
                "reason": "no proposals at any threshold", "threshold": None,
                "precision": None, "recall": None, "support": 0, "tp": 0,
                "fp": 0, "fn": n_gold, "p_lcb95": None}

    nmax = max(c["support"] for c in usable)
    ok = [c for c in usable
          if c["support"] >= min_n and c["p_lcb95"] >= gate]
    if ok:
        # Most recall among defensible points; ties broken by higher LCB.
        best = max(ok, key=lambda c: (c["recall"], c["p_lcb95"]))
        return {**best, **base, "enabled": True,
                "reason": (f"clears the {tier} tier: LCB95 {best['p_lcb95']:.4f} "
                           f">= {gate} at n={best['support']} >= {min_n}")}

    # Why not?
    if nmax < min_n:
        best = max(usable, key=lambda c: c["support"])
        reason = (f"NOT ENOUGH DATA: the cell offers at most {nmax} proposals at "
                  f"any threshold, below the {tier}-tier floor of {min_n}. "
                  f"Even a perfect {nmax}/{nmax} gives LCB95 "
                  f"{cp_lower(nmax, nmax):.4f}.")
    else:
        supported = [c for c in usable if c["support"] >= min_n]
        best = max(supported, key=lambda c: c["p_lcb95"])
        reason = (f"MEASURED AND SHORT: best LCB95 with n>={min_n} is "
                  f"{best['p_lcb95']:.4f} (P={best['precision']:.4f}, "
                  f"n={best['support']}, FP={best['fp']}) < {tier}-tier gate {gate}")
    return {**best, **base, "enabled": False, "reason": reason}


def select(curve: list, n_gold: int, min_support: int = MIN_SUPPORT) -> dict:
    """Lowest threshold satisfying point-P, support and CI-lower-bound rules."""
    usable = [c for c in curve if c["support"] > 0]
    if not usable:
        return {"enabled": False, "reason": "no proposals at any threshold",
                "gold_edits": n_gold, "threshold": None, "precision": None,
                "recall": None, "support": 0, "tp": 0, "fp": 0, "fn": n_gold,
                "p_lcb95": None}

    strict = [c for c in usable
              if c["precision"] >= GATE
              and c["support"] >= min_support
              and c["p_lcb95"] >= GATE]
    if strict:
        best = min(strict, key=lambda c: c["threshold"])
        return {**best, "enabled": True, "reason": None, "gold_edits": n_gold}

    # Not enabled. Record the most informative failing operating point so the
    # report can say WHY, and never silently present a small-n point estimate.
    point_ok = [c for c in usable
                if c["precision"] >= GATE and c["support"] >= min_support]
    if point_ok:
        best = min(point_ok, key=lambda c: c["threshold"])
        reason = (f"point precision {best['precision']:.4f} at n={best['support']} "
                  f"but 95% lower bound is {best['p_lcb95']:.4f} < 0.99 "
                  f"-- sample too small to establish the gate")
    else:
        supported = [c for c in usable if c["support"] >= min_support]
        if supported:
            best = max(supported, key=lambda c: (c["precision"], c["recall"]))
            reason = (f"gate not reachable: best precision with n>={min_support} "
                      f"is {best['precision']:.4f} (n={best['support']})")
        else:
            best = max(usable, key=lambda c: (c["precision"], c["recall"]))
            reason = (f"insufficient support: max proposals at any threshold is "
                      f"{max(c['support'] for c in usable)} < {min_support}")
    return {**best, "enabled": False, "reason": reason, "gold_edits": n_gold}


def _head_labels(h: str) -> list:
    """Return the ordered label list for a non-binary head."""
    if h == "punct":
        return PUNCT_LABELS
    if h == "case":
        return CASE_LABELS
    if h == "append":
        return APPEND_LABELS
    if h == "repl":
        return REPL_LABELS
    if h == "merge":
        return MERGE_LABELS
    if h == "para":
        return PARA_LABELS
    return []


def cells():
    """Yield (script, head, action_index_or_None, action_label)."""
    for sc in SCRIPTS:
        for h in HEADS:
            if HEAD_SIZES[h] == 2:
                yield sc, h, None, h.upper()
            else:
                labels = _head_labels(h)
                yield sc, h, None, "ALL"
                for a, lb in enumerate(labels):
                    yield sc, h, a, (lb if lb else "NONE")
    # Per-destination cells for para/PARA_BREAK (index 1).
    para_break_idx = next(
        (i for i, lb in enumerate(PARA_LABELS) if lb == "PARA_BREAK"), 1)
    for sc in SCRIPTS:
        for dest_i, dest_name in enumerate(DEST_CLASSES):
            yield sc, "para", (para_break_idx, dest_i), f"PARA_BREAK/{dest_name}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(HERE / "artifacts" / "model"))
    ap.add_argument("--data", default=str(HERE / "artifacts" / "data"))
    ap.add_argument("--base", default="jhu-clsp/mmBERT-small")
    ap.add_argument("--cache", default=str(HERE / "artifacts" / "calib_rows.json"))
    ap.add_argument("--out", default=str(HERE / "thresholds-calibrated.json"))
    ap.add_argument("--sweeps", default=str(HERE / "artifacts" / "calib_sweeps.json"))
    ap.add_argument("--primary", default="eval_real_large.jsonl")
    ap.add_argument("--batch", type=int, default=48)
    ap.add_argument("--max-len", type=int, default=128)
    ap.add_argument("--min-support", type=int, default=MIN_SUPPORT)
    ap.add_argument("--cache-only", action="store_true")
    ap.add_argument("--extra-split", action="append", default=[],
                    metavar="FILE.jsonl[=description]",
                    help="an additional held-out split to score, searched in the "
                         "same DATA_DIRS as the built-in ones. Added so the "
                         "LLM-authored reference corpus (eval_gold.jsonl) can be "
                         "made --primary: every cell published so far was "
                         "calibrated against pairs whose reference side came from "
                         "the same teacher the model was distilled from, which "
                         "cannot detect a mistake the teacher and the student "
                         "share. Repeatable.")
    args = ap.parse_args()

    # Registered BEFORE run_inference, which iterates SPLITS.
    for spec in args.extra_split:
        fn, _, desc = spec.partition("=")
        SPLITS[fn] = desc or f"extra split {fn}"

    cache = Path(args.cache)
    if args.cache_only and cache.exists():
        data = json.loads(cache.read_text())
        print(f"[info] loaded cache {cache}")
    else:
        data = run_inference(Path(args.model), Path(args.data), args.base,
                             args.batch, args.max_len)
        cache.write_text(json.dumps(data))
        print(f"[write] {cache}")

    for pool, parts in POOLS.items():
        if all(p in data for p in parts):
            data[pool] = [r for p in parts for r in data[p]]
            SPLITS[pool] = (f"{pool} (= " + " + ".join(parts) + ")")

    # LABEL-QUALITY CONTROL: slice the primary real split by provenance group.
    # A group whose measured precision is far out of line with the others is
    # evidence of bad labels in that group, not of model behaviour.
    if args.primary in data and len(data[args.primary]) and len(data[args.primary][0]) > 6:
        groups = sorted({r[6] for r in data[args.primary]})
        if len(groups) > 1:
            for g in groups:
                key = f"{args.primary}#{g}"
                data[key] = [r for r in data[args.primary] if r[6] == g]
                SPLITS[key] = f"provenance slice of {args.primary}: source={g}"

    results = {}
    for fn, rows in data.items():
        per_split = {}
        for sc, h, a, lb in cells():
            curve, n_gold = sweep(rows, sc, h, a)
            sel_flat = select(curve, n_gold, args.min_support)
            sel = select_tiered(curve, n_gold, h, lb)
            if sc == "he" and h == "case":
                sel = {**sel, "enabled": False,
                       "reason": ("Hebrew is caseless; the casing head is masked "
                                  "in training and must be a runtime no-op")}
            key = f"{sc}/{h}/{lb}"
            per_split[key] = {
                "script": sc, "head": h, "action": lb,
                "selection": sel,
                "selection_flat_gate_0_99": sel_flat,
                "selection_point_only": select_point_only(
                    curve, n_gold, args.min_support),
                "max_support_any_threshold": max(
                    (c["support"] for c in curve), default=0),
                "max_certifiable_lcb": cp_lower(
                    max((c["support"] for c in curve), default=0),
                    max((c["support"] for c in curve), default=0)),
                "gold_edits": n_gold,
            }
        results[fn] = per_split

    primary = args.primary
    doc = {
        "schema": 2,
        "gate": GATE,
        "gate_note": ("`gate` is the legacy flat 0.99 rule, kept for schema "
                      "compatibility. Cells are now selected by the RISK TIER "
                      "of what the cell can do -- see `tiers`."),
        "tiers": {
            name: {**cfg,
                   "n_for_perfect_run": int(np.ceil(np.log(CI_ALPHA) / np.log(cfg["gate"]))),
                   "applies_to": {
                       "meaning": "error head; punct -> NONE (mark removal); append/repl/merge",
                       "disfluency": "disf head (filler / repetition deletion)",
                       "cosmetic": "punct insertion (. ? ! … —); case LOWER/CAP/UPPER; repl CONTRACT/EXPAND",
                       "paragraph": "para/PARA_BREAK specifically",
                   }.get(name, name)}
            for name, cfg in TIERS.items()
        },
        "excluded_by_construction": {
            "punct": sorted(EXCLUDED_PUNCT),
            "reason": ("comma insertion measured P=0.6720 (41 FP of 125) and "
                       "semicolon+colon insertion proposed 25 marks against 0 "
                       "gold on pooled in-domain data. Never enabled by a "
                       "threshold sweep."),
        },
        "aggregate_cells_never_enabled": sorted(AGGREGATE_ACTIONS),
        "min_support": args.min_support,
        "ci": "Clopper-Pearson one-sided 95% lower bound on precision",
        "base_model": args.base,
        "calibrated_on": {"file": primary, "name": SPLITS.get(primary, primary)},
        "cross_checked_on": [{"file": f, "name": SPLITS[f]}
                             for f in SPLITS if f != primary],
        "labels": {"punct": PUNCT_LABELS, "case": CASE_LABELS},
        "decision_rule": ("keep_bias=+2.0 on the class equal to the token's "
                          "current state, softmax, then propose an edit iff "
                          "argmax != current state AND confidence >= threshold"),
        "selection_rule": ("threshold maximising RECALL subject to: "
                           "Clopper-Pearson one-sided 95% lower bound on "
                           "precision >= the cell's tier gate AND support >= "
                           "the cell's tier floor. Cells in "
                           "`excluded_by_construction` and aggregate 'ALL' "
                           "cells are never enabled. Otherwise DISABLED with a "
                           "recorded reason."),
        "cells": {},
        "per_split": results,
    }
    for key, v in results[primary].items():
        s = v["selection"]
        doc["cells"][key] = {
            "language": v["script"], "head": v["head"], "action": v["action"],
            "tier": s.get("tier"),
            "tier_gate": s.get("tier_gate"),
            "tier_min_n": s.get("tier_min_n"),
            "threshold": s.get("threshold"),
            "precision": None if s.get("precision") != s.get("precision") else s.get("precision"),
            "recall": None if s.get("recall") != s.get("recall") else s.get("recall"),
            "support": s.get("support"),
            "tp": s.get("tp"), "fp": s.get("fp"), "fn": s.get("fn"),
            "gold_edits": s.get("gold_edits"),
            "precision_lcb95": None if s.get("p_lcb95") != s.get("p_lcb95") else s.get("p_lcb95"),
            "max_support_any_threshold": v["max_support_any_threshold"],
            "max_certifiable_lcb95_if_perfect": v["max_certifiable_lcb"],
            "enabled": bool(s.get("enabled")),
            "reason": s.get("reason"),
            "point_estimate_only_candidate": v["selection_point_only"],
        }

    # `allow_nan=False` on purpose. Python happily writes a bare `NaN` token, which is not JSON
    # and which `JSONDecoder` on the Swift side refuses outright — so a single empty cell would
    # make the whole threshold table unreadable to the app. Non-finite values mean "no evidence",
    # and `null` is how that is spelled in JSON.
    def _finite(obj):
        if isinstance(obj, float):
            return obj if math.isfinite(obj) else None
        if isinstance(obj, dict):
            return {k: _finite(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [_finite(v) for v in obj]
        return obj

    Path(args.out).write_text(
        json.dumps(_finite(doc), indent=2, ensure_ascii=False, allow_nan=False))
    Path(args.sweeps).write_text(json.dumps(
        _finite({fn: {k: v for k, v in r.items()} for fn, r in results.items()}),
        indent=2, ensure_ascii=False, allow_nan=False))
    print(f"[write] {args.out}")
    print(f"[write] {args.sweeps}")

    for fn in results:
        print(f"\n===== {SPLITS.get(fn, fn)} =====")
        hdr = (f"{'cell':>22} {'tier':>10} {'thr':>8} {'P':>7} {'LCB95':>7} {'R':>7} "
               f"{'n':>6} {'TP':>6} {'FP':>4} {'gold':>6} {'nmax':>6} "
               f"{'>=300':>6} {'>=120':>6} {'ship':>5}")
        print(hdr)
        print("-" * len(hdr))
        for key, v in results[fn].items():
            s = v["selection"]
            if v["gold_edits"] == 0 and v["max_support_any_threshold"] == 0:
                continue
            def f(x):
                return f"{x:.4f}" if isinstance(x, float) and x == x else "  --  "
            nmax = v["max_support_any_threshold"]
            print(f"{key:>22} {str(s.get('tier')):>10} {f(s.get('threshold'))} "
                  f"{f(s.get('precision'))} "
                  f"{f(s.get('p_lcb95'))} {f(s.get('recall'))} "
                  f"{s.get('support', 0):>6} {s.get('tp', 0):>6} {s.get('fp', 0):>4} "
                  f"{v['gold_edits']:>6} {nmax:>6} "
                  f"{('yes' if nmax >= 300 else 'NO'):>6} "
                  f"{('yes' if nmax >= 120 else 'NO'):>6} "
                  f"{'YES' if s.get('enabled') else 'no':>5}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python
"""
build_gold_split.py -- turn the LLM-authored reference corpus
(`Tools/llm-eval/authoring/gold-corpus.json`) into mmBERT edit labels, and split
it -- BY CASE ID -- into a training slice and a calibration holdout.

Why this file exists
--------------------
Every calibration number published so far was measured against pairs whose
reference side came from the same Qwen-4B teacher the model was distilled from.
That is not an independent reference: wherever the teacher is systematically
wrong, the model learns the same mistake and then scores it as a true positive.
It flatters precision in exactly the direction that then fails the release gate.

The authored corpus is independent of the teacher. Its reference side was
written under a hard constraint -- punctuation, capitalisation, paragraph
breaks, filler removal and obvious grammar fixes only, no paraphrase, no
content-word substitution, no reordering -- which is precisely the subset of
edits this label scheme can express.

Two uses, in order of value:

  1. CALIBRATION REFERENCE (the point of the exercise). The holdout slice
     becomes calibrate.py's `--primary` split.
  2. TRAINING SUPERVISION (secondary). ~150 pairs against ~22,000 corpus rows is
     noise unless upweighted, and upweighting 150 pairs invites memorisation.
     See GOLD_TRAIN_REPEAT in run_gold_retrain.sh for the factor and its
     justification.

Leakage
-------
The single thing that would invalidate the whole run is a case appearing in both
train and the calibration holdout. Three defences:

  A. The split is on case `id`, deterministically (sha1 of the id), stratified
     by language. One id lands in exactly one side.
  B. `assert` on id-set disjointness, and on `norm_key` disjointness of the
     rendered text (two different ids carrying the same utterance would be a
     leak the id check cannot see).
  C. The holdout file is passed to build_corpus.py as `--holdout`, which drops
     any history row, teacher pair, extra-train row or synthetic-corruption seed
     whose `norm_key` matches it. So a holdout case cannot re-enter training
     through the history DB either.

Reuses build_corpus.align_pair -- the same aligner as the teacher-distillation
path -- so alignment-preserving edits (punctuation, casing, filler/repetition
deletion) are labelled and every lexical rewrite is masked. There is exactly one
aligner in this toolchain and this is not a second one.

Usage
-----
  ./.venv/bin/python build_gold_split.py \
      --gold ../llm-eval/authoring/gold-corpus.json \
      --calib-frac 0.70 --seed 20260818
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import build_corpus as BC  # noqa: E402
from build_eval_large import lexical_drift  # noqa: E402
from common import IGNORE, Example, detect_script, split_word  # noqa: E402

REPO = HERE.parent.parent
DEFAULT_GOLD = REPO / "Tools" / "llm-eval" / "authoring" / "gold-corpus.json"

SOURCE_TAG = "authored_gold"


def stable_rank(case_id: str, salt: str) -> str:
    """Deterministic, seed-dependent ordering key for a case id.

    Not `hash()`: PYTHONHASHSEED randomises str hashing per process, so the
    train/holdout split would silently differ between the build run and any
    later audit run. sha1 is stable across processes, machines and Python
    versions.
    """
    return hashlib.sha1(f"{salt}:{case_id}".encode()).hexdigest()


def label_counts(rows: List[Example]) -> dict:
    out: Dict[str, dict] = {}
    for ex in rows:
        d = out.setdefault(ex.script, {
            "examples": 0, "words": 0, "labelled_punct": 0, "labelled_case": 0,
            "labelled_disf": 0, "labelled_error": 0, "gold_punct_edits": 0,
            "gold_case_edits": 0, "gold_disf_edits": 0, "gold_error_edits": 0,
        })
        d["examples"] += 1
        d["words"] += len(ex.words)
        for i, raw in enumerate(ex.words):
            w = split_word(raw)
            p, c, dd, er = ex.punct[i], ex.case[i], ex.disf[i], ex.error[i]
            if p != IGNORE:
                d["labelled_punct"] += 1
                d["gold_punct_edits"] += int(p != w.punct_state)
            if c != IGNORE:
                d["labelled_case"] += 1
                d["gold_case_edits"] += int(c != w.case_state)
            if dd != IGNORE:
                d["labelled_disf"] += 1
                d["gold_disf_edits"] += int(dd == 1)
            if er != IGNORE:
                d["labelled_error"] += 1
                d["gold_error_edits"] += int(er == 1)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gold", default=str(DEFAULT_GOLD))
    ap.add_argument("--out-calib", default=str(HERE / "artifacts" / "data" / "eval_gold.jsonl"),
                    help="calibration holdout. Written into artifacts/data so "
                         "calibrate.py finds it next to the other splits.")
    ap.add_argument("--out-train", default=str(HERE / "data" / "gold_train.jsonl"))
    ap.add_argument("--report", default=str(HERE / "artifacts" / "gold_split_report.json"))
    ap.add_argument("--calib-frac", type=float, default=0.70,
                    help="fraction of cases held out for calibration, per language. "
                         "Weighted towards calibration on purpose: as training data "
                         "these pairs are ~0.7%% of the corpus even at x12, while as "
                         "an independent reference they are the only non-teacher "
                         "evidence that exists.")
    ap.add_argument("--max-lex-frac", type=float, default=0.10,
                    help="same alignment audit as build_eval_large.py")
    ap.add_argument("--min-ratio", type=float, default=0.90)
    ap.add_argument("--seed", type=int, default=20260818)
    args = ap.parse_args()

    gp = Path(args.gold)
    if not gp.exists():
        raise SystemExit(f"gold corpus not found: {gp}")
    doc = json.loads(gp.read_text())
    cases = doc.get("cases", doc if isinstance(doc, list) else [])
    header = doc.get("header", {}) if isinstance(doc, dict) else {}
    print(f"[gold] {gp}: {len(cases)} cases, header={json.dumps(header, ensure_ascii=False)[:400]}")

    salt = str(args.seed)
    drops: Counter = Counter()
    kept: List[Tuple[str, str, Example]] = []      # (id, declared_lang, example)
    seen_ids = set()
    seen_keys = set()

    for c in cases:
        cid = str(c.get("id") or "")
        raw = (c.get("input") or "").strip()
        ref = (c.get("gold") or "").strip()
        if not cid or not raw or not ref:
            drops["empty_field"] += 1
            continue
        if cid in seen_ids:
            drops["duplicate_id"] += 1
            continue
        seen_ids.add(cid)
        k = BC.norm_key(raw)
        if not k:
            drops["empty_norm_key"] += 1
            continue
        if k in seen_keys:
            drops["duplicate_input_text"] += 1
            continue
        seen_keys.add(k)

        # Script is resolved from the text, never from the declared field --
        # the same rule the rest of the toolchain uses.
        sc = detect_script(ref)
        declared = (c.get("language") or "").strip()
        if sc not in ("en", "he", "ru"):
            drops["script_unsupported"] += 1
            continue
        if declared and declared != sc:
            drops[f"declared_{declared}_but_script_{sc}"] += 1
            # Not fatal: the script wins, the mismatch is recorded.
        why = BC.teacher_quality_reject(raw, ref)
        if why:
            drops[f"quality_{why}"] += 1
            continue
        d = lexical_drift(raw, ref, sc)
        if d is None:
            drops["empty_tokens"] += 1
            continue
        frac, ratio, _n, _ops = d
        if frac > args.max_lex_frac + 1e-9:
            drops["AUTHOR_REWORDED_lex_frac"] += 1
            continue
        if ratio < args.min_ratio:
            drops["AUTHOR_REWORDED_low_align_ratio"] += 1
            continue
        ex = BC.align_pair(raw, ref, sc, SOURCE_TAG)
        if ex is None:
            drops["no_usable_labels"] += 1
            continue
        kept.append((cid, sc, ex))

    print(f"[filter] kept {len(kept)} of {len(cases)}  "
          f"by script {dict(Counter(sc for _, sc, _ in kept))}")
    print(f"[filter] drops {dict(drops.most_common())}")
    if not kept:
        raise SystemExit("no usable authored pairs -- refusing to write empty splits")

    # ---- deterministic, language-stratified split BY ID ----
    by_sc: Dict[str, list] = defaultdict(list)
    for cid, sc, ex in kept:
        by_sc[sc].append((cid, ex))
    calib, train = [], []
    for sc in sorted(by_sc):
        lst = sorted(by_sc[sc], key=lambda x: stable_rank(x[0], salt))
        k = int(round(args.calib_frac * len(lst)))
        k = max(1, min(len(lst), k))
        calib += [(cid, sc, ex) for cid, ex in lst[:k]]
        train += [(cid, sc, ex) for cid, ex in lst[k:]]
        print(f"[split] {sc}: {k} calib / {len(lst) - k} train")

    calib_ids = {cid for cid, _, _ in calib}
    train_ids = {cid for cid, _, _ in train}
    # (B) The assertion the whole result rests on. A case on both sides means
    # the model was trained on the answers to its own calibration set, and every
    # precision number below would be fiction.
    overlap = calib_ids & train_ids
    assert not overlap, f"LEAK: {len(overlap)} case ids in BOTH train and calib: {sorted(overlap)[:10]}"
    assert len(calib_ids) + len(train_ids) == len(kept), \
        "LEAK: id sets do not partition the kept cases"
    ck = {BC.norm_key(" ".join(ex.words)) for _, _, ex in calib}
    tk = {BC.norm_key(" ".join(ex.words)) for _, _, ex in train}
    tover = ck & tk
    assert not tover, f"LEAK: {len(tover)} identical input texts under different ids"
    print(f"[assert] id-disjoint OK ({len(calib_ids)} calib / {len(train_ids)} train), "
          f"text-disjoint OK")

    def dump(path: Path, rows) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w") as f:
            for _cid, _sc, ex in rows:
                f.write(json.dumps(ex.to_json(), ensure_ascii=False) + "\n")
        print(f"[write] {path} n={len(rows)} "
              f"scripts={dict(Counter(sc for _, sc, _ in rows))} "
              f"words={sum(len(ex.words) for _, _, ex in rows)}")

    dump(Path(args.out_calib), calib)
    dump(Path(args.out_train), train)

    report = {
        "generated_by": "build_gold_split.py",
        "params": vars(args),
        "gold_header": header,
        "cases_in_file": len(cases),
        "kept": len(kept),
        "drops": dict(drops.most_common()),
        "calib_ids": sorted(calib_ids),
        "train_ids": sorted(train_ids),
        "calib_label_counts": label_counts([ex for _, _, ex in calib]),
        "train_label_counts": label_counts([ex for _, _, ex in train]),
    }
    Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"[write] {args.report}")
    print(json.dumps(report["calib_label_counts"], indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

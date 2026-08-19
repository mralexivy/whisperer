#!/usr/bin/env python
"""
build_eval_large.py -- build a LARGE held-out real-ASR eval set for the
mmBERT transcript editor.

Why this exists
---------------
`eval_real.jsonl` (built by build_corpus.py) holds 86 real (raw ASR -> Qwen-4B
teacher) pairs: 82 en / 2 he / 2 ru. That is structurally incapable of
certifying a precision gate -- the largest cell offers at most 272 proposals at
any threshold and a *perfect* 272/272 gives a 95% Clopper-Pearson lower bound
of only 0.9890. CALIBRATION.md therefore disabled every cell on statistics, not
on measured quality.

This script mines every real (ASR text -> better-punctuated reference) pair
available on the machine, applies a much stricter usability filter than
build_corpus.py did, removes anything the model was fine-tuned on, and writes
`data/eval_real_large.jsonl` (+ optionally `data/train_real_large.jsonl`).

Sources
-------
  1. WhispererTests/TestData/golden-set.json -- 400 entries. `storedTranscript`
     is the streaming ASR output actually stored by the app; `goldenTranscript`
     is a whole-file decode of the same audio by the same model, which is
     better punctuated and better cased. A real ASR -> reference pair.
  2. The app's history DBs (sandboxed AND non-sandboxed), READ ONLY.
     `ZTRANSCRIPTION` -> `ZAIENHANCEDTEXT` (the shipped Qwen-4B's polished
     output). Unlike build_corpus.py this does NOT restrict to
     `ZAIMODENAME == 'Correct'`: the mode records the prompt, not the text
     relationship, and a Custom/Rewrite row whose output differs from the input
     only in punctuation and casing is a perfectly good teacher pair. The text
     relationship is checked directly instead (see below).
  3. Tools/llm-eval/corpus.json -- the LLM-eval corpus (input / gold).

Label quality gate (the whole game)
-----------------------------------
A teacher pair is usable only where the reference differs from the input ONLY
in punctuation, casing and filler/repetition deletion. If the teacher reworded,
translated, truncated or expanded, the difflib alignment silently produces
garbage labels. Three defences, in order:

  A. `teacher_quality_reject` from build_corpus.py -- script change, lost
     digits/URLs, chat-template leakage, degeneration, length ratio.
  B. NEW word-level alignment audit. Align on `Word.key` (the accent-stripped,
     lowercased, punctuation-stripped core), then classify every non-`equal`
     opcode:
       - `delete` of a known filler or of an immediate repetition -> a genuine
         disfluency edit, allowed and labelled.
       - every other `delete`, and all `replace` / `insert` -> LEXICAL DRIFT.
     A pair is DROPPED if the lexical-drift fraction exceeds
     `--max-lex-frac` (default 0.10 of the input words) or if the alignment
     ratio falls below `--min-ratio` (default 0.90). Surviving lexical spans
     are MASKED by `align_pair` (label = -100) and their neighbouring
     punctuation is masked too, so they contribute nothing to precision.
     `--max-lex-frac 0` gives the fully strict "letter sequence must match
     modulo case" set.
  C. Leakage removal. Anything whose normalised letter sequence appears in
     `train.jsonl` / `val.jsonl` -- on either the input side (real teacher
     pairs were upweighted 6x into train) or the reconstructed target side
     (golden-set and DB-polished texts were used as clean seeds for synthetic
     corruption, 8 differently-corrupted copies each) -- is dropped. The target
     side is reconstructed by rendering each training example's own labels,
     which undoes the corruption. Keys are filler-stripped so that the
     corruptor's inserted-but-masked soft fillers cannot defeat the match.

Usage
-----
  ./.venv/bin/python build_eval_large.py
  ./.venv/bin/python build_eval_large.py --max-lex-frac 0 --out-eval data/eval_real_strict.jsonl
"""

from __future__ import annotations

import argparse
import difflib
import json
import random
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import build_corpus as BC  # noqa: E402  (reuses its DB loader, filter, aligner)
from common import (  # noqa: E402
    IGNORE, PUNCT_LABELS, Example, apply_case, detect_script, split_word,
    tokenize_words,
)

REPO = HERE.parent.parent
LLM_EVAL_CORPUS = REPO / "Tools" / "llm-eval" / "corpus.json"

# `norm_key` lives in build_corpus so that the corpus builder can exclude the
# held-out documents using the *same* key this script splits on. Two copies of a
# leakage key that drift apart is a silent leak.
ALL_FILLERS = BC.ALL_FILLERS
norm_key = BC.norm_key


def render_target(ex: dict) -> str:
    """Reconstruct the *target* text of a training example from its labels.

    For synthetically corrupted examples this recovers (up to masked spans) the
    clean seed text -- i.e. the golden-set transcript or DB-polished text the
    corruptor started from. That is exactly the string we must not let back
    into eval.
    """
    out = []
    for i, raw in enumerate(ex["words"]):
        if ex["disf"][i] == 1:
            continue
        w = split_word(raw)
        core = w.core
        c = ex["case"][i]
        if c != IGNORE:
            core = apply_case(core, c)
        p = ex["punct"][i]
        trail = PUNCT_LABELS[p] if p != IGNORE else w.trail
        out.append(core + trail)
    return " ".join(out)


def leakage_keys(data_dir: Path, files=("train.jsonl", "val.jsonl")) -> set:
    keys = set()
    for fn in files:
        p = data_dir / fn
        if not p.exists():
            print(f"[warn] leakage source missing: {p}")
            continue
        n = 0
        with p.open() as f:
            for line in f:
                ex = json.loads(line)
                keys.add(norm_key(" ".join(ex["words"])))
                keys.add(norm_key(render_target(ex)))
                n += 1
        print(f"[leak] {fn}: {n} examples -> {len(keys)} cumulative keys")
    keys.discard("")
    return keys


# --------------------------------------------------------------------------
# candidate collection
# --------------------------------------------------------------------------

def collect_candidates(golden_path=None) -> List[Tuple[str, str, str]]:
    """(source_tag, asr_text, reference_text). READ ONLY on every source."""
    out: List[Tuple[str, str, str]] = []

    g = json.loads(Path(golden_path or BC.GOLDEN).read_text())
    for e in g["entries"]:
        a = (e.get("storedTranscript") or "").strip()
        b = (e.get("goldenTranscript") or "").strip()
        if a and b:
            out.append(("golden_wholefile", a, b))

    for tag, p in (("db_sandbox", BC.SANDBOX_DB), ("db_nonsandbox", BC.NONSANDBOX_DB)):
        for r in BC.load_db(p):
            a = (r.get("ZTRANSCRIPTION") or "").strip()
            b = (r.get("ZAIENHANCEDTEXT") or "").strip()
            if a and b:
                out.append((f"{tag}:{r.get('ZAIMODENAME') or 'none'}", a, b))

    if LLM_EVAL_CORPUS.exists():
        c = json.loads(LLM_EVAL_CORPUS.read_text())
        for x in c.get("cases", []):
            a = (x.get("input") or "").strip()
            b = (x.get("gold") or "").strip()
            if a and b:
                out.append(("llm_eval", a, b))
    return out


# --------------------------------------------------------------------------
# alignment audit
# --------------------------------------------------------------------------

def source_group(src: str) -> str:
    """Collapse provenance to the three groups whose LABEL QUALITY differs.

    They are kept distinguishable in the `source` field so calibration can
    slice by them: if one group's precision is wildly out of line with the
    others, that is evidence of a labelling problem in that group, not of model
    behaviour, and it has to be investigated before any cell is enabled.
    """
    if src == "golden_wholefile":
        # Reference = a whole-file decode of the same audio by the same ASR
        # model. NOT a human reference and not a teacher LLM: it fixes the
        # windowing damage of the streaming path (and, incidentally, most of
        # the punctuation and casing), but where the model mishears a word it
        # mishears it identically on both sides.
        return "gold_wholefile"
    if src.endswith(":Correct") or src in ("llm_eval", "eval_real_v1"):
        return "teacher_correct"
    return "teacher_other"


def lexical_drift(raw: str, ref: str, script: str) -> Optional[Tuple[float, float, int, Counter]]:
    """(lex_fraction, alignment_ratio, n_input_words, op_counts) or None."""
    rws = tokenize_words(raw)
    pws = tokenize_words(ref)
    if not rws or not pws:
        return None
    sm = difflib.SequenceMatcher(a=[w.key for w in rws], b=[w.key for w in pws],
                                 autojunk=False)
    strong = BC.STRONG_FILLERS.get(script, set())
    n = len(rws)
    lex = 0
    ops: Counter = Counter()
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        if tag == "delete":
            for k in range(i1, i2):
                w = rws[k]
                is_rep = ((k > 0 and w.key == rws[k - 1].key) or
                          (k + 1 < n and w.key == rws[k + 1].key))
                if w.key in strong or is_rep:
                    ops["disfluency_delete"] += 1
                else:
                    ops["lexical_delete"] += 1
                    lex += 1
        else:
            ops[f"lexical_{tag}"] += 1
            lex += max(i2 - i1, j2 - j1)
    return lex / n, sm.ratio(), n, ops


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(HERE / "artifacts" / "data"),
                    help="dir holding train/val jsonl (leakage source)")
    ap.add_argument("--out-dir", default=str(HERE / "data"))
    ap.add_argument("--out-eval", default="eval_real_large.jsonl")
    ap.add_argument("--out-train", default="train_real_large.jsonl")
    ap.add_argument("--report", default=str(HERE / "artifacts" / "eval_real_large_report.json"))
    ap.add_argument("--golden", default=None,
                    help="golden-set JSON to mine (default: the 400-entry benchmark "
                         "corpus). Point at artifacts/raw/history-golden.json to mine "
                         "the whole recordings history")
    ap.add_argument("--min-eval", type=int, default=300,
                    help="floor on eval pairs per script before any go to train")
    ap.add_argument("--max-lex-frac", type=float, default=0.10)
    ap.add_argument("--min-ratio", type=float, default=0.90)
    ap.add_argument("--train-frac", type=float, default=0.0,
                    help="fraction of EN pairs diverted to the train-side file. "
                         "he/ru are never diverted -- they are data-starved.")
    ap.add_argument("--seed", type=int, default=20260817)
    ap.add_argument("--keep-existing-eval-real", action="store_true", default=True,
                    help="also fold in the 86 pairs of eval_real.jsonl (already held out)")
    args = ap.parse_args()

    data_dir = Path(args.data)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)

    # The 326-pair holdout that every published calibration number was measured on.
    # Growing the candidate pool reshuffles the split, so any pair that was eval
    # before is pinned to eval now -- otherwise a retrain would be scored on pairs
    # it had just been trained on, and the comparison against CALIBRATION.md would
    # be against a different set under the same name.
    pinned_eval = set()
    prev_eval = out_dir / args.out_eval
    if prev_eval.exists():
        with prev_eval.open() as f:
            for line in f:
                pinned_eval.add(norm_key(" ".join(json.loads(line)["words"])))
        print(f"[pin] {len(pinned_eval)} pairs pinned to eval from the existing "
              f"{args.out_eval}")

    leak = leakage_keys(data_dir)

    cands = collect_candidates(args.golden)
    print("[collect] raw candidate pairs:", len(cands),
          dict(Counter(s for s, _, _ in cands).most_common()))

    # ---- dedupe on the INPUT side. The same utterance polished twice is not
    #      two independent observations.
    seen_input = set()
    uniq: List[Tuple[str, str, str]] = []
    dup = 0
    for s, a, b in cands:
        k = norm_key(a)
        if not k or k in seen_input:
            dup += 1
            continue
        seen_input.add(k)
        uniq.append((s, a, b))
    print(f"[dedupe] {len(uniq)} unique inputs ({dup} duplicate inputs dropped)")

    drops: Counter = Counter()
    kept: List[Tuple[Example, str]] = []
    leaked_train: List[Tuple[Example, str]] = []
    drift_hist: List[float] = []
    op_totals: Counter = Counter()

    for src, raw, ref in uniq:
        sc = detect_script(ref)
        if sc not in ("en", "he", "ru"):
            drops["script_unsupported"] += 1
            continue
        leaked = norm_key(raw) in leak or norm_key(ref) in leak
        if leaked:
            drops["LEAKAGE_in_finetune_set"] += 1
        why = BC.teacher_quality_reject(raw, ref)
        if why:
            drops[f"quality_{why}"] += 1
            continue
        d = lexical_drift(raw, ref, sc)
        if d is None:
            drops["quality_empty_tokens"] += 1
            continue
        frac, ratio, nwords, ops = d
        if frac > args.max_lex_frac + 1e-9:
            drops["TEACHER_REWORDED_lex_frac"] += 1
            continue
        if ratio < args.min_ratio:
            drops["TEACHER_REWORDED_low_align_ratio"] += 1
            continue
        ex = BC.align_pair(raw, ref, sc, source_group(src))
        if ex is None:
            drops["no_usable_labels"] += 1
            continue
        if leaked:
            # Already in the fine-tuning set -> worthless as eval, but a
            # sibling retrain can still use it, and it is now labelled by the
            # stricter pipeline. Goes to the train-side file only.
            leaked_train.append((ex, src))
            continue
        kept.append((ex, src))
        drift_hist.append(frac)
        op_totals.update(ops)

    print("[filter] kept", len(kept), dict(Counter(e.script for e, _ in kept)))
    print("[filter] drops", dict(drops.most_common()))

    # ---- fold in the existing held-out eval_real.jsonl (never trained on)
    folded = 0
    if args.keep_existing_eval_real:
        p = data_dir / "eval_real.jsonl"
        have = {norm_key(" ".join(e.words)) for e, _ in kept}
        if p.exists():
            with p.open() as f:
                for line in f:
                    d = json.loads(line)
                    k = norm_key(" ".join(d["words"]))
                    if k in have:
                        continue
                    have.add(k)
                    ex = Example.from_json(d)
                    ex.source = source_group("eval_real_v1")
                    kept.append((ex, "eval_real_v1"))
                    folded += 1
    print(f"[fold] folded {folded} pairs from the original eval_real.jsonl")

    # ---- split
    by_sc: Dict[str, list] = defaultdict(list)
    for ex, src in kept:
        by_sc[ex.script].append((ex, src))
    eval_set, train_set = [], []
    repinned = 0
    for sc, lst in by_sc.items():
        lst = sorted(lst, key=lambda x: " ".join(x[0].words))
        rng.shuffle(lst)
        # Pinned pairs are lifted out before the split so the previous holdout
        # survives a pool that has grown by an order of magnitude.
        pinned = [x for x in lst if norm_key(" ".join(x[0].words)) in pinned_eval]
        lst = [x for x in lst if norm_key(" ".join(x[0].words)) not in pinned_eval]
        repinned += len(pinned)
        # he/ru used to be excluded from the train split entirely, to give two
        # tiny languages every pair they had for eval. With the pool grown from
        # the whole recordings history the constraint reverses: he had SIX real
        # training documents, which is why every he cell came back unmeasured.
        # Split every script now, but never take a script's eval below --min-eval.
        room = max(0, len(lst) + len(pinned) - args.min_eval)
        k = min(int(round(args.train_frac * len(lst))), room)
        train_set += lst[:k]
        eval_set += lst[k:] + pinned
    if pinned_eval:
        print(f"[pin] {repinned} of {len(pinned_eval)} pinned pairs re-found and "
              f"forced into eval")
    # Pairs excluded from eval for LEAKAGE are still valid training data.
    train_set += leaked_train

    def dump(path: Path, xs) -> None:
        with path.open("w") as f:
            for ex, _ in xs:
                f.write(json.dumps(ex.to_json(), ensure_ascii=False) + "\n")
        print(f"[write] {path} n={len(xs)} "
              f"scripts={dict(Counter(e.script for e, _ in xs))} "
              f"words={sum(len(e.words) for e, _ in xs)}")

    dump(out_dir / args.out_eval, eval_set)
    if train_set:
        dump(out_dir / args.out_train, train_set)

    def label_counts(xs) -> dict:
        out: Dict[str, dict] = {}
        for ex, _ in xs:
            d = out.setdefault(ex.script, {
                "examples": 0, "words": 0, "labelled_punct": 0,
                "labelled_case": 0, "labelled_disf": 0, "labelled_error": 0,
                "gold_punct_edits": 0, "gold_case_edits": 0,
                "gold_disf_edits": 0, "gold_error_edits": 0,
                "gold_punct_by_mark": Counter(),
            })
            d["examples"] += 1
            d["words"] += len(ex.words)
            for i, raw in enumerate(ex.words):
                w = split_word(raw)
                p, c, dd, er = ex.punct[i], ex.case[i], ex.disf[i], ex.error[i]
                if p != IGNORE:
                    d["labelled_punct"] += 1
                    if p != w.punct_state:
                        d["gold_punct_edits"] += 1
                        d["gold_punct_by_mark"][PUNCT_LABELS[p] or "NONE"] += 1
                if c != IGNORE:
                    d["labelled_case"] += 1
                    if c != w.case_state:
                        d["gold_case_edits"] += 1
                if dd != IGNORE:
                    d["labelled_disf"] += 1
                    if dd == 1:
                        d["gold_disf_edits"] += 1
                if er != IGNORE:
                    d["labelled_error"] += 1
                    if er == 1:
                        d["gold_error_edits"] += 1
        for v in out.values():
            v["gold_punct_by_mark"] = dict(v["gold_punct_by_mark"].most_common())
        return out

    report = {
        "generated_by": "build_eval_large.py",
        "params": vars(args),
        "sources": dict(Counter(s for s, _, _ in cands).most_common()),
        "raw_candidates": len(cands),
        "unique_inputs": len(uniq),
        "duplicate_inputs_dropped": dup,
        "drops": dict(drops.most_common()),
        "drops_note": ("LEAKAGE_in_finetune_set is counted first and does not "
                       "short-circuit: a leaked pair that also fails a quality "
                       "check is counted in both buckets, so the drop counters "
                       "sum to more than unique_inputs - kept_pairs."),
        "kept_pairs": len(kept),
        "leaked_but_quality_ok_routed_to_train": len(leaked_train),
        "folded_from_eval_real_v1": folded,
        "kept_by_source": dict(Counter(s for _, s in kept).most_common()),
        "kept_by_script": dict(Counter(e.script for e, _ in kept)),
        "mean_lexical_drift_fraction": (sum(drift_hist) / len(drift_hist)) if drift_hist else None,
        "alignment_ops": dict(op_totals.most_common()),
        "eval": label_counts(eval_set),
        "train": label_counts(train_set),
    }
    Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"[write] {args.report}")
    print(json.dumps(report["eval"], indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

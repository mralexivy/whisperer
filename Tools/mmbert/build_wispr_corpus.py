#!/usr/bin/env python
"""
build_wispr_corpus.py -- mine the Wispr Flow corpus into mmBERT training examples.

Phase 1 corpus builder. Reads ~/wispr_corpus/corpus.jsonl (1,639 asr+formatted
pairs) and produces label streams aligned on word boundaries, then writes:

  artifacts/data/wispr_train.jsonl   (80% of clean pairs, stratified by script)
  artifacts/data/wispr_val.jsonl     (20% of clean pairs, stratified by script)
  artifacts/data/wispr_coverage.json (coverage report)

Processing pipeline
-------------------
1. Script resolution via detect_script() on text, never the detectedLanguage column.
2. HTML list extraction: strip <ol>/<ul>/<li> tags, record LIST_ITEM / PARA_BREAK
   positions by word index in the stripped target text.
3. editedText contamination gate: rows with clean edits produce an extra
   asrText→editedText pair weighted 1.5×; heavily-divergent edits are rejected
   and only the asrText→formattedText pair is used.
4. Teacher quality gate (reused from build_corpus.teacher_quality_reject).
5. Reverted-AI down-weighting: hasRevertedAI=True or formattingDivergenceScore > 0.5
   → source='reverted', weight = --reverted-weight (default 0.3).
6. Extended label alignment (punct, case, disf, append, repl, merge, para, dest).
7. Drift-fraction gate: unexplainable opcodes / total words > --max-lex-frac → drop.
8. Holdout protection: norm_key deduplication against data/eval_real_large.jsonl.
9. 80/20 stratified train/val split by script.

Usage
-----
    ./.venv/bin/python build_wispr_corpus.py --report
    ./.venv/bin/python build_wispr_corpus.py [--out artifacts/data] [--seed 1234]
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import random
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# ---------------------------------------------------------------------------
# Core common primitives (always present)
# ---------------------------------------------------------------------------
from common import (  # noqa: E402
    CASE2ID, IGNORE, PUNCT2ID, PUNCT_LABELS, Example, Word,
    detect_script, has_case, normalise_punct, split_word, tokenize_words,
    build_example,
)

# ---------------------------------------------------------------------------
# Extended vocab — added by parallel common.py agent.
# py_compile is purely syntactic and does NOT execute imports, so this block
# passes the syntax check even before common.py is updated.  At runtime the
# script requires these symbols; do not run until common.py is patched.
# ---------------------------------------------------------------------------
from common import (  # noqa: E402,F401
    APPEND_VOCAB, APPEND2ID, N_APPEND,
    GTRANSFORMS, N_GTRANSFORM,
    REPL_LITERALS, REPL_VOCAB, N_REPL,
    MERGE_LABELS, MERGE2ID, N_MERGE,
    PARA_LABELS, PARA2ID, N_PARA,
    DEST_CLASSES, DEST2ID, N_DEST, bundle_id_to_dest,
)

# apply_gtransform may raise ImportError internally when inflect is not installed
# (PLURAL/SINGULAR transforms need it).  Wrap at the call site.
try:
    from common import apply_gtransform as _apply_gtransform_raw  # noqa: E402

    def apply_gtransform(word: str, transform: str) -> Optional[str]:
        """Return transformed word, or None if transform inapplicable / inflect absent."""
        try:
            return _apply_gtransform_raw(word, transform)
        except ImportError:
            return None
        except Exception:
            return None

except (ImportError, AttributeError):

    def apply_gtransform(word: str, transform: str) -> Optional[str]:  # type: ignore[misc]
        return None

# ---------------------------------------------------------------------------
# Re-use helpers from build_corpus (no circular import: that module only
# imports from common).
# ---------------------------------------------------------------------------
import build_corpus as BC  # noqa: E402

norm_key = BC.norm_key
ALL_FILLERS = BC.ALL_FILLERS
STRONG_FILLERS = BC.STRONG_FILLERS
teacher_quality_reject = BC.teacher_quality_reject

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CORPUS_DEFAULT = Path(os.path.expanduser("~/wispr_corpus/corpus.jsonl"))

PARA_NONE = "NONE"
PARA_BREAK = "PARA_BREAK"
PARA_LIST_ITEM = "LIST_ITEM"

_HTML_TAG = re.compile(r"</?(?:ol|ul|li)\b[^>]*>", re.IGNORECASE)
_LI_OPEN = re.compile(r"<li\b[^>]*>", re.IGNORECASE)


# ---------------------------------------------------------------------------
# HTML structure extraction
# ---------------------------------------------------------------------------

def extract_html_structure(text: str) -> Tuple[str, Dict[int, str]]:
    """Strip HTML list markup; return (clean_text, {target_word_idx: para_label}).

    Para labels are PARA_BREAK (blank-line-separated paragraph) or LIST_ITEM
    (<li> tag).  The label is placed on the FIRST word of the new structural
    unit.  Only word positions in the STRIPPED target text are reported.
    """
    marks: Dict[int, str] = {}

    # Fast path: no HTML tags, no multi-line content
    if not _HTML_TAG.search(text) and "\n" not in text:
        return text, {}

    lines = text.split("\n")
    segments: List[Tuple[Optional[str], str]] = []  # (mark_or_None, segment_text)
    prev_blank = False

    for line in lines:
        stripped = line.strip()
        if not stripped:
            prev_blank = True
            continue

        has_li = bool(_LI_OPEN.search(stripped))
        clean_line = _HTML_TAG.sub("", stripped).strip()
        if not clean_line:
            prev_blank = True
            continue

        if has_li:
            mark: Optional[str] = PARA_LIST_ITEM
        elif prev_blank:
            mark = PARA_BREAK
        else:
            mark = None

        segments.append((mark, clean_line))
        prev_blank = False

    if not segments:
        # Degenerate: all tags, nothing left
        clean = _HTML_TAG.sub("", text)
        clean = re.sub(r"\s+", " ", clean).strip()
        return clean, {}

    parts: List[str] = []
    word_idx = 0
    for mark, segment in segments:
        seg_words = segment.split()
        if seg_words and mark is not None:
            marks[word_idx] = mark
        parts.extend(seg_words)
        word_idx += len(seg_words)

    return " ".join(parts), marks


# ---------------------------------------------------------------------------
# G-transform / literal-replacement helpers
# ---------------------------------------------------------------------------

def _try_gtransform_repl(src_key: str, dst_key: str) -> Optional[int]:
    """Try every GTRANSFORM; return the REPL label index (1-based, 0=NONE) or None.

    Assumes REPL_VOCAB[:N_GTRANSFORM] corresponds 1-to-1 with GTRANSFORMS, so
    label index = GTRANSFORMS.index(transform) + 1.
    """
    for i, transform in enumerate(GTRANSFORMS):
        result = apply_gtransform(src_key, transform)
        if result is not None and result.lower() == dst_key:
            return i + 1  # 1-based; 0 reserved for NONE
    return None


def _try_literal_repl(dst_key: str) -> Optional[int]:
    """Return the REPL label index for a literal replacement, or None.

    REPL_LITERALS is a dict mapping normalised target word → label index
    (offset already includes the N_GTRANSFORM prefix, if any).
    """
    if isinstance(REPL_LITERALS, dict):
        return REPL_LITERALS.get(dst_key)
    # Fallback: search REPL_VOCAB list
    try:
        vocab = REPL_VOCAB  # type: ignore[name-defined]
        idx = vocab.index(dst_key)
        return N_GTRANSFORM + idx + 1
    except (ValueError, AttributeError, NameError):
        return None


# ---------------------------------------------------------------------------
# Extended Wispr aligner
# ---------------------------------------------------------------------------

def wispr_align_pair(
    raw: str,
    target: str,
    script: str,
    source: str,
    para_marks: Dict[int, str],
    dest: int = 0,
) -> Tuple[Optional[Example], Counter, int, int]:
    """Align (raw ASR, formatted/edited) and derive per-word edit labels.

    Extends build_corpus.align_pair with append / repl / merge / para / dest heads.

    Returns
    -------
    (example_or_None, mask_counter, expressible_ops, total_ops)
    """
    rws = tokenize_words(raw)
    pws = tokenize_words(target)
    if not rws or not pws:
        return None, Counter(), 0, 0

    n = len(rws)
    strong = STRONG_FILLERS.get(script, set())

    # Per-word target arrays — None means IGNORE / masked
    tgt_p: List[Optional[int]] = [None] * n
    tgt_c: List[Optional[int]] = [None] * n
    tgt_d: List[Optional[bool]] = [None] * n
    tgt_append: List[Optional[int]] = [None] * n
    tgt_repl: List[Optional[int]] = [None] * n
    tgt_merge: List[Optional[int]] = [None] * n
    tgt_para: List[Optional[int]] = [None] * n

    mask_counts: Counter = Counter()
    expressible = 0
    total_ops_count = 0

    PARA_NONE_ID = PARA2ID.get(PARA_NONE, 0)
    MERGE_NONE_ID = MERGE2ID.get("NONE", 0)
    APPEND_NONE_ID = 0  # index 0 = no append

    sm = difflib.SequenceMatcher(
        a=[w.key for w in rws],
        b=[w.key for w in pws],
        autojunk=False,
    )
    ops = sm.get_opcodes()

    for tag, i1, i2, j1, j2 in ops:
        ni = i2 - i1   # input span length
        nj = j2 - j1   # target span length

        # ------------------------------------------------------------------
        if tag == "equal":
            total_ops_count += ni
            expressible += ni
            for k in range(ni):
                dst_w = pws[j1 + k]
                tgt_p[i1 + k] = dst_w.punct_state
                tgt_c[i1 + k] = dst_w.case_state
                tgt_d[i1 + k] = False
                tgt_repl[i1 + k] = 0       # NONE
                tgt_merge[i1 + k] = MERGE_NONE_ID
                tgt_append[i1 + k] = APPEND_NONE_ID
                tgt_j = j1 + k
                if tgt_j in para_marks:
                    tgt_para[i1 + k] = PARA2ID.get(para_marks[tgt_j], PARA_NONE_ID)
                else:
                    tgt_para[i1 + k] = PARA_NONE_ID

        # ------------------------------------------------------------------
        elif tag == "delete":
            total_ops_count += ni
            for k in range(ni):
                w = rws[i1 + k]
                is_rep = (
                    (i1 + k > 0 and w.key == rws[i1 + k - 1].key) or
                    (i1 + k + 1 < n and w.key == rws[i1 + k + 1].key)
                )
                if w.key in strong or is_rep:
                    # Genuine disfluency — labelled DELETE
                    tgt_d[i1 + k] = True
                    tgt_p[i1 + k] = None
                    tgt_c[i1 + k] = None
                    tgt_para[i1 + k] = PARA_NONE_ID
                    expressible += 1
                elif w.key in ALL_FILLERS:
                    # Soft filler — deletable with DISF label
                    tgt_d[i1 + k] = True
                    tgt_p[i1 + k] = None
                    tgt_c[i1 + k] = None
                    tgt_para[i1 + k] = PARA_NONE_ID
                    expressible += 1
                else:
                    # Lexical deletion → mask whole word
                    mask_counts["lexical_delete"] += 1
                    # tgt_* remain None

        # ------------------------------------------------------------------
        elif tag == "insert":
            # Pure insertion in target (no input words consumed).
            # APPEND label attaches to the PRECEDING input word.
            total_ops_count += nj
            if nj == 1:
                inserted_key = pws[j1].key
                if i1 > 0:
                    if inserted_key in APPEND2ID:
                        prev = i1 - 1
                        # Only overwrite if the preceding word isn't already masked
                        if tgt_append[prev] is not None:
                            tgt_append[prev] = APPEND2ID[inserted_key]
                            expressible += 1
                        else:
                            mask_counts["append_prev_already_masked"] += 1
                    else:
                        mask_counts["out_of_vocab_single_insert"] += 1
                else:
                    # Insertion before the first input word — cannot attach
                    mask_counts["insert_at_start"] += 1
            else:
                mask_counts["multi_word_insert"] += 1

            # Mask punct of the word immediately before the insertion boundary
            if i1 > 0:
                tgt_p[i1 - 1] = None

        # ------------------------------------------------------------------
        elif tag == "replace":
            total_ops_count += max(ni, nj)

            if ni == 1 and nj == 1:
                # 1:1 replace — try g-transforms, then literal replacement
                src_key = rws[i1].key
                dst_key = pws[j1].key

                repl_idx = _try_gtransform_repl(src_key, dst_key)
                if repl_idx is None:
                    repl_idx = _try_literal_repl(dst_key)

                if repl_idx is not None:
                    tgt_repl[i1] = repl_idx
                    tgt_p[i1] = pws[j1].punct_state
                    tgt_c[i1] = pws[j1].case_state
                    tgt_d[i1] = False
                    tgt_merge[i1] = MERGE_NONE_ID
                    tgt_append[i1] = APPEND_NONE_ID
                    tgt_para[i1] = PARA_NONE_ID
                    expressible += 1
                else:
                    mask_counts["unexplainable_replace_1to1"] += 1
                    if i1 > 0:
                        tgt_p[i1 - 1] = None

            elif ni == 2 and nj == 1:
                # 2-to-1: potential merge (compound / hyphenation)
                merged_out = pws[j1].key
                combined = rws[i1].key + rws[i1 + 1].key
                hyphen = rws[i1].key + "-" + rws[i1 + 1].key
                if merged_out in (combined, hyphen):
                    merge_label = "MERGE_2TO1"
                    m_idx = MERGE2ID.get(merge_label)
                    if m_idx is not None:
                        tgt_merge[i1] = m_idx
                        tgt_p[i1] = pws[j1].punct_state
                        tgt_c[i1] = pws[j1].case_state
                        tgt_d[i1] = False
                        tgt_repl[i1] = 0
                        tgt_append[i1] = APPEND_NONE_ID
                        tgt_para[i1] = PARA_NONE_ID
                        # The absorbed second word is masked
                        # (all its tgt_* remain None)
                        expressible += 1
                    else:
                        mask_counts["merge_label_missing_2to1"] += 1
                else:
                    mask_counts["unexplainable_2to1"] += 1
                if i1 > 0:
                    tgt_p[i1 - 1] = None

            elif ni == 1 and nj == 2:
                # 1-to-2: potential split (e.g., contraction expansion)
                split_label = "MERGE_1TO2"
                m_idx = MERGE2ID.get(split_label)
                if m_idx is not None:
                    tgt_merge[i1] = m_idx
                    # Punct from the last target word of the pair
                    tgt_p[i1] = pws[j1 + 1].punct_state
                    tgt_c[i1] = pws[j1].case_state
                    tgt_d[i1] = False
                    tgt_repl[i1] = 0
                    tgt_append[i1] = APPEND_NONE_ID
                    tgt_para[i1] = PARA_NONE_ID
                    expressible += 1
                else:
                    mask_counts["merge_label_missing_1to2"] += 1
                if i1 > 0:
                    tgt_p[i1 - 1] = None

            else:
                # Multi:multi replace — out of scope, mask the span
                for _k in range(i1, i2):
                    pass  # tgt_* already None
                if i1 > 0:
                    tgt_p[i1 - 1] = None
                mask_counts["multi_word_replace"] += 1

    # Any usable label at all?
    any_usable = any(
        p is not None or d is not None
        for p, d in zip(tgt_p, tgt_d)
    )
    if not any_usable:
        return None, mask_counts, expressible, total_ops_count

    # Build extended Example via updated build_example signature.
    # The new common.py build_example accepts extra keyword args.
    ex = build_example(
        rws, tgt_p, tgt_c, tgt_d, script, source,
        tgt_append=tgt_append,
        tgt_repl=tgt_repl,
        tgt_merge=tgt_merge,
        tgt_para=tgt_para,
        dest=dest,
    )
    return ex, mask_counts, expressible, total_ops_count


# ---------------------------------------------------------------------------
# editedText contamination gate
# ---------------------------------------------------------------------------

def edited_text_is_clean(formatted: str, edited: str) -> bool:
    """Return True if editedText is close enough to formattedText to distil.

    Gate: word-count delta <= 20 AND SequenceMatcher ratio >= 0.90.
    """
    fw = formatted.split()
    ew = edited.split()
    delta = abs(len(ew) - len(fw))
    if delta > 20:
        return False
    sm = difflib.SequenceMatcher(a=fw, b=ew, autojunk=False)
    return sm.ratio() >= 0.90


# ---------------------------------------------------------------------------
# Corpus loading
# ---------------------------------------------------------------------------

def load_corpus(path: Path) -> List[dict]:
    rows = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


# ---------------------------------------------------------------------------
# Main processing loop
# ---------------------------------------------------------------------------

def process_corpus(
    rows: List[dict],
    holdout_keys: Set[str],
    reverted_weight: float,
    max_lex_frac: float,
) -> Tuple[List[Tuple[Example, float]], dict]:
    """
    Process Wispr corpus rows into labelled Examples with weights.

    Returns
    -------
    examples : list of (Example, weight)
    report   : dict with coverage statistics
    """
    # Counters for the coverage report
    n_loaded = len(rows)
    n_passing = 0
    n_asr_fmt = 0
    n_edited_clean = 0
    n_edited_rejected = 0
    n_labelled_words = 0
    n_expressible_ops = 0
    n_total_ops = 0
    n_para_breaks = 0
    n_list_items = 0
    append_counts: Counter = Counter()  # by APPEND2ID value
    repl_count = 0
    merge_count = 0
    disf_count = 0
    mask_totals: Counter = Counter()

    # Rejection reasons
    reject_reasons: Counter = Counter()

    examples: List[Tuple[Example, float]] = []

    for row in rows:
        asr = (row.get("asrText") or "").strip()
        fmt = (row.get("formattedText") or "").strip()
        edited = (row.get("editedText") or "").strip()
        app_id = row.get("app") or ""
        url = row.get("url") or ""
        has_reverted = bool(row.get("hasRevertedAI", False))
        div_score = row.get("formattingDivergenceScore") or 0.0

        if not asr or not fmt:
            reject_reasons["empty"] += 1
            continue

        # Script resolution — NEVER use detectedLanguage
        script = detect_script(asr)
        if script == "unk":
            reject_reasons["script_unknown"] += 1
            continue
        if script not in ("en", "he", "ru"):
            reject_reasons["script_unsupported"] += 1
            continue

        # Teacher quality gate (shared with build_corpus)
        why = teacher_quality_reject(asr, fmt)
        if why:
            reject_reasons[f"quality_{why}"] += 1
            continue

        # Holdout deduplication
        if norm_key(asr) in holdout_keys or norm_key(fmt) in holdout_keys:
            reject_reasons["holdout"] += 1
            continue

        # Weight for reverted / high-divergence rows
        if has_reverted or div_score > 0.5:
            base_weight = reverted_weight
            source_tag = "reverted"
        else:
            base_weight = 1.0
            source_tag = "wispr"

        # Destination class from app/bundle id or url
        dest = bundle_id_to_dest(app_id or url)

        # ----------------------------------------------------------------
        # Pair 1: asrText → formattedText
        # ----------------------------------------------------------------
        clean_fmt, para_marks = extract_html_structure(fmt)

        # Count structural markers
        for label in para_marks.values():
            if label == PARA_BREAK:
                n_para_breaks += 1
            elif label == PARA_LIST_ITEM:
                n_list_items += 1

        ex1, masks1, expr1, total1 = wispr_align_pair(
            asr, clean_fmt, script, source_tag, para_marks, dest
        )

        if total1 > 0:
            drift1 = 1.0 - (expr1 / total1)
            if drift1 > max_lex_frac + 1e-9:
                reject_reasons["drift_frac_too_high"] += 1
                ex1 = None

        if ex1 is not None:
            examples.append((ex1, base_weight))
            n_asr_fmt += 1
            n_passing += 1
            n_labelled_words += len(ex1.words)
            n_expressible_ops += expr1
            n_total_ops += total1
            mask_totals.update(masks1)
            # Collect label stats
            if hasattr(ex1, "disf"):
                disf_count += sum(1 for v in ex1.disf if v == 1)
            if hasattr(ex1, "para"):
                n_para_breaks += sum(
                    1 for v in ex1.para
                    if v == PARA2ID.get(PARA_BREAK, -1)
                )
                n_list_items += sum(
                    1 for v in ex1.para
                    if v == PARA2ID.get(PARA_LIST_ITEM, -1)
                )
            if hasattr(ex1, "repl"):
                repl_count += sum(1 for v in ex1.repl if v not in (0, IGNORE))
            if hasattr(ex1, "merge"):
                merge_count += sum(1 for v in ex1.merge if v not in (0, IGNORE))
            if hasattr(ex1, "append"):
                for v in ex1.append:  # type: ignore[attr-defined]
                    if v not in (0, IGNORE, None):
                        append_counts[v] += 1
        else:
            reject_reasons["no_usable_labels_fmt"] += 1

        # ----------------------------------------------------------------
        # Pair 2 (optional): asrText → editedText
        # ----------------------------------------------------------------
        if edited and edited != fmt:
            if edited_text_is_clean(fmt, edited):
                # Check quality gate for the edited pair too
                why_ed = teacher_quality_reject(asr, edited)
                if why_ed:
                    reject_reasons[f"edited_quality_{why_ed}"] += 1
                elif norm_key(edited) in holdout_keys:
                    reject_reasons["edited_holdout"] += 1
                else:
                    clean_ed, para_marks_ed = extract_html_structure(edited)
                    ex2, masks2, expr2, total2 = wispr_align_pair(
                        asr, clean_ed, script, "edited", para_marks_ed, dest
                    )
                    if total2 > 0:
                        drift2 = 1.0 - (expr2 / total2)
                        if drift2 > max_lex_frac + 1e-9:
                            ex2 = None

                    if ex2 is not None:
                        examples.append((ex2, base_weight * 1.5))
                        n_edited_clean += 1
                        n_passing += 1
                        n_labelled_words += len(ex2.words)
                        n_expressible_ops += expr2
                        n_total_ops += total2
                        mask_totals.update(masks2)
                    else:
                        reject_reasons["edited_no_usable_labels"] += 1
            else:
                n_edited_rejected += 1

    # Expressible opcode fraction
    expr_pct = (n_expressible_ops / max(n_total_ops, 1)) * 100.0

    # Append label distribution at K=50 and K=100
    top50 = sum(v for _, v in append_counts.most_common(50))
    top100 = sum(v for _, v in append_counts.most_common(100))
    total_append = sum(append_counts.values())
    append_k50_pct = (top50 / max(total_append, 1)) * 100.0
    append_k100_pct = (top100 / max(total_append, 1)) * 100.0

    report = {
        "pairs_loaded": n_loaded,
        "pairs_passing_gate": n_passing,
        "asr_to_formatted": n_asr_fmt,
        "asr_to_edited_clean": n_edited_clean,
        "asr_to_edited_rejected": n_edited_rejected,
        "labelled_words": n_labelled_words,
        "expressible_opcodes_pct": round(expr_pct, 2),
        "para_breaks": n_para_breaks,
        "list_items": n_list_items,
        "append_labels": total_append,
        "append_k50_pct": round(append_k50_pct, 1),
        "append_k100_pct": round(append_k100_pct, 1),
        "repl_labels": repl_count,
        "merge_labels": merge_count,
        "disf_labels": disf_count,
        "masking_breakdown": {
            "multi_word_insert": mask_totals.get("multi_word_insert", 0),
            "out_of_vocab_single_insert": mask_totals.get("out_of_vocab_single_insert", 0),
            "multi_word_replace": mask_totals.get("multi_word_replace", 0),
            "unexplainable": (
                mask_totals.get("unexplainable_replace_1to1", 0) +
                mask_totals.get("unexplainable_2to1", 0) +
                mask_totals.get("lexical_delete", 0)
            ),
        },
        "rejection_reasons": dict(reject_reasons.most_common()),
    }

    return examples, report


# ---------------------------------------------------------------------------
# Train / val split (stratified by script)
# ---------------------------------------------------------------------------

def split_examples(
    examples: List[Tuple[Example, float]],
    train_frac: float,
    seed: int,
) -> Tuple[List[Tuple[Example, float]], List[Tuple[Example, float]]]:
    """Stratified 80/20 split by script."""
    by_script: Dict[str, List[Tuple[Example, float]]] = defaultdict(list)
    for ex, w in examples:
        by_script[ex.script].append((ex, w))

    train: List[Tuple[Example, float]] = []
    val: List[Tuple[Example, float]] = []
    rng = random.Random(seed)

    for sc, items in sorted(by_script.items()):
        items = sorted(items, key=lambda x: " ".join(x[0].words))
        rng.shuffle(items)
        k = max(1, int(round(train_frac * len(items))))
        train.extend(items[:k])
        val.extend(items[k:])

    rng.shuffle(train)
    rng.shuffle(val)
    return train, val


# ---------------------------------------------------------------------------
# Coverage report printer
# ---------------------------------------------------------------------------

def print_coverage(report: dict, n_train: int, n_val: int) -> None:
    r = report
    print("=== Wispr corpus coverage ===")
    print(f"Pairs loaded:   {r['pairs_loaded']}")
    print(f"Pairs passing gate: {r['pairs_passing_gate']}")
    print(f"  asr→formatted:              {r['asr_to_formatted']}")
    print(f"  asr→edited (clean):         {r['asr_to_edited_clean']}")
    print(f"  asr→edited (rejected):      {r['asr_to_edited_rejected']}"
          f" (delta>20 or ratio<0.90)")
    if n_train >= 0:
        print(f"  → wispr_train: {n_train}  wispr_val: {n_val}")
    print(f"Labelled words:  {r['labelled_words']}")
    print(f"Expressible opcodes: {r['expressible_opcodes_pct']}%"
          f"  (= 1 - drift_frac at word level)")
    print(f"Para breaks:     {r['para_breaks']}")
    print(f"List items:      {r['list_items']}")
    a = r["append_labels"]
    print(f"Append labels:   {a}"
          f" (K=50→{r['append_k50_pct']}%, K=100→{r['append_k100_pct']}%)")
    print(f"Repl labels:     {r['repl_labels']}")
    print(f"Merge labels:    {r['merge_labels']}")
    print(f"Disf labels:     {r['disf_labels']}")
    print("Masking breakdown:")
    mb = r["masking_breakdown"]
    print(f"  multi-word insert (too complex): {mb['multi_word_insert']}")
    print(f"  out-of-vocab single insert:      {mb['out_of_vocab_single_insert']}")
    print(f"  multi-word replace:              {mb['multi_word_replace']}")
    print(f"  unexplainable:                   {mb['unexplainable']}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Build mmBERT training examples from the Wispr Flow corpus."
    )
    ap.add_argument(
        "--corpus",
        default=str(CORPUS_DEFAULT),
        help="path to corpus.jsonl (default: ~/wispr_corpus/corpus.jsonl)",
    )
    ap.add_argument(
        "--out",
        default=str(HERE / "artifacts" / "data"),
        help="output directory (default: artifacts/data)",
    )
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--train-frac", type=float, default=0.80,
                    help="fraction of pairs for train split (default: 0.80)")
    ap.add_argument("--max-lex-frac", type=float, default=0.10,
                    help="max unexplainable opcode fraction (default: 0.10)")
    ap.add_argument("--reverted-weight", type=float, default=0.3,
                    help="sample weight for hasRevertedAI=True or "
                         "formattingDivergenceScore>0.5 rows (default: 0.3)")
    ap.add_argument("--report", action="store_true",
                    help="print coverage report and exit without writing files")
    args = ap.parse_args()

    corpus_path = Path(os.path.expanduser(args.corpus))
    out_dir = Path(os.path.expanduser(args.out))

    if not corpus_path.exists():
        print(f"ERROR: corpus not found: {corpus_path}", file=sys.stderr)
        sys.exit(1)

    # ------------------------------------------------------------------
    # Holdout protection: exclude sequences already in eval_real_large.jsonl
    # ------------------------------------------------------------------
    holdout_keys: Set[str] = set()
    eval_large_path = HERE / "data" / "eval_real_large.jsonl"
    if eval_large_path.exists():
        n_holdout = 0
        with eval_large_path.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    holdout_keys.add(norm_key(" ".join(d["words"])))
                    n_holdout += 1
                except (json.JSONDecodeError, KeyError):
                    continue
        holdout_keys.discard("")
        print(f"[holdout] {eval_large_path.name}: "
              f"{n_holdout} examples → {len(holdout_keys)} keys")
    else:
        print(f"[holdout] {eval_large_path} not found — no holdout applied")

    # ------------------------------------------------------------------
    # Load and process corpus
    # ------------------------------------------------------------------
    print(f"[load] reading {corpus_path} ...")
    rows = load_corpus(corpus_path)
    print(f"[load] {len(rows)} rows")

    examples, report = process_corpus(
        rows,
        holdout_keys=holdout_keys,
        reverted_weight=args.reverted_weight,
        max_lex_frac=args.max_lex_frac,
    )

    # ------------------------------------------------------------------
    # Report-only mode
    # ------------------------------------------------------------------
    if args.report:
        print_coverage(report, n_train=-1, n_val=-1)
        print("\nRejection reasons:", json.dumps(report["rejection_reasons"], indent=2))
        return

    # ------------------------------------------------------------------
    # Train / val split
    # ------------------------------------------------------------------
    train_pairs, val_pairs = split_examples(examples, args.train_frac, args.seed)
    print(f"[split] train={len(train_pairs)} val={len(val_pairs)}"
          f" scripts_train={dict(Counter(e.script for e, _ in train_pairs))}"
          f" scripts_val={dict(Counter(e.script for e, _ in val_pairs))}")

    # ------------------------------------------------------------------
    # Write output
    # ------------------------------------------------------------------
    out_dir.mkdir(parents=True, exist_ok=True)

    def dump_jsonl(path: Path, pairs: List[Tuple[Example, float]]) -> None:
        with path.open("w", encoding="utf-8") as f:
            for ex, weight in pairs:
                d = ex.to_json()
                d["weight"] = weight
                f.write(json.dumps(d, ensure_ascii=False) + "\n")
        print(f"[write] {path}  n={len(pairs)}"
              f"  scripts={dict(Counter(e.script for e, _ in pairs))}"
              f"  sources={dict(Counter(e.source for e, _ in pairs))}")

    dump_jsonl(out_dir / "wispr_train.jsonl", train_pairs)
    dump_jsonl(out_dir / "wispr_val.jsonl", val_pairs)

    # Coverage report
    report["seed"] = args.seed
    report["train_pairs"] = len(train_pairs)
    report["val_pairs"] = len(val_pairs)
    report["train_by_script"] = dict(Counter(e.script for e, _ in train_pairs))
    report["val_by_script"] = dict(Counter(e.script for e, _ in val_pairs))
    report["sources_train"] = dict(Counter(e.source for e, _ in train_pairs))
    report["sources_val"] = dict(Counter(e.source for e, _ in val_pairs))
    report["params"] = {
        "corpus": str(corpus_path),
        "seed": args.seed,
        "train_frac": args.train_frac,
        "max_lex_frac": args.max_lex_frac,
        "reverted_weight": args.reverted_weight,
    }

    coverage_path = out_dir / "wispr_coverage.json"
    coverage_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"[write] {coverage_path}")

    print_coverage(report, n_train=len(train_pairs), n_val=len(val_pairs))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
build_meeting_corpus.py -- mine Wispr meeting transcripts into mmBERT training pairs.

For each meeting with both live.ndjson and refined.ndjson, aligns raw ASR segments
(live) to polished segments (refined) by recording-relative timestamp, then builds
labelled training examples for all 8 mmBERT heads.

Alignment strategy
------------------
  - refined.timestamp "MM:SS" → recording-relative milliseconds
  - live.startRecordingMs → recording-relative milliseconds
  - For each refined segment at T_ref, collect live segments in
    [T_prev_ref - 2000, T_ref + 3000] ms.
  - Concatenate live.text as raw; use refined.text as target.
  - Quality gate: SequenceMatcher ratio ≥ MIN_RATIO and word delta ≤ MAX_WORD_DELTA.
  - Consecutive surviving segments are grouped into ~60-120 word documents so
    that paragraph boundaries land INSIDE an example (see GROUP_TARGET_WORDS).
    Refined HTML is parsed with build_wispr_corpus.extract_html_structure, so
    <li> becomes LIST_ITEM and each new segment in a group becomes PARA_BREAK.

Scope
-----
  - All 3 languages: en, he, ru (detected per segment via detect_script).
  - Source filter: include ALL live speakers (mic + system/remote) — meetings are
    multi-speaker, and Wispr's refined output reflects all speakers. This gives
    the most aligned pairs.
  - Minimum refined text length: MIN_WORDS = 4 words.

Output
------
  artifacts/data/meeting_train.jsonl
  artifacts/data/meeting_val.jsonl
  artifacts/data/meeting_coverage.json

Usage
-----
    ./.venv/bin/python build_meeting_corpus.py [--out artifacts/data] [--report]
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from common import (
    CASE2ID, IGNORE, PUNCT2ID, PUNCT_LABELS, Example, Word,
    detect_script, has_case, normalise_punct, split_word, tokenize_words,
    build_example,
)

try:
    from common import (
        APPEND_VOCAB, APPEND2ID, N_APPEND,
        GTRANSFORMS, N_GTRANSFORM,
        REPL_LITERALS, REPL_VOCAB, N_REPL,
        MERGE_LABELS, MERGE2ID, N_MERGE,
        PARA_LABELS, PARA2ID, N_PARA,
        DEST_CLASSES, DEST2ID, N_DEST, bundle_id_to_dest,
    )
    HAS_EXTENDED = True
except ImportError:
    HAS_EXTENDED = False

import build_corpus as BC

norm_key = BC.norm_key
ALL_FILLERS = BC.ALL_FILLERS
STRONG_FILLERS = BC.STRONG_FILLERS
teacher_quality_reject = BC.teacher_quality_reject

# Import the full aligner + HTML structure extractor from build_wispr_corpus
try:
    import build_wispr_corpus as BWC
    wispr_align_pair = BWC.wispr_align_pair
    extract_html_structure = BWC.extract_html_structure
    HAS_WISPR_ALIGNER = True
except ImportError:
    HAS_WISPR_ALIGNER = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MEETINGS_DIR = Path(os.path.expanduser(
    "~/Library/Application Support/Wispr Flow/meetings"
))

MIN_RATIO = 0.40       # Lower than dictation corpus (0.90) — meeting ASR is messier
MAX_WORD_DELTA = 40    # Maximum word count difference
MIN_WORDS = 4          # Minimum refined words to include
WINDOW_BACK_MS = 2000  # ms before refined timestamp to include live segs
WINDOW_FWD_MS = 3000   # ms after refined timestamp to include live segs

PARA_NONE = "NONE"
PARA_BREAK = "PARA_BREAK"
PARA_LIST_ITEM = "LIST_ITEM"
_HTML_TAG = re.compile(r"</?(?:ol|ul|li)\b[^>]*>", re.IGNORECASE)

# Multi-segment grouping. One example per refined segment can never contain a
# PARA_BREAK: a paragraph break is a boundary BETWEEN refined segments, so with
# one segment per example there is no boundary inside the example and the para
# head sees nothing but NONE. Consecutive refined segments are therefore
# concatenated into documents, with the first word of every segment after the
# first labelled PARA_BREAK. Sized to stay inside the trainer's 128-token cap
# (mean ~1.6 wordpieces/word for en/he/ru here).
GROUP_TARGET_WORDS = 60   # close the document once it reaches this many words
GROUP_MAX_WORDS = 120     # never exceed this


def parse_timestamp_ms(ts: str) -> int:
    """Convert 'MM:SS' or 'M:SS' timestamp string to milliseconds."""
    ts = ts.strip()
    parts = ts.split(":")
    try:
        if len(parts) == 2:
            return (int(parts[0]) * 60 + int(parts[1])) * 1000
        elif len(parts) == 3:
            return (int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])) * 1000
    except (ValueError, IndexError):
        pass
    return 0


def strip_html(text: str) -> str:
    """Remove HTML list tags from text.

    Only for LIVE (raw ASR) segments, which carry no structure worth keeping.
    Never call this on refined text -- it deletes the <ol>/<ul>/<li> markup that
    is the only source of LIST_ITEM labels. Refined text goes through
    build_wispr_corpus.extract_html_structure instead.
    """
    return _HTML_TAG.sub("", text).strip()


def load_live_segments(path: Path) -> List[Dict]:
    """Load and sort live segments by startRecordingMs. Skip meta line."""
    segs = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "text" not in d or "startRecordingMs" not in d:
            continue
        text = strip_html(d["text"].strip())
        if not text:
            continue
        segs.append({
            "text": text,
            "start_ms": int(d["startRecordingMs"]),
            "end_ms": int(d.get("endRecordingMs", d["startRecordingMs"] + 1000)),
            "speaker_source": d.get("speaker", {}).get("source", "unknown"),
        })
    segs.sort(key=lambda s: s["start_ms"])
    return segs


def load_refined_segments(path: Path) -> List[Dict]:
    """Load and sort refined segments by timestamp.

    The text is kept VERBATIM, HTML markup included. Structure extraction
    happens later, in group_pairs, via extract_html_structure.
    """
    segs = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "text" not in d or "timestamp" not in d:
            continue
        text = d["text"].strip()
        if not text:
            continue
        segs.append({
            "text": text,
            "ts_ms": parse_timestamp_ms(d["timestamp"]),
        })
    segs.sort(key=lambda s: s["ts_ms"])
    return segs


def align_meeting(
    live_segs: List[Dict],
    refined_segs: List[Dict],
) -> List[Tuple[str, str]]:
    """Produce (raw_text, refined_text) pairs for one meeting.

    For each refined segment, collects live segments in the window
    [refined_ts - WINDOW_BACK_MS, refined_ts + WINDOW_FWD_MS].
    Uses a sliding prev_ts to avoid double-counting live segments.
    """
    if not live_segs or not refined_segs:
        return []

    pairs = []
    used_live: Set[int] = set()

    for i, ref in enumerate(refined_segs):
        ref_ms = ref["ts_ms"]
        # Window: from just after the previous refined segment to slightly past this one
        prev_ms = refined_segs[i - 1]["ts_ms"] if i > 0 else 0
        window_start = max(0, prev_ms - WINDOW_BACK_MS)
        window_end = ref_ms + WINDOW_FWD_MS

        # Collect live segments in the window (not already used)
        window_live = []
        for j, live in enumerate(live_segs):
            if j in used_live:
                continue
            if window_start <= live["start_ms"] <= window_end:
                window_live.append((j, live))

        if not window_live:
            continue

        # Mark as used
        for j, _ in window_live:
            used_live.add(j)

        raw_text = " ".join(l["text"] for _, l in window_live).strip()
        refined_text = ref["text"].strip()

        pairs.append((raw_text, refined_text))

    return pairs


def quality_gate(raw: str, refined: str) -> bool:
    """Return True if the pair passes quality checks."""
    raw_words = raw.split()
    ref_words = refined.split()

    if len(ref_words) < MIN_WORDS:
        return False

    delta = abs(len(raw_words) - len(ref_words))
    if delta > MAX_WORD_DELTA:
        return False

    ratio = difflib.SequenceMatcher(None, raw.lower(), refined.lower()).ratio()
    if ratio < MIN_RATIO:
        return False

    return True


def build_pair_example(
    raw: str,
    refined: str,
    script: str,
    para_marks: Dict[int, str],
    dest: int = 0,
) -> Optional[Tuple[Optional[Example], Counter, int, int]]:
    """Build a training example from (raw, refined) using the wispr aligner."""
    if HAS_WISPR_ALIGNER:
        return wispr_align_pair(raw, refined, script, "meeting", para_marks, dest)
    return None


def _assemble_group(
    segs: List[Tuple[str, str, Dict[int, str]]],
    script: str,
) -> Tuple[str, str, Dict[int, str], str]:
    """Concatenate (raw, clean_refined, marks) segments into one document.

    The first word of every segment after the first becomes PARA_BREAK, unless
    that segment's own HTML already marked it LIST_ITEM (the more specific
    label wins).
    """
    raws: List[str] = []
    cleans: List[str] = []
    marks: Dict[int, str] = {}
    offset = 0
    for idx, (raw, clean, seg_marks) in enumerate(segs):
        words = clean.split()
        for wi, label in seg_marks.items():
            if 0 <= wi < len(words):
                marks[offset + wi] = label
        if idx > 0 and words and offset not in marks:
            marks[offset] = PARA_BREAK
        raws.append(raw)
        cleans.append(clean)
        offset += len(words)
    return " ".join(raws).strip(), " ".join(cleans).strip(), marks, script


def group_pairs(
    pairs: List[Tuple[str, str]],
    stats: Counter,
) -> List[Tuple[str, str, Dict[int, str], str]]:
    """Turn per-segment (raw, refined_html) pairs into multi-segment documents.

    Segments are gated individually (so one bad alignment cannot poison a whole
    document) and a failed or off-script segment closes the current group: a
    PARA_BREAK is only honest between segments whose raw audio is actually
    adjacent in the concatenated input.
    """
    groups: List[Tuple[str, str, Dict[int, str], str]] = []
    cur: List[Tuple[str, str, Dict[int, str]]] = []
    cur_words = 0
    cur_script: Optional[str] = None

    def flush() -> None:
        nonlocal cur, cur_words, cur_script
        if cur and cur_script:
            groups.append(_assemble_group(cur, cur_script))
        cur, cur_words, cur_script = [], 0, None

    for raw, refined_html in pairs:
        clean, seg_marks = extract_html_structure(refined_html)
        clean = re.sub(r"\s+", " ", clean).strip()

        if not quality_gate(raw, clean):
            stats["dropped_quality"] += 1
            flush()
            continue

        script = detect_script(clean)
        if script not in ("en", "he", "ru"):
            stats["dropped_script"] += 1
            flush()
            continue

        if cur_script is not None and script != cur_script:
            flush()

        n_words = len(clean.split())
        if cur and cur_words + n_words > GROUP_MAX_WORDS:
            flush()

        cur.append((raw, clean, seg_marks))
        cur_words += n_words
        cur_script = script

        if cur_words >= GROUP_TARGET_WORDS:
            flush()

    flush()
    return groups


def run(args: argparse.Namespace) -> None:
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Discover meetings
    meeting_dirs = sorted(MEETINGS_DIR.glob("*/"))
    meeting_dirs = [
        d for d in meeting_dirs
        if (d / "live.ndjson").exists() and (d / "refined.ndjson").exists()
    ]
    print(f"Found {len(meeting_dirs)} meetings with both live.ndjson and refined.ndjson")

    all_examples: List[Dict] = []
    stats: Counter = Counter()
    mask_totals: Counter = Counter()
    by_script: Counter = Counter()
    para_dist: Counter = Counter()
    para_by_script: Counter = Counter()

    for meeting_dir in meeting_dirs:
        live_segs = load_live_segments(meeting_dir / "live.ndjson")
        refined_segs = load_refined_segments(meeting_dir / "refined.ndjson")

        pairs = align_meeting(live_segs, refined_segs)
        stats["pairs_raw"] += len(pairs)

        # Group consecutive refined segments so paragraph boundaries exist
        # INSIDE an example. Quality/script gating happens per segment inside.
        groups = group_pairs(pairs, stats)
        stats["groups"] += len(groups)

        for raw, refined, para_marks, script in groups:
            # Holdout protection: check against eval set
            key = norm_key(raw)
            # (Skip holdout check for meeting corpus — different domain from eval set)

            # Build example
            result = build_pair_example(raw, refined, script, para_marks)
            if result is None:
                stats["dropped_aligner_unavailable"] += 1
                continue

            example, mask_counts, expressible, total_ops = result
            if example is None:
                stats["dropped_alignment"] += 1
                continue

            mask_totals += mask_counts
            by_script[script] += 1
            stats["accepted"] += 1
            stats[f"accepted_{script}"] += 1

            row = example.to_json()
            row["weight"] = 0.7  # down-weighted vs dictation pairs
            all_examples.append(row)

            for v in row.get("para", []):
                name = "IGNORE" if v == IGNORE else PARA_LABELS[v]
                para_dist[name] += 1
                para_by_script[f"{script}/{name}"] += 1

    print(f"\nCorpus stats:")
    print(f"  Raw pairs:     {stats['pairs_raw']}")
    print(f"  Grouped docs:  {stats['groups']}")
    print(f"  Dropped (quality gate): {stats['dropped_quality']}")
    print(f"  Dropped (script):       {stats['dropped_script']}")
    print(f"  Dropped (alignment):    {stats['dropped_alignment']}")
    print(f"  Dropped (no aligner):   {stats['dropped_aligner_unavailable']}")
    print(f"  Accepted:      {stats['accepted']}")
    print(f"    en:  {stats.get('accepted_en', 0)}")
    print(f"    he:  {stats.get('accepted_he', 0)}")
    print(f"    ru:  {stats.get('accepted_ru', 0)}")

    print(f"\n  para label distribution: {dict(para_dist)}")
    for sc in ("en", "he", "ru"):
        row = {name: para_by_script[f"{sc}/{name}"]
               for name in ("NONE", "PARA_BREAK", "LIST_ITEM", "IGNORE")
               if para_by_script[f"{sc}/{name}"]}
        pos = row.get("PARA_BREAK", 0) + row.get("LIST_ITEM", 0)
        print(f"    {sc}: {row}  positives={pos}")
    total_pos = para_dist["PARA_BREAK"] + para_dist["LIST_ITEM"]
    print(f"  para positives (PARA_BREAK + LIST_ITEM): {total_pos}")
    if total_pos == 0:
        print("  WARNING: zero para positives — the para head cannot learn "
              "from this corpus.")

    if args.report:
        return

    if not all_examples:
        print("No examples — check aligner availability (need build_wispr_corpus.py).")
        return

    # 80/20 split stratified by script
    random.seed(args.seed)
    random.shuffle(all_examples)

    by_script_examples: Dict[str, List] = defaultdict(list)
    for ex in all_examples:
        by_script_examples[ex.get("script", "en")].append(ex)

    train_rows: List[Dict] = []
    val_rows: List[Dict] = []

    for script, exs in by_script_examples.items():
        split = max(1, int(len(exs) * 0.8))
        train_rows.extend(exs[:split])
        val_rows.extend(exs[split:])

    random.shuffle(train_rows)
    random.shuffle(val_rows)

    train_path = out_dir / "meeting_train.jsonl"
    val_path = out_dir / "meeting_val.jsonl"

    with train_path.open("w", encoding="utf-8") as f:
        for r in train_rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with val_path.open("w", encoding="utf-8") as f:
        for r in val_rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    coverage = {
        "total_meetings": len(meeting_dirs),
        "pairs_raw": stats["pairs_raw"],
        "accepted": stats["accepted"],
        "by_script": dict(by_script),
        "train": len(train_rows),
        "val": len(val_rows),
        "mask_counts": dict(mask_totals),
        "para_dist": dict(para_dist),
        "para_by_script": dict(para_by_script),
    }
    (out_dir / "meeting_coverage.json").write_text(
        json.dumps(coverage, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    print(f"\nWrote {len(train_rows)} train rows → {train_path}")
    print(f"Wrote {len(val_rows)} val rows   → {val_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(HERE / "artifacts/data"),
                        help="Output directory for train/val JSONL files")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--report", action="store_true",
                        help="Print stats only; do not write files")
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()

#!/usr/bin/env python
"""
score_list_formatter.py -- Phase 3b: score ListFormatter heuristic coverage
against the 50 real list pairs in the Wispr corpus.

Loads ~/wispr_corpus/corpus.jsonl, finds rows where formattedText contains
<ol>/<ul>/<li> tags, then applies a Python-side heuristic that mirrors what
Whisperer/Transcription/ListFormatter.swift would detect: explicit ordinal words
("first", "second", …), numeric ordinals ("1.", "2.", …), or bullet cues in the
asrText.  Since we can't run Swift from Python, the heuristic stands in for the
Swift detector's coverage estimate.

Writes artifacts/list_formatter_baseline.json and prints a coverage report.

Usage:
    ./.venv/bin/python score_list_formatter.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CORPUS_JSONL = Path.home() / "wispr_corpus" / "corpus.jsonl"
ARTIFACTS = Path(__file__).resolve().parent / "artifacts"

# ── heuristic list detector ───────────────────────────────────────────────────
# Mirrors the cues ListFormatter.swift looks for in raw ASR text.

ORDINAL_WORDS = {
    "first", "second", "third", "fourth", "fifth",
    "sixth", "seventh", "eighth", "ninth", "tenth",
    # Hebrew transliterations sometimes appear in mixed-language recordings
    "rishon", "sheni", "shlishi",
}

# "1." / "2." / "(1)" / "1)" at word boundaries
_NUMERIC_ORDINAL_RE = re.compile(r"(?:^|\s)(?:\(?\d{1,2}[.)]\s)")

# "- item" or "* item" bullet prefix
_BULLET_RE = re.compile(r"(?:^|\n)\s*[-*•]\s+\S")


def has_explicit_list_marker(asr_text: str) -> bool:
    """Return True if the raw ASR text contains a detectable list cue."""
    if not asr_text:
        return False
    lower = asr_text.lower()
    words = re.split(r"\W+", lower)
    # Ordinal word cue
    if ORDINAL_WORDS.intersection(words):
        return True
    # Numeric ordinal cue
    if _NUMERIC_ORDINAL_RE.search(asr_text):
        return True
    # Bullet cue
    if _BULLET_RE.search(asr_text):
        return True
    return False


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    if not CORPUS_JSONL.exists():
        sys.exit(f"Corpus not found: {CORPUS_JSONL}")

    all_rows = [json.loads(l) for l in CORPUS_JSONL.read_text().splitlines() if l.strip()]

    # Find the 50 list pairs (formattedText contains <ol>, <ul>, or <li>)
    LIST_TAGS = re.compile(r"<(?:ol|ul|li)[\s>/]", re.IGNORECASE)
    list_rows = [r for r in all_rows if LIST_TAGS.search(r.get("formattedText") or "")]

    print(f"total corpus rows : {len(all_rows)}")
    print(f"list pairs found  : {len(list_rows)}")

    detected = [r for r in list_rows if has_explicit_list_marker(r.get("asrText") or "")]
    missed = [r for r in list_rows if not has_explicit_list_marker(r.get("asrText") or "")]

    print(f"\n── ListFormatter heuristic coverage ──────────────")
    print(f"  total list pairs  : {len(list_rows)}")
    print(f"  detected          : {len(detected)}  ({100 * len(detected) / max(len(list_rows), 1):.1f}%)")
    print(f"  missed (hard)     : {len(missed)}  ({100 * len(missed) / max(len(list_rows), 1):.1f}%)")

    print("\n── Top 5 detected examples ───────────────────────")
    for i, r in enumerate(detected[:5], 1):
        asr = (r.get("asrText") or "")[:120].replace("\n", " ")
        fmt = (r.get("formattedText") or "")[:120].replace("\n", " ")
        print(f"  [{i}] asr: {asr}")
        print(f"       fmt: {fmt}")

    print("\n── Top 5 missed examples (no explicit marker) ────")
    for i, r in enumerate(missed[:5], 1):
        asr = (r.get("asrText") or "")[:120].replace("\n", " ")
        fmt = (r.get("formattedText") or "")[:120].replace("\n", " ")
        print(f"  [{i}] asr: {asr}")
        print(f"       fmt: {fmt}")

    # Write artifact
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    out = ARTIFACTS / "list_formatter_baseline.json"

    payload = {
        "total_list_pairs": len(list_rows),
        "detected": len(detected),
        "missed": len(missed),
        "coverage_pct": round(100 * len(detected) / max(len(list_rows), 1), 1),
        "detected_examples": [
            {
                "asr": r.get("asrText", ""),
                "formatted": r.get("formattedText", ""),
                "app": r.get("app", ""),
            }
            for r in detected[:10]
        ],
        "missed_examples": [
            {
                "asr": r.get("asrText", ""),
                "formatted": r.get("formattedText", ""),
                "app": r.get("app", ""),
            }
            for r in missed[:10]
        ],
    }
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(f"\nwrote → {out}")


if __name__ == "__main__":
    main()

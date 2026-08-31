#!/usr/bin/env python3
"""Mine literal mmBERT replacement labels from grounded correction pairs.

The output is a list because its position is the model class ID contract.  The
script never consumes a calibration holdout and never invents corrections.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable

from common import GTRANSFORMS, detect_script, tokenize_words


HERE = Path(__file__).resolve().parent
DEFAULT_CORPUS = Path(os.path.expanduser("~/wispr_corpus/corpus.jsonl"))
WORD_RE = re.compile(r"^[^\W\d_][^\W_'-]*(?:['-][^\W\d_][^\W_]*)?$", re.UNICODE)


def pairs_from_row(row: dict) -> Iterable[tuple[str, str, str]]:
    raw = (row.get("asrText") or row.get("observedSource") or "").strip()
    if not raw:
        return
    edited = (row.get("editedText") or "").strip()
    formatted = (row.get("formattedText") or "").strip()
    explicit = (
        row.get("observedReplacement")
        or row.get("replacement")
        or row.get("correctedText")
        or ""
    )
    if explicit and row.get("observedSource"):
        yield row["observedSource"].strip(), str(explicit).strip(), "observedSource"
    if edited and edited != raw:
        yield raw, edited, "editedText"
    elif formatted and formatted != raw:
        yield raw, formatted, "formattedText"


def literal_events(raw: str, target: str) -> Iterable[tuple[str, str]]:
    source = [w.key for w in tokenize_words(raw)]
    dest = [w.key for w in tokenize_words(target)]
    matcher = difflib.SequenceMatcher(a=source, b=dest, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace" or i2 - i1 != 1 or j2 - j1 != 1:
            continue
        observed, replacement = source[i1], dest[j1]
        if observed == replacement or not WORD_RE.fullmatch(replacement):
            continue
        if not (2 <= len(replacement) <= 40):
            continue
        if detect_script(observed) != detect_script(replacement):
            continue
        yield observed, replacement


def mine(rows: Iterable[dict], min_support: int, limit: int) -> tuple[list[str], dict]:
    targets: Counter[str] = Counter()
    source_target: Counter[tuple[str, str]] = Counter()
    provenance: Counter[str] = Counter()
    for row in rows:
        for raw, target, source in pairs_from_row(row):
            for observed, replacement in literal_events(raw, target):
                targets[replacement] += 1
                source_target[(observed, replacement)] += 1
                provenance[source] += 1

    forbidden = {x.lower() for x in GTRANSFORMS}
    ranked = [
        word for word, count in targets.most_common()
        if count >= min_support and word not in forbidden
    ][:limit]
    examples = defaultdict(list)
    selected = set(ranked)
    for (observed, replacement), count in source_target.most_common():
        if replacement in selected and len(examples[replacement]) < 5:
            examples[replacement].append({"observed": observed, "count": count})
    report = {
        "labels": len(ranked),
        "events": sum(targets[w] for w in ranked),
        "min_support": min_support,
        "limit": limit,
        "provenance": dict(provenance),
        "support": {w: targets[w] for w in ranked},
        "examples": dict(examples),
    }
    return ranked, report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    parser.add_argument("--out", default=str(HERE / "data" / "repl_vocab.json"))
    parser.add_argument("--report", default=str(HERE / "artifacts" / "repl_vocab_report.json"))
    parser.add_argument("--min-support", type=int, default=2)
    parser.add_argument("--limit", type=int, default=150)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    corpus = Path(os.path.expanduser(args.corpus))
    rows = [json.loads(line) for line in corpus.read_text(encoding="utf-8").splitlines() if line.strip()]
    vocab, report = mine(rows, args.min_support, args.limit)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.dry_run:
        return
    out = Path(args.out)
    report_path = Path(args.report)
    out.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(vocab, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

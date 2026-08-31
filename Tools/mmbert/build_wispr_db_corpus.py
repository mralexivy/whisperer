#!/usr/bin/env python
"""
build_wispr_db_corpus.py -- mine the Wispr Flow SQLite database into mmBERT training examples.

Reads directly from:
  ~/Library/Application Support/Wispr Flow/flow.sqlite

No FDA required (Wispr Flow is a Developer ID app, not sandboxed).

Applies filters:
  - status = 'formatted'
  - asrText IS NOT NULL AND asrText != ''
  - formattedText IS NOT NULL AND formattedText != ''
  - asrText != formattedText  (no-op rows have zero labels)
  - numWords >= 4             (short fragments yield nothing usable)
  - isArchived = 0

Outputs:
  artifacts/data/wispr_db_train.jsonl
  artifacts/data/wispr_db_val.jsonl
  artifacts/data/wispr_db_coverage.json

Labeling pipeline is identical to build_wispr_corpus.py (all 8 heads).
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from collections import Counter
from pathlib import Path
from typing import List, Set, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# ---------------------------------------------------------------------------
# Re-use ALL labeling logic from build_wispr_corpus.py
# ---------------------------------------------------------------------------
import build_wispr_corpus as WC  # noqa: E402

# Expose helpers from common via WC's imports
from common import detect_script  # noqa: E402

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

DB_DEFAULT = Path(os.path.expanduser(
    "~/Library/Application Support/Wispr Flow/flow.sqlite"
))

_QUERY = """
SELECT
    asrText,
    formattedText,
    editedText,
    app,
    url,
    COALESCE(hasRevertedAI, 0)        AS hasRevertedAI,
    COALESCE(formattingDivergenceScore, 0.0) AS formattingDivergenceScore
FROM History
WHERE
    status = 'formatted'
    AND asrText IS NOT NULL AND asrText != ''
    AND formattedText IS NOT NULL AND formattedText != ''
    AND asrText != formattedText
    AND COALESCE(numWords, 0) >= 4
    AND isArchived = 0
ORDER BY timestamp DESC
"""


def load_from_sqlite(db_path: Path) -> List[dict]:
    """Read History rows from flow.sqlite and return as list of dicts."""
    if not db_path.exists():
        print(f"ERROR: database not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = []
        for r in con.execute(_QUERY):
            rows.append({
                "asrText":                   r["asrText"],
                "formattedText":             r["formattedText"],
                "editedText":                r["editedText"],
                "app":                       r["app"] or "",
                "url":                       r["url"] or "",
                "hasRevertedAI":             bool(r["hasRevertedAI"]),
                "formattingDivergenceScore": float(r["formattingDivergenceScore"] or 0.0),
            })
        return rows
    finally:
        con.close()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Build mmBERT training examples from the Wispr Flow SQLite database."
    )
    ap.add_argument(
        "--db",
        default=str(DB_DEFAULT),
        help="path to flow.sqlite (default: ~/Library/Application Support/Wispr Flow/flow.sqlite)",
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
                    help="weight for hasRevertedAI=True or divScore>0.5 rows (default: 0.3)")
    ap.add_argument("--report", action="store_true",
                    help="print coverage report and exit without writing files")
    args = ap.parse_args()

    db_path = Path(os.path.expanduser(args.db))
    out_dir = Path(os.path.expanduser(args.out))

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
                    holdout_keys.add(WC.norm_key(" ".join(d["words"])))
                    n_holdout += 1
                except (json.JSONDecodeError, KeyError):
                    continue
        holdout_keys.discard("")
        print(f"[holdout] {eval_large_path.name}: "
              f"{n_holdout} examples → {len(holdout_keys)} keys")
    else:
        print(f"[holdout] {eval_large_path} not found — no holdout applied")

    # ------------------------------------------------------------------
    # Load from SQLite
    # ------------------------------------------------------------------
    print(f"[load] reading {db_path} ...")
    rows = load_from_sqlite(db_path)
    print(f"[load] {len(rows)} rows (status=formatted, numWords>=4, asrText!=formattedText)")

    # ------------------------------------------------------------------
    # Label using the identical pipeline from build_wispr_corpus.py
    # ------------------------------------------------------------------
    examples, report = WC.process_corpus(
        rows,
        holdout_keys=holdout_keys,
        reverted_weight=args.reverted_weight,
        max_lex_frac=args.max_lex_frac,
    )

    # ------------------------------------------------------------------
    # Report-only mode
    # ------------------------------------------------------------------
    if args.report:
        WC.print_coverage(report, n_train=-1, n_val=-1)
        print("\nRejection reasons:", json.dumps(report["rejection_reasons"], indent=2))
        return

    # ------------------------------------------------------------------
    # Train / val split (stratified by script)
    # ------------------------------------------------------------------
    train_pairs, val_pairs = WC.split_examples(examples, args.train_frac, args.seed)
    scripts_train = dict(Counter(e.script for e, _ in train_pairs))
    scripts_val   = dict(Counter(e.script for e, _ in val_pairs))
    print(f"[split] train={len(train_pairs)} val={len(val_pairs)}"
          f" scripts_train={scripts_train} scripts_val={scripts_val}")

    # ------------------------------------------------------------------
    # Write output
    # ------------------------------------------------------------------
    out_dir.mkdir(parents=True, exist_ok=True)

    def dump_jsonl(path: Path, pairs) -> None:
        with path.open("w", encoding="utf-8") as f:
            for ex, weight in pairs:
                d = ex.to_json()
                d["weight"] = weight
                f.write(json.dumps(d, ensure_ascii=False) + "\n")
        print(f"[write] {path}  n={len(pairs)}"
              f"  scripts={dict(Counter(e.script for e, _ in pairs))}"
              f"  sources={dict(Counter(e.source for e, _ in pairs))}")

    dump_jsonl(out_dir / "wispr_db_train.jsonl", train_pairs)
    dump_jsonl(out_dir / "wispr_db_val.jsonl",   val_pairs)

    # ------------------------------------------------------------------
    # Write coverage JSON for CI
    # ------------------------------------------------------------------
    report["n_train"] = len(train_pairs)
    report["n_val"]   = len(val_pairs)
    report["scripts_train"] = scripts_train
    report["scripts_val"]   = scripts_val
    cov_path = out_dir / "wispr_db_coverage.json"
    with cov_path.open("w") as f:
        json.dump(report, f, indent=2)
    print(f"[write] {cov_path}")

    WC.print_coverage(report, n_train=len(train_pairs), n_val=len(val_pairs))


if __name__ == "__main__":
    main()

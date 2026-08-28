#!/usr/bin/env python3
"""
emit_swift_table.py -- regenerate the baked `MMBERTCalibrationTable.measured` literal.

The Swift literal mirrors `thresholds-calibrated-*.json` and is guarded by
`EditingModelTests.testBakedTableIsNoLooserThanTheJSON`, which fails if the literal is
ever more permissive than the file. Until now the literal was maintained by hand, which
is why it could drift from the file in the first place. This script is the only supported
way to update it.

Usage:
    ./.venv/bin/python emit_swift_table.py \
        --json thresholds-calibrated-wispr.json \
        --swift ../../Whisperer/Transcription/Editing/MMBERTEditingModel.swift
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

BEGIN = "    static let measured = MMBERTCalibrationTable(cells: ["
END = "    ])"

# Mirrors MMBERTCalibrationTable.Head. A head the Swift enum cannot spell is dropped
# rather than emitted, because `Head(rawValue:)` would silently skip it at decode time
# and the literal must say exactly what the runtime would load.
SWIFT_HEADS = {"error", "punct", "case", "disf", "append", "repl", "merge", "para"}


def fmt(value, kind):
    if value is None:
        return "nil"
    if kind == "int":
        return str(int(value))
    if kind == "bool":
        return "true" if value else "false"
    return repr(float(value))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", required=True)
    ap.add_argument("--swift", required=True)
    ap.add_argument("--check", action="store_true",
                    help="Exit 1 if the file is out of date; write nothing.")
    args = ap.parse_args()

    doc = json.loads(Path(args.json).read_text())
    if doc.get("schema") != 2:
        raise SystemExit(f"{args.json}: schema {doc.get('schema')}, this emitter writes 2")

    lines, enabled_by_head, per_lang = [], Counter(), {}
    for cell in doc["cells"].values():
        head = cell["head"]
        if head not in SWIFT_HEADS:
            continue
        key = f'{cell["language"]}/{head}/{cell["action"]}'
        lines.append(
            f'        "{key}": Cell('
            f'threshold: {fmt(cell.get("threshold"), "f")}, '
            f'enabled: {fmt(cell.get("enabled"), "bool")}, '
            f'precision: {fmt(cell.get("precision"), "f")}, '
            f'support: {fmt(cell.get("support"), "int")}, '
            f'precisionLCB95: {fmt(cell.get("precision_lcb95"), "f")}),'
        )
        if cell.get("enabled"):
            enabled_by_head[head] += 1
            per_lang.setdefault(cell["language"], []).append(f'{head}/{cell["action"]}')

    lines.sort()
    total_enabled = sum(enabled_by_head.values())
    summary = "; ".join(f"{lang}: {', '.join(sorted(a))}" for lang, a in sorted(per_lang.items()))

    swift_path = Path(args.swift)
    src = swift_path.read_text()
    start = src.index(BEGIN)
    end = src.index(END, start) + len(END)
    body = "\n".join([BEGIN] + lines + [END])

    if src[start:end] == body:
        print(f"up to date: {total_enabled} enabled cell(s)")
        return
    if args.check:
        raise SystemExit(
            f"{swift_path} is out of date with {args.json}. "
            f"Re-run emit_swift_table.py without --check.")

    swift_path.write_text(src[:start] + body + src[end:])
    print(f"wrote {len(lines)} cells to {swift_path}")
    print(f"  {total_enabled} enabled: {summary or '(none)'}")
    print(f"  by head: {dict(enabled_by_head)}")
    for head in sorted(SWIFT_HEADS):
        if not enabled_by_head[head]:
            print(f"  note: {head} has no enabled cell — that class stays unreachable")


if __name__ == "__main__":
    main()

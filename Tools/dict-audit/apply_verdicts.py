#!/usr/bin/env python3
"""
apply_verdicts.py — Phase 3 of the rule audit.

Reads verdict files from verdicts/ (one per pack, produced by the LLM audit
subagents) and rewrites the pack JSONs in Whisperer/Resources/dictionaries/.

Verdict file format (verdicts/pack_NN_*.json):
  [
    {
      "alias": str,        # lowercased alias (matches emit_batches output)
      "term": str,         # the correct form
      "pack": str,         # pack stem
      "verdict": str,      # KEEP | DROP | REWRITE | DEDUPE
      "reason": str,       # one-line justification
      "new_alias": str     # only for REWRITE — the replacement alias to use
    },
    ...
  ]

For DEDUPE rows, the verdict file must also include which term to keep
in the "term" field.

After rewriting:
  - version bumped to "2.0.0" for every pack
  - audit-report.md written with every DROP/REWRITE/DEDUPE and its reason
  - check_packs.py is run to validate invariants
"""

import json
import pathlib
import re
import subprocess
import sys
from collections import defaultdict

PACKS_DIR = pathlib.Path(__file__).parent.parent.parent / "Whisperer/Resources/dictionaries"
VERDICTS_DIR = pathlib.Path(__file__).parent / "verdicts"
REPORT_FILE = pathlib.Path(__file__).parent / "audit-report.md"
SCRIPT_DIR = pathlib.Path(__file__).parent


def load_verdicts() -> dict[str, dict]:
    """Load all verdict files. Returns alias_lower -> verdict dict."""
    if not VERDICTS_DIR.exists():
        print(f"ERROR: verdicts/ directory not found at {VERDICTS_DIR}", file=sys.stderr)
        sys.exit(1)

    all_verdicts: dict[str, dict] = {}
    for vf in sorted(VERDICTS_DIR.glob("*.json")):
        with open(vf) as f:
            rows = json.load(f)
        for row in rows:
            key = (row["alias"].lower(), row["pack"])
            all_verdicts[key] = row

    return all_verdicts


def load_packs() -> list[tuple[pathlib.Path, dict]]:
    packs = []
    for p in sorted(PACKS_DIR.glob("pack_*.json")):
        with open(p) as f:
            packs.append((p, json.load(p.open())))
    return packs


def main() -> None:
    verdicts = load_verdicts()
    packs = load_packs()

    report_lines: list[str] = [
        "# Dictionary Audit Report\n",
        "Rules dropped, rewritten, or deduped by the LLM audit.\n",
    ]
    total_dropped = 0
    total_rewritten = 0
    total_deduped = 0
    total_kept = 0

    for pack_path, pack_data in packs:
        stem = pack_path.stem
        category = pack_data["metadata"]["category"]
        report_lines.append(f"\n## {stem} — {category}\n")

        new_corrections = []
        for correction in pack_data["corrections"]:
            term = correction["term"]
            new_aliases: list[str] = []

            for alias in correction["aliases"]:
                al = alias.lower()
                key = (al, stem)
                verdict_row = verdicts.get(key)

                if verdict_row is None:
                    # No verdict = KEEP (unaudited — shouldn't happen after a full run)
                    new_aliases.append(alias)
                    total_kept += 1
                    continue

                v = verdict_row["verdict"].upper()
                reason = verdict_row.get("reason", "")

                if v == "KEEP":
                    new_aliases.append(alias)
                    total_kept += 1

                elif v == "DROP":
                    report_lines.append(f"- **DROP** `{al}` → `{term}`: {reason}\n")
                    total_dropped += 1

                elif v == "REWRITE":
                    new_alias = verdict_row.get("new_alias", "").strip()
                    if new_alias:
                        new_aliases.append(new_alias)
                        report_lines.append(
                            f"- **REWRITE** `{al}` → `{new_alias}` (→ `{term}`): {reason}\n"
                        )
                        total_rewritten += 1
                    else:
                        # Treat as DROP if no replacement given
                        report_lines.append(f"- **DROP** (no new_alias) `{al}` → `{term}`: {reason}\n")
                        total_dropped += 1

                elif v == "DEDUPE":
                    # Keep only if this pack's term is the chosen winner
                    chosen_term = verdict_row.get("term", term)
                    if chosen_term == term:
                        new_aliases.append(alias)
                        report_lines.append(
                            f"- **DEDUPE/KEEP** `{al}` → `{term}` (winner): {reason}\n"
                        )
                    else:
                        report_lines.append(
                            f"- **DEDUPE/DROP** `{al}` → `{term}` (loser, winner=`{chosen_term}`): {reason}\n"
                        )
                    total_deduped += 1

                else:
                    # Unknown verdict — treat as KEEP with warning
                    print(f"WARNING: unknown verdict {v!r} for {al!r} in {stem}", file=sys.stderr)
                    new_aliases.append(alias)
                    total_kept += 1

            if new_aliases:
                new_corrections.append({"term": term, "aliases": new_aliases})
            # If no aliases remain, the term is silently dropped from this pack.

        # Bump version and update entry count
        pack_data["corrections"] = new_corrections
        pack_data["metadata"]["version"] = "2.0.0"
        total_count = sum(len(c["aliases"]) for c in new_corrections)
        if "totalEntries" in pack_data["metadata"]:
            pack_data["metadata"]["totalEntries"] = total_count
        if "totalCorrections" in pack_data["metadata"]:
            pack_data["metadata"]["totalCorrections"] = len(new_corrections)

        with open(pack_path, "w") as f:
            json.dump(pack_data, f, indent=2, ensure_ascii=False)
            f.write("\n")

        print(f"  Rewrote {stem}: {total_count} aliases remaining")

    # Write audit report
    report_lines.append(f"\n---\n")
    report_lines.append(
        f"\n**Summary:** {total_kept} KEEP, {total_dropped} DROP, "
        f"{total_rewritten} REWRITE, {total_deduped} DEDUPE\n"
    )
    REPORT_FILE.write_text("".join(report_lines), encoding="utf-8")
    print(f"\nAudit report: {REPORT_FILE}")
    print(f"Summary: {total_kept} KEEP | {total_dropped} DROP | {total_rewritten} REWRITE | {total_deduped} DEDUPE")

    # Run invariant check
    print("\nRunning check_packs.py…")
    result = subprocess.run(
        [sys.executable, str(SCRIPT_DIR / "check_packs.py")],
        capture_output=False,
    )
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()

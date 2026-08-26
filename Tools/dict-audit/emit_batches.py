#!/usr/bin/env python3
"""
emit_batches.py — Phase 1 of the rule audit.

Reads all 12 built-in pack JSONs, pre-computes deterministic flags for each
alias, and writes one batch file per pack to batches/.

Each row in a batch file:
  {
    "alias": str,          # the misspelled form (lowercased)
    "term": str,           # the correct replacement
    "pack": str,           # pack filename stem (e.g. "pack_01_languages_frameworks")
    "flags": [str, ...]    # zero or more of the flag strings below
  }

Flags (NOT verdicts — these are inputs for the LLM auditor):
  all_english          — every space-separated token is in /usr/share/dict/words
  single_word_english  — exactly one token and it's in the dictionary (highest risk)
  conflict             — this alias maps to ≥2 different terms across packs
  identity             — alias == term case-insensitively (no-op rule)
  substring_of_term    — alias (lowercased) is a substring of term (lowercased)
                         (risks matching its own replacement output)
"""

import json
import pathlib
import re
import sys
from collections import defaultdict

PACKS_DIR = pathlib.Path(__file__).parent.parent.parent / "Whisperer/Resources/dictionaries"
BATCHES_DIR = pathlib.Path(__file__).parent / "batches"
WORDS_FILE = pathlib.Path("/usr/share/dict/words")


def load_words() -> set:
    with open(WORDS_FILE) as f:
        return {w.strip().lower() for w in f if w.strip()}


def load_packs() -> list[tuple[str, dict]]:
    packs = []
    for p in sorted(PACKS_DIR.glob("pack_*.json")):
        with open(p) as f:
            packs.append((p.stem, json.load(f)))
    return packs


def compute_conflict_map(packs: list[tuple[str, dict]]) -> dict[str, set]:
    """alias_lower -> set of distinct correct terms across all packs."""
    alias_to_terms: dict[str, set] = defaultdict(set)
    for _stem, pack in packs:
        for correction in pack["corrections"]:
            term = correction["term"]
            for alias in correction["aliases"]:
                alias_to_terms[alias.lower()].add(term)
    return alias_to_terms


def main() -> None:
    words = load_words()
    packs = load_packs()
    alias_to_terms = compute_conflict_map(packs)

    BATCHES_DIR.mkdir(exist_ok=True)

    total = 0
    for stem, pack in packs:
        rows = []
        for correction in pack["corrections"]:
            term = correction["term"]
            for alias in correction["aliases"]:
                alias_lower = alias.lower()
                tokens = re.findall(r"[a-z]+", alias_lower)

                flags = []

                # all_english / single_word_english
                if tokens and all(t in words for t in tokens):
                    flags.append("all_english")
                    if len(tokens) == 1:
                        flags.append("single_word_english")

                # conflict
                if len(alias_to_terms[alias_lower]) > 1:
                    flags.append("conflict")

                # identity
                if alias_lower == term.lower():
                    flags.append("identity")

                # substring_of_term
                if alias_lower and alias_lower in term.lower():
                    flags.append("substring_of_term")

                rows.append({
                    "alias": alias_lower,
                    "term": term,
                    "pack": stem,
                    "flags": flags,
                })

        out = BATCHES_DIR / f"{stem}.json"
        with open(out, "w") as f:
            json.dump(rows, f, indent=2, ensure_ascii=False)
        print(f"  {stem}: {len(rows)} aliases → {out.name}")
        total += len(rows)

    print(f"\nTotal aliases emitted: {total}")
    flagged = sum(1 for _, p in packs for c in p["corrections"] for a in c["aliases"]
                  if any(True for _ in [None]))  # placeholder
    # count properly
    all_rows = []
    for p in BATCHES_DIR.glob("pack_*.json"):
        with open(p) as f:
            all_rows.extend(json.load(f))
    c_english = sum(1 for r in all_rows if "all_english" in r["flags"])
    c_single  = sum(1 for r in all_rows if "single_word_english" in r["flags"])
    c_conflict = sum(1 for r in all_rows if "conflict" in r["flags"])
    c_identity = sum(1 for r in all_rows if "identity" in r["flags"])
    print(f"  all_english:         {c_english}")
    print(f"  single_word_english: {c_single}")
    print(f"  conflict:            {c_conflict}")
    print(f"  identity:            {c_identity}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
check_packs.py — invariant checker for the 12 built-in dictionary packs.

Run this after applying verdicts to confirm the cleaned packs satisfy all
safety constraints. Also used as the ground-truth reference by the Swift
DictionaryPackIntegrityTests.

Exit 0 if all checks pass. Exit 1 with details on any failure.
"""

import json
import pathlib
import re
import sys
from collections import defaultdict

PACKS_DIR = pathlib.Path(__file__).parent.parent.parent / "Whisperer/Resources/dictionaries"
WORDS_FILE = pathlib.Path("/usr/share/dict/words")
# Allowlist file for single-word aliases that are legitimately safe.
# Format: JSON list of {"alias": str, "term": str, "reason": str}
ALLOWLIST_FILE = pathlib.Path(__file__).parent / "english_word_allowlist.json"


def load_words() -> set:
    with open(WORDS_FILE) as f:
        return {w.strip().lower() for w in f if w.strip()}


def load_allowlist() -> set[tuple[str, str]]:
    """Returns set of (alias_lower, term_lower) pairs that are explicitly allowed."""
    if not ALLOWLIST_FILE.exists():
        return set()
    with open(ALLOWLIST_FILE) as f:
        entries = json.load(f)
    return {(e["alias"].lower(), e["term"].lower()) for e in entries}


def load_packs() -> list[tuple[str, dict]]:
    packs = []
    for p in sorted(PACKS_DIR.glob("pack_*.json")):
        with open(p) as f:
            packs.append((p.stem, json.load(f)))
    return packs


def main() -> None:
    words = load_words()
    allowlist = load_allowlist()
    packs = load_packs()

    errors: list[str] = []

    # Cross-pack alias → terms map (conflict detection)
    alias_to_terms: dict[str, set] = defaultdict(set)
    alias_to_packs: dict[str, list] = defaultdict(list)
    for stem, pack in packs:
        for correction in pack["corrections"]:
            term = correction["term"]
            for alias in correction["aliases"]:
                al = alias.lower()
                alias_to_terms[al].add(term)
                alias_to_packs[al].append(stem)

    for stem, pack in packs:
        seen_aliases: set[str] = set()

        for correction in pack["corrections"]:
            term = correction["term"]
            if not term:
                errors.append(f"[{stem}] Empty term")
                continue

            for alias in correction["aliases"]:
                if not alias:
                    errors.append(f"[{stem}:{term}] Empty alias")
                    continue

                al = alias.lower()

                # No duplicates within a pack
                if al in seen_aliases:
                    errors.append(f"[{stem}] Duplicate alias: {al!r}")
                seen_aliases.add(al)

                # No identity rules
                if al == term.lower():
                    errors.append(f"[{stem}] Identity rule: {al!r} → {term!r}")

                # No single-word English aliases (unless in allowlist).
                # Only flag aliases that are purely alphabetic — "arm 64", "web 3",
                # "s 3" etc. contain digits/spaces and are NOT plain English words.
                if re.match(r'^[a-z]+$', al) and al in words:
                    if (al, term.lower()) not in allowlist:
                        errors.append(
                            f"[{stem}] Single-word English alias not in allowlist: "
                            f"{al!r} → {term!r}"
                        )

    # Cross-pack conflicts
    for al, terms in alias_to_terms.items():
        if len(terms) > 1:
            errors.append(
                f"CONFLICT: alias {al!r} maps to {sorted(terms)} "
                f"in {alias_to_packs[al]}"
            )

    if errors:
        print(f"FAILED — {len(errors)} error(s):")
        for e in errors:
            print(f"  ✗ {e}")
        sys.exit(1)
    else:
        total = sum(sum(len(c["aliases"]) for c in p["corrections"]) for _, p in packs)
        print(f"OK — {len(packs)} packs, {total} aliases, all invariants satisfied.")
        sys.exit(0)


if __name__ == "__main__":
    main()

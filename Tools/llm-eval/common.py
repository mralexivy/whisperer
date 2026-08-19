"""Shared primitives for the LLM-polish evaluation harness.

Similarity, script detection, word diffs, and the deterministic split live here so
that `build_corpus.py`, `score.py` and `report.py` cannot drift apart.

This is an offline analysis harness, not app code.
"""

from __future__ import annotations

import difflib
import hashlib
import os
import re
import unicodedata
from typing import Iterable

# ---------------------------------------------------------------------------
# Database location — mirrors HistoryTestLoader.findDatabase() exactly.
# Sandbox path FIRST. That ordering is load-bearing: the non-sandboxed database
# has 590 rows / 44 AI-paired rows and shares zero ids with golden-set.json;
# the sandboxed one has 2825 rows / 804 AI-paired rows and contains all 400.
# ---------------------------------------------------------------------------

DB_CANDIDATES = [
    os.path.expanduser(
        "~/Library/Containers/com.ivy.whisperer/Data/Library/Application Support/"
        "Whisperer/history.sqlite"
    ),
    os.path.expanduser("~/Library/Application Support/Whisperer/history.sqlite"),
]


def find_database() -> str:
    for path in DB_CANDIDATES:
        if os.path.exists(path):
            return path
    raise SystemExit("No history.sqlite found at either the sandbox or the non-sandbox path")


# ---------------------------------------------------------------------------
# Script detection
# ---------------------------------------------------------------------------

_HEBREW = re.compile(r"[֐-׿יִ-ﭏ]")
_CYRILLIC = re.compile(r"[Ѐ-ӿԀ-ԯ]")
_LATIN = re.compile(r"[A-Za-zÀ-ɏ]")

SCRIPTS = ("he", "ru", "en")


def script_counts(text: str) -> dict[str, int]:
    return {
        "he": len(_HEBREW.findall(text)),
        "ru": len(_CYRILLIC.findall(text)),
        "en": len(_LATIN.findall(text)),
    }


def scripts_present(text: str, min_chars: int = 3) -> set[str]:
    """Scripts *present* in the text — presence, not majority.

    knowledge.md, "Script gate on presence, not majority": a Russian sentence
    containing `docker run --rm -it ubuntu bash` is majority-Latin, so a majority
    test flagged a correct Cyrillic answer as drift and passed a real translation.
    """
    counts = script_counts(text)
    return {s for s, n in counts.items() if n >= min_chars}


def script_of(text: str) -> str:
    """Dominant script of *text* by character-count majority.

    Exact replica of the logic in ``sample_authoring_batches.py``, using the same
    character ranges so language grouping in the gold-scoring path is consistent
    with batch selection.  Returns ``"he"``, ``"ru"``, ``"en"``, or ``"other"``.

    Distinct from ``dominant_script()`` (which uses regexes covering a wider set of
    combining characters) so the two functions stay aligned with their respective
    call sites: ``dominant_script`` for corpus/gate logic, ``script_of`` for the
    authored-gold path.
    """
    hebrew = sum(1 for c in text if "֐" <= c <= "׿")
    cyrillic = sum(1 for c in text if "Ѐ" <= c <= "ӿ")
    latin = sum(1 for c in text if c.isascii() and c.isalpha())
    top = max(hebrew, cyrillic, latin)
    if top == 0:
        return "other"
    if top == hebrew:
        return "he"
    return "ru" if top == cyrillic else "en"


# ---------------------------------------------------------------------------
# Filler-word stripping — for the authored-gold authoring-constraint checks.
# Single-word entries only; multi-word fillers ("you know", "I mean", "как бы")
# are intentionally excluded to avoid stripping legitimate content words.
# ---------------------------------------------------------------------------

FILLERS = frozenset({
    # English
    "um", "uh", "basically",
    # Russian
    "ну", "э", "типа", "вот",
    # Hebrew
    "אה", "אמ", "כאילו", "יעני",
})


def filler_strip(text: str) -> str:
    """Return *text* with single-word ASR filler tokens removed (case-insensitive).

    Uses ``fold()`` so the result is lowercased and punctuation-stripped — suitable
    only for constraint checks, not for display.
    """
    return " ".join(w for w in fold(text).split() if w not in FILLERS)


def dominant_script(text: str) -> str:
    """The language label for reporting.

    `ZLANGUAGE` is the router's decision, not the script of the text that came out:
    151 of the 441 Correct-mode rows are declared `he` while only 10 actually contain
    Hebrew characters. Language is therefore resolved from the transcript itself.
    """
    counts = script_counts(text)
    if not any(counts.values()):
        return "unk"
    return max(SCRIPTS, key=lambda s: counts[s])


# ---------------------------------------------------------------------------
# Similarity
# ---------------------------------------------------------------------------


def normalize(text: str) -> str:
    """NFC + whitespace collapse. Nothing else.

    Case and punctuation are deliberately preserved: capitalisation and terminal
    punctuation are two of the four error classes in criteria.md §1, so folding
    them away would make the scorer blind to most of what Correct mode does.
    """
    return " ".join(unicodedata.normalize("NFC", text).split())


_PUNCT = re.compile(r"[^\w\s]", re.UNICODE)


def fold(text: str) -> str:
    """Case-folded, punctuation-stripped text — the *content* channel.

    Used only for the secondary `contentRecovery` axis. `golden-set.json` is a raw
    whisper decode: it carries the model's own punctuation and casing, which is not
    a correction target. Folding both sides isolates the word choices, which is the
    one thing an ASR reference can legitimately adjudicate.
    """
    return " ".join(_PUNCT.sub(" ", normalize(text).lower()).split())


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(
                min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb))
            )
        previous = current
    return previous[-1]


def sim(a: str, b: str) -> float:
    """Normalised character-level edit similarity in [0, 1].

    `1 - levenshtein(a, b) / max(len(a), len(b))`.

    Character level rather than token level, for three reasons specific to this
    corpus: (1) the dominant edit classes are punctuation, capitalisation and
    single-character morphology, all of which a whitespace tokeniser either erases
    or inflates to a whole-token miss; (2) Hebrew and Russian are morphologically
    rich, so a token-level metric charges a full token for a one-letter inflection
    fix; (3) it is script-agnostic, which a word tokeniser tuned on English is not.

    The same function is used for both `sim(out, gold)` and `sim(in, gold)` — the
    recovery formula is only meaningful if the two terms are on one scale.
    """
    a, b = normalize(a), normalize(b)
    if not a and not b:
        return 1.0
    denominator = max(len(a), len(b))
    if denominator == 0:
        return 1.0
    return 1.0 - _levenshtein(a, b) / denominator


# ---------------------------------------------------------------------------
# Word-level edit sets, for precision / recall / F0.5
# ---------------------------------------------------------------------------


def words(text: str) -> list[str]:
    return normalize(text).split()


def edit_ops(source: str, target: str) -> set[tuple]:
    """The set of word-level edits turning `source` into `target`.

    Each op is anchored on the source index so that an edit "made" and an edit
    "required" are comparable: they count as the same edit only if they replace the
    same source span with the same words.
    """
    a, b = words(source), words(target)
    ops: set[tuple] = set()
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        ops.add((tag, i1, i2, tuple(b[j1:j2])))
    return ops


def f_beta(precision: float, recall: float, beta: float = 0.5) -> float:
    if precision <= 0 and recall <= 0:
        return 0.0
    b2 = beta * beta
    denominator = b2 * precision + recall
    if denominator == 0:
        return 0.0
    return (1 + b2) * precision * recall / denominator


# ---------------------------------------------------------------------------
# Deterministic split
# ---------------------------------------------------------------------------


def split_bucket(case_id: str, train_fraction: float = 48 / 112) -> str:
    """Stable train/holdout assignment from the case id alone.

    Reproduces the documented 48-train / 64-holdout ratio (0.4286). Hashing the id
    means the split survives corpus regeneration: adding a recording never moves an
    existing case across the boundary, which is what makes a holdout number
    comparable between runs.
    """
    digest = hashlib.sha1(case_id.encode("utf-8")).hexdigest()
    position = int(digest[:8], 16) / 0xFFFFFFFF
    return "train" if position < train_fraction else "holdout"


def mean(values: Iterable[float]) -> float:
    values = list(values)
    return sum(values) / len(values) if values else 0.0

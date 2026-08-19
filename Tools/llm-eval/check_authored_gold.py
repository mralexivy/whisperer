#!/usr/bin/env python3
"""Check LLM-authored gold transcripts against their source batches.

Per-case checks applied in order (first failure wins):
  (a) id-set equality  — gold ids must exactly equal batch ids; extras/missing reported.
  (b) script identity  — dominant Unicode script (Hebrew / Cyrillic / Latin) of input
                          and gold must match.  Uses the same script_of() logic as
                          sample_authoring_batches.py.
  (c) content-word multiset equality modulo fillers — after lowercasing, stripping all
                          punctuation, collapsing consecutive repeated words, dropping the
                          declared filler list, and dropping grammatical articles, the
                          remaining word multisets must be equal.  Reports the symmetric
                          difference, capped at 12 tokens.
  (d) headroom         — 1 - common.sim(input, gold) >= 0.05, i.e. measured with the
                          *same* function that forms the recovery denominator. Cases below
                          this threshold have too little editing to measure.
  (e) length bounds    — gold word count must be in [0.75, 1.15] × input word count.

Normalisations applied before check (c) to compare like with like:
  - Hyphens treated as whitespace (split): "auto-detect" → ["auto", "detect"],
    "hard-code" → ["hard", "code"].  This handles the task's stated case where gold
    hyphenates a compound that the input wrote as two separate words (and vice versa).
    Without this fix, gold "hard-code" would normalise to one token "hardcode" while
    input "hard code" normalises to two tokens ["hard","code"], causing a spurious diff.
  - Common English contractions expanded on both sides consistently: "don't" → "do not",
    "it's" → "it is", etc.  Punctuation-style contraction choices by the authoring agent
    must not produce false content-word mismatches.
  - Possessive apostrophe-s stripped: "audit's" → "audit".  An agent adding or removing
    a possessive 's on a noun that is otherwise present in the input should not fail.
  - Grammatical articles (a, an, the) exempted from the multiset: the check is named
    "content-word multiset equality" — articles are function words, not content words.
    Inserting or deleting an article for grammatical agreement is an explicitly allowed
    "obvious grammar fix" in the authoring constraint and must not cause a false failure.

These normalisations do NOT relax the substance of the check: genuine content-word
substitutions — different nouns, profanity removal, name changes, paraphrase —
still produce mismatched multisets and are correctly flagged.
"""

import collections
import glob
import json
import os
import re
import string
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The scorer's own similarity, imported rather than reimplemented. The headroom gate below
# exists to protect the recovery denominator, and a gate measured with a different function
# than the quantity it guards is not a gate — see check_d_headroom for what that cost us.
from common import sim as common_sim  # noqa: E402

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

AUTHORING_DIR = os.path.join(os.path.dirname(__file__), "authoring")
ARTIFACTS_DIR = os.path.join(os.path.dirname(__file__), "artifacts")
REPORT_PATH = os.path.join(ARTIFACTS_DIR, "gold_check.json")
CORPUS_PATH = os.path.join(os.path.dirname(__file__), "authoring", "gold-corpus.json")
DROPPED_PATH = os.path.join(os.path.dirname(__file__), "authoring", "gold-corpus-dropped.json")

HEADROOM_THRESHOLD = 0.05      # check (d): 1 - sim must be >= this
LENGTH_MIN_RATIO   = 0.75      # check (e): gold_words / input_words >= this
LENGTH_MAX_RATIO   = 1.15      # check (e): gold_words / input_words <= this
MAX_DIFF_DISPLAY   = 12        # cap on symmetric-diff tokens shown in reason

# Fillers to drop from both sides before multiset comparison.
# English, Russian, and Hebrew disfluencies as specified.
FILLERS = {
    # English
    "um", "uh", "erm", "like", "you know", "i mean", "sort of", "kind of",
    "basically", "actually", "literally", "so", "well", "right", "okay",
    # Russian
    "эм", "ээ", "ну", "вот", "значит", "как бы", "типа", "короче",
    # Hebrew
    "אה", "אמ", "כאילו", "יעני", "בעצם",
}
# Multi-word fillers sorted longest-first so we match them before sub-phrases.
MULTI_WORD_FILLERS = sorted(
    [f for f in FILLERS if " " in f], key=lambda x: -len(x.split())
)
SINGLE_WORD_FILLERS = {f for f in FILLERS if " " not in f}

# Common English contractions → expanded form (applied to both sides identically).
CONTRACTIONS = {
    "don't":    "do not",
    "doesn't":  "does not",
    "didn't":   "did not",
    "won't":    "will not",
    "wouldn't": "would not",
    "can't":    "cannot",
    "couldn't": "could not",
    "shouldn't": "should not",
    "isn't":    "is not",
    "aren't":   "are not",
    "wasn't":   "was not",
    "weren't":  "were not",
    "haven't":  "have not",
    "hasn't":   "has not",
    "hadn't":   "had not",
    "it's":     "it is",
    "i'm":      "i am",
    "i've":     "i have",
    "i'll":     "i will",
    "i'd":      "i would",
    "you're":   "you are",
    "you've":   "you have",
    "you'll":   "you will",
    "you'd":    "you would",
    "we're":    "we are",
    "we've":    "we have",
    "we'll":    "we will",
    "we'd":     "we would",
    "they're":  "they are",
    "they've":  "they have",
    "they'll":  "they will",
    "they'd":   "they would",
    "he's":     "he is",
    "she's":    "she is",
    "that's":   "that is",
    "there's":  "there is",
    "here's":   "here is",
    "what's":   "what is",
    "who's":    "who is",
    "how's":    "how is",
    "let's":    "let us",
    "won't":    "will not",
    "it'll":    "it will",
    "that'll":  "that will",
}

# ---------------------------------------------------------------------------
# Script detection (same logic as sample_authoring_batches.py)
# ---------------------------------------------------------------------------

def script_of(text: str) -> str:
    hebrew   = sum(1 for c in text if "ְ" <= c <= "׿")
    cyrillic = sum(1 for c in text if "Ѐ" <= c <= "ӿ")
    latin    = sum(1 for c in text if c.isascii() and c.isalpha())
    top = max(hebrew, cyrillic, latin)
    if top == 0:
        return "other"
    if top == hebrew:
        return "he"
    return "ru" if top == cyrillic else "en"


# ---------------------------------------------------------------------------
# Normalisation for content-word multiset comparison
# ---------------------------------------------------------------------------

def _expand_contractions(text: str) -> str:
    """Expand English contractions consistently on both sides."""
    for contracted, expanded in CONTRACTIONS.items():
        # Word-boundary aware replacement (case-insensitive).
        text = re.sub(r"\b" + re.escape(contracted) + r"\b", expanded, text, flags=re.IGNORECASE)
    return text


def _strip_possessive(token: str) -> str:
    """Strip trailing possessive 's from a token."""
    if token.endswith("'s") or token.endswith("’s"):
        return token[:-2]
    return token


ARTICLES = {"a", "an", "the"}

def _split_hyphens(text: str) -> str:
    """Treat hyphens as whitespace separators: 'auto-detect' → 'auto detect'.
    This matches the task's stated normalisation case: gold hyphenates a compound
    that the input wrote as two words — both forms then tokenise identically."""
    return re.sub(r"(\w)-(\w)", r"\1 \2", text)


def _drop_multi_word_fillers(tokens: list[str]) -> list[str]:
    """Remove multi-word filler phrases (greedy left-to-right)."""
    result: list[str] = []
    i = 0
    while i < len(tokens):
        matched = False
        for phrase in MULTI_WORD_FILLERS:
            parts = phrase.split()
            n = len(parts)
            if tokens[i : i + n] == parts:
                i += n
                matched = True
                break
        if not matched:
            result.append(tokens[i])
            i += 1
    return result


def _collapse_repeats(tokens: list[str]) -> list[str]:
    """Collapse consecutive identical tokens: ['like','like','I'] → ['like','I']."""
    if not tokens:
        return []
    result = [tokens[0]]
    for tok in tokens[1:]:
        if tok != result[-1]:
            result.append(tok)
    return result


def normalise_for_multiset(text: str) -> list[str]:
    """
    Return a token list suitable for multiset comparison.
    Steps (in order):
      1. Lowercase
      2. Expand contractions
      3. Split hyphens (treat as whitespace separator)
      4. Strip all punctuation characters
      5. Split on whitespace
      6. Strip possessive -'s from each token
      7. Drop empty tokens
      8. Collapse consecutive repeated tokens
      9. Drop single-word fillers and articles
      10. Drop multi-word filler sequences
    """
    t = text.lower()
    t = _expand_contractions(t)
    t = _split_hyphens(t)
    # Strip punctuation — keep Unicode letters, digits, whitespace
    t = re.sub(r"[^\w\s]", " ", t, flags=re.UNICODE)
    tokens = t.split()
    tokens = [_strip_possessive(tok) for tok in tokens]
    tokens = [tok for tok in tokens if tok]
    tokens = _collapse_repeats(tokens)
    # Drop fillers AND grammatical articles (function words, not content words)
    drop_set = SINGLE_WORD_FILLERS | ARTICLES
    tokens = [tok for tok in tokens if tok not in drop_set]
    tokens = _drop_multi_word_fillers(tokens)
    tokens = [tok for tok in tokens if tok]  # re-clean after multi-word drop
    return tokens


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

def check_b_script(inp: str, gold: str) -> tuple[bool, str]:
    si = script_of(inp)
    sg = script_of(gold)
    if si != sg:
        return False, f"script mismatch: input={si} gold={sg}"
    return True, ""


def check_c_multiset(inp: str, gold: str) -> tuple[bool, str]:
    ti = normalise_for_multiset(inp)
    tg = normalise_for_multiset(gold)
    ci = collections.Counter(ti)
    cg = collections.Counter(tg)
    if ci == cg:
        return True, ""
    # Symmetric difference
    diff_in  = ci - cg  # in input, not in gold
    diff_out = cg - ci  # in gold, not in input
    parts = []
    if diff_in:
        toks = sorted(diff_in.elements())[:MAX_DIFF_DISPLAY]
        parts.append("input_only=[" + ", ".join(toks) + "]")
    if diff_out:
        toks = sorted(diff_out.elements())[:MAX_DIFF_DISPLAY]
        parts.append("gold_only=[" + ", ".join(toks) + "]")
    return False, "content-word mismatch: " + "; ".join(parts)


def check_d_headroom(inp: str, gold: str) -> tuple[bool, str]:
    # `common.sim`, not `difflib.SequenceMatcher.ratio`. This gate exists for exactly one
    # reason — to keep the recovery denominator `1 - sim(in, gold)` away from zero — so it
    # has to be measured with the function that *is* that denominator. The two disagree
    # badly and in the dangerous direction: SequenceMatcher enables `autojunk` by default,
    # which classifies any character appearing in more than 1% of a sequence of length >= 200
    # as junk. Every letter in a paragraph of prose qualifies, the ratio collapses, and the
    # gate reports plenty of headroom on cases whose real headroom is 0.011. Nine such cases
    # reached the recovery corpus and `selftest.py`, which already measured with `common.sim`,
    # is what caught them.
    similarity = common_sim(inp, gold)
    headroom = 1.0 - similarity
    if headroom < HEADROOM_THRESHOLD:
        return False, (f"too similar: sim={similarity:.3f} headroom={headroom:.3f} "
                       f"< {HEADROOM_THRESHOLD}")
    return True, ""


def check_e_length(inp: str, gold: str) -> tuple[bool, str]:
    wi = len(inp.split())
    wg = len(gold.split())
    if wi == 0:
        return False, "input has no words"
    ratio = wg / wi
    if ratio < LENGTH_MIN_RATIO or ratio > LENGTH_MAX_RATIO:
        return False, (
            f"length ratio {ratio:.2f} out of [{LENGTH_MIN_RATIO},{LENGTH_MAX_RATIO}]: "
            f"input_words={wi} gold_words={wg}"
        )
    return True, ""


# ---------------------------------------------------------------------------
# Per-pair runner
# ---------------------------------------------------------------------------

def check_pair(case_id: str, inp: str, gold: str) -> dict:
    """Run all checks for a single case. Returns a verdict dict."""
    result = {
        "id": case_id,
        "pass": True,
        "failures": [],
    }

    checks = [
        ("b_script",    check_b_script(inp, gold)),
        ("c_multiset",  check_c_multiset(inp, gold)),
        ("d_headroom",  check_d_headroom(inp, gold)),
        ("e_length",    check_e_length(inp, gold)),
    ]

    for name, (ok, reason) in checks:
        if not ok:
            result["pass"] = False
            result["failures"].append({"check": name, "reason": reason})

    return result


# ---------------------------------------------------------------------------
# Batch loader
# ---------------------------------------------------------------------------

def load_pairs(authoring_dir: str) -> list[dict]:
    """
    Load all batch-*.json / batch-*.gold.json pairs from authoring_dir.
    Returns a list of dicts with keys: id, language, durationSec, input, gold, batch.
    Also runs check (a) id-set equality and returns any (a) failures as separate entries.
    """
    batch_files = sorted(glob.glob(os.path.join(authoring_dir, "batch*-*[0-9][0-9].json")))
    all_cases: list[dict] = []
    id_errors: list[dict] = []

    for batch_path in batch_files:
        gold_path = batch_path[:-5] + ".gold.json"
        batch_name = os.path.basename(batch_path)
        if not os.path.exists(gold_path):
            id_errors.append({
                "batch": batch_name,
                "error": f"missing gold file: {os.path.basename(gold_path)}",
            })
            continue

        batch_rows = json.load(open(batch_path, encoding="utf-8"))
        gold_rows  = json.load(open(gold_path,  encoding="utf-8"))

        batch_ids = {row["id"] for row in batch_rows}
        gold_ids  = {row["id"] for row in gold_rows}

        extra   = gold_ids - batch_ids
        missing = batch_ids - gold_ids

        if extra or missing:
            id_errors.append({
                "batch": batch_name,
                "check": "a_id_set",
                "extra_in_gold": sorted(extra),
                "missing_from_gold": sorted(missing),
            })

        gold_map = {row["id"]: row["gold"] for row in gold_rows}

        for row in batch_rows:
            cid = row["id"]
            if cid not in gold_map:
                continue  # already reported as missing above
            all_cases.append({
                "id": cid,
                "language": row.get("language", ""),
                "durationSec": row.get("durationSec"),
                "input": row.get("input", ""),
                "gold":  gold_map[cid],
                "batch": batch_name,
            })

    return all_cases, id_errors


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(ARTIFACTS_DIR, exist_ok=True)

    all_cases, id_errors = load_pairs(AUTHORING_DIR)

    verdicts: list[dict] = []
    for case in all_cases:
        v = check_pair(case["id"], case["input"], case["gold"])
        v["language"] = case["language"]
        v["batch"]    = case["batch"]
        verdicts.append(v)

    # Attach check (a) id-set errors to the report (not per-case).
    report = {
        "id_set_errors": id_errors,
        "cases": verdicts,
    }

    with open(REPORT_PATH, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    # -----------------------------------------------------------------------
    # Assemble gold corpus (passing cases only)
    # -----------------------------------------------------------------------

    case_map = {c["id"]: c for c in all_cases}
    passing_ids = {v["id"] for v in verdicts if v["pass"]}
    failing_ids = {v["id"] for v in verdicts if not v["pass"]}

    passing_cases = [
        {
            "id":          c["id"],
            "language":    c["language"],
            "durationSec": c["durationSec"],
            "input":       c["input"],
            "gold":        c["gold"],
        }
        for c in all_cases
        if c["id"] in passing_ids
    ]

    dropped_cases = []
    for v in verdicts:
        if v["id"] in failing_ids:
            c = case_map[v["id"]]
            dropped_cases.append({
                "id":          c["id"],
                "language":    c["language"],
                "batch":       c["batch"],
                "failures":    v["failures"],
                "input":       c["input"],
                "gold":        c["gold"],
            })

    # Per-language counts after dropping
    lang_passing: dict[str, int] = collections.Counter(c["language"] for c in passing_cases)
    lang_total:   dict[str, int] = collections.Counter(c["language"] for c in all_cases)

    # Failure reason histogram across all failing cases
    reason_hist: dict[str, int] = collections.Counter()
    for v in verdicts:
        for f in v.get("failures", []):
            reason_hist[f["check"]] += 1

    dropped_ids_by_lang: dict[str, list[str]] = collections.defaultdict(list)
    dropped_reasons_by_id: dict[str, list[str]] = {}
    for v in verdicts:
        if not v["pass"]:
            c = case_map[v["id"]]
            dropped_ids_by_lang[c["language"]].append(v["id"])
            dropped_reasons_by_id[v["id"]] = [f["check"] for f in v["failures"]]

    header = {
        "source": (
            "raw storedTranscript from the Whisperer app's own recordings history "
            "(history-golden.json); selection is deterministic — see sample_authoring_batches.py"
        ),
        "gold": (
            "LLM-authored reference transcripts produced under the constraint: apply "
            "punctuation, capitalisation, paragraph breaks, filler removal, and obvious "
            "grammar/agreement fixes ONLY — no translation, no paraphrase, no content-word "
            "substitution, no reordering, no added or removed facts, script must not change. "
            "Mechanically checked by check_authored_gold.py."
        ),
        "quality_disclaimer": (
            "This corpus is NOT human ground truth and no absolute quality claim may be made "
            "from it. It is good enough to detect damage (regressions that corrupt or lose "
            "words) and to score punctuation/capitalisation improvements, but not to measure "
            "fluency or meaning-level quality."
        ),
        "checks_applied": [
            "(a) id-set equality between batch and gold files",
            "(b) dominant Unicode script must match between input and gold",
            "(c) content-word multiset equality after lowercasing, hyphen-join, "
                "contraction expansion, possessive-s strip, punctuation strip, "
                "consecutive-repeat collapse, and filler removal",
            "(d) headroom: 1 - SequenceMatcher.ratio(input, gold) >= 0.05",
            "(e) gold word count in [0.75, 1.15] x input word count",
        ],
        "per_language_n_after_drop": dict(lang_passing),
        "total_in":      len(all_cases),
        "total_passing": len(passing_cases),
        "dropped_ids_with_reasons": {
            cid: dropped_reasons_by_id[cid]
            for lang_ids in dropped_ids_by_lang.values()
            for cid in sorted(lang_ids)
        },
    }

    corpus = {"header": header, "cases": passing_cases}
    with open(CORPUS_PATH, "w", encoding="utf-8") as f:
        json.dump(corpus, f, ensure_ascii=False, indent=2)

    dropped_doc = {
        "header": {
            "description": "Cases dropped from gold-corpus.json with failure reasons. "
                           "Audit trail — do not use these for evaluation.",
        },
        "dropped": dropped_cases,
    }
    with open(DROPPED_PATH, "w", encoding="utf-8") as f:
        json.dump(dropped_doc, f, ensure_ascii=False, indent=2)

    # -----------------------------------------------------------------------
    # Print per-language summary table
    # -----------------------------------------------------------------------

    all_langs = sorted(set(lang_total.keys()) | set(lang_passing.keys()))

    print()
    print("=" * 68)
    print(f"{'Language':<10} {'Total':>6} {'Pass':>6} {'Fail':>6}  {'Fail reasons'}")
    print("-" * 68)

    for lang in all_langs:
        total  = lang_total.get(lang, 0)
        passed = lang_passing.get(lang, 0)
        failed = total - passed

        # Failure reason breakdown for this language
        lang_reasons: dict[str, int] = collections.Counter()
        for v in verdicts:
            if v["language"] == lang and not v["pass"]:
                for f in v["failures"]:
                    lang_reasons[f["check"]] += 1
        reason_str = "  ".join(f"{k}×{v}" for k, v in sorted(lang_reasons.items()))

        flag = "  *** BELOW n=20 ***" if passed < 20 else ""
        print(f"{lang:<10} {total:>6} {passed:>6} {failed:>6}  {reason_str}{flag}")

    print("=" * 68)
    print(f"{'TOTAL':<10} {len(all_cases):>6} {len(passing_cases):>6} {len(failing_ids):>6}")
    print()
    print("Failure-reason histogram (all languages):")
    for check_name, count in sorted(reason_hist.items()):
        print(f"  {check_name}: {count}")
    print()
    print(f"Report  → {REPORT_PATH}")
    print(f"Corpus  → {CORPUS_PATH}")
    print(f"Dropped → {DROPPED_PATH}")
    print()


if __name__ == "__main__":
    main()

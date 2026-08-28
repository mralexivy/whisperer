#!/usr/bin/env python
"""
build_corpus.py -- corpus construction for the mmBERT transcript-polishing tagger.

Three jobs, all deterministic given --seed:

  1. STUDY the real ASR distribution. Reads the app's own (sandboxed) history DB
     and measures what whisper.cpp actually emits and what the shipped 4B teacher
     actually changes. Writes artifacts/asr_stats.json. The synthetic corruption
     policy is driven by these measured numbers, not by guesses.

  2. DISTIL the teacher. Aligns the real (raw ASR -> 4B-polished) pairs into the
     same token-level edit labels, keeping ONLY the alignment-preserving edits
     (punctuation, casing, filler/repetition deletion) and masking every lexical
     rewrite. Applies a teacher-quality filter first -- the 4B is not ground
     truth and distilling its failures would be the worst possible outcome.

  3. CORRUPT clean text (Wikipedia he/ru/en + in-domain clean transcripts) into
     synthetic (corrupted -> clean) pairs. This is what gives Hebrew and Russian
     enough coverage for a per-language release gate.

Language is ALWAYS resolved by Unicode script over the text. The DB's ZLANGUAGE
field records the routed model, not the speech, and is not used anywhere.

Usage:
    python build_corpus.py --out artifacts/data --seed 1234
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import random
import re
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (  # noqa: E402
    CASE2ID, IGNORE, PUNCT2ID, PUNCT_LABELS, Example, Word, build_example,
    detect_script, has_case, normalise_punct, split_word, tokenize_words,
    APPEND2ID, REPL2ID, MERGE2ID, PARA2ID,  # new for 8-head model
)

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

SANDBOX_DB = Path(os.path.expanduser(
    "~/Library/Containers/com.ivy.whisperer/Data/Library/Application Support/"
    "Whisperer/history.sqlite"))
NONSANDBOX_DB = Path(os.path.expanduser(
    "~/Library/Application Support/Whisperer/history.sqlite"))
GOLDEN = REPO / "WhispererTests" / "TestData" / "golden-set.json"

SCRIPT_SALT = {"en": 11, "he": 23, "ru": 37}

# Fillers observed in the app's own raw transcripts, plus the standard set.
# Only single-token fillers are deletable in this label scheme.
FILLERS = {
    "en": ["um", "uh", "erm", "hmm", "mmm", "like", "basically", "actually",
           "literally", "so", "well", "right", "okay"],
    "ru": ["ну", "вот", "типа", "короче", "как-бы", "значит", "это", "эм"],
    "he": ["אה", "אמ", "כאילו", "בעצם", "יעני", "אז", "טוב"],
}
# Fillers that are safe to DELETE as a target (a subset -- "so"/"אז"/"ну" carry
# discourse meaning at sentence start, so they are only deletable mid-sentence).
STRONG_FILLERS = {
    "en": {"um", "uh", "erm", "hmm", "mmm", "like", "basically", "actually",
           "literally"},
    "ru": {"ну", "вот", "типа", "короче", "как-бы", "эм"},
    "he": {"אה", "אמ", "כאילו", "יעני"},
}

CHAT_TOKENS = ["<|im_start|>", "<|im_end|>", "<|", "[INPUT]", "[/INPUT]",
               "<think>", "</think>", "<|endoftext|>", "assistant\n",
               "[OUTPUT]", "```"]

URL_RE = re.compile(r"https?://\S+|www\.\S+")
DIGIT_RE = re.compile(r"\d+")

ALL_FILLERS = set()
for _v in FILLERS.values():
    ALL_FILLERS |= set(_v)

_WORDCHARS = re.compile(r"[^0-9a-zЀ-ԯ֐-׿]+")


def norm_key(text: str, drop_fillers: bool = True) -> str:
    """Case-, accent-, punctuation-insensitive letter sequence of `text`.

    The single leakage key for the whole toolchain: `build_eval_large.py` splits
    train from eval on it, and this file excludes the held-out documents on it.
    Optionally drops filler words so that the synthetic corruptor's *inserted*
    fillers cannot hide a leaked example.
    """
    t = unicodedata.normalize("NFD", text.lower())
    t = "".join(c for c in t if unicodedata.category(c) != "Mn")
    t = _WORDCHARS.sub(" ", t)
    toks = t.split()
    if drop_fillers:
        toks = [w for w in toks if w not in ALL_FILLERS]
    return " ".join(toks)


# =========================================================================
# 1. STUDY
# =========================================================================

def load_db(path: Path) -> List[dict]:
    if not path.exists():
        return []
    # The app's history lives inside its sandbox container, which macOS protects
    # behind Full Disk Access. Without FDA, sqlite reports a bare "authorization
    # denied" that surfaces upstream as "no rows in <path>" — indistinguishable
    # from an empty database, and the reason a retrain looks like a data problem
    # when it is a permissions problem.
    try:
        with open(path, "rb") as fh:
            fh.read(16)
    except PermissionError as exc:
        raise SystemExit(
            f"Cannot read {path}: {exc}\n"
            "This is macOS Full Disk Access, not a missing database. Grant FDA to "
            "the terminal (or IDE) running this script in System Settings > Privacy "
            "& Security > Full Disk Access, then re-run.\n"
            "Do NOT fall back to ~/Library/Application Support/Whisperer/history.sqlite: "
            "that is the non-sandboxed store used by Debug builds and holds a different, "
            "much smaller set of recordings."
        ) from exc
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    rows = [dict(r) for r in con.execute(
        "SELECT ZID, ZTRANSCRIPTION, ZAIENHANCEDTEXT, ZAIMODENAME, ZLANGUAGE, "
        "ZDURATION FROM ZTRANSCRIPTIONENTITY")]
    con.close()
    return rows


def study(rows: List[dict]) -> dict:
    """Measure what raw whisper output actually looks like, per script."""
    per: Dict[str, dict] = {}
    for sc in ("en", "he", "ru"):
        per[sc] = {"words": 0, "punct": Counter(), "sent_initial_lower": 0,
                   "sent_initial": 0, "midcap": 0, "allcaps": 0,
                   "filler": Counter(), "repeats": 0, "utts": 0,
                   "utt_words": []}
    for r in rows:
        t = (r.get("ZTRANSCRIPTION") or "").strip()
        if not t:
            continue
        sc = detect_script(t)
        if sc not in per:
            continue
        d = per[sc]
        ws = tokenize_words(t)
        d["utts"] += 1
        d["utt_words"].append(len(ws))
        d["words"] += len(ws)
        prev_end = True
        for i, w in enumerate(ws):
            p = normalise_punct(w.trail)
            d["punct"][p] += 1
            cs = w.case_state
            if prev_end:
                d["sent_initial"] += 1
                if cs == CASE2ID["LOWER"]:
                    d["sent_initial_lower"] += 1
            elif cs == CASE2ID["CAP"]:
                d["midcap"] += 1
            if cs == CASE2ID["UPPER"]:
                d["allcaps"] += 1
            prev_end = p in (".", "?", "!", "…")
            if i and w.key and w.key == ws[i - 1].key:
                d["repeats"] += 1
            lw = w.key
            if lw in FILLERS.get(sc, []):
                d["filler"][lw] += 1

    out = {}
    for sc, d in per.items():
        n = max(d["words"], 1)
        out[sc] = {
            "utterances": d["utts"],
            "words": d["words"],
            "mean_words_per_utt": round(sum(d["utt_words"]) / max(len(d["utt_words"]), 1), 1),
            "punct_rate_per_word": {k: round(v / n, 5) for k, v in d["punct"].most_common()},
            "sent_initial_lowercase_rate": round(
                d["sent_initial_lower"] / max(d["sent_initial"], 1), 4),
            "mid_sentence_cap_rate": round(d["midcap"] / n, 4),
            "allcaps_rate": round(d["allcaps"] / n, 5),
            "immediate_repeat_rate": round(d["repeats"] / n, 5),
            "filler_rate": {k: round(v / n, 5) for k, v in d["filler"].most_common()},
        }
    return out


# =========================================================================
# 2. TEACHER DISTILLATION
# =========================================================================

def teacher_quality_reject(raw: str, pol: str) -> Optional[str]:
    """Return a rejection reason, or None if the pair is safe to distil."""
    if not raw.strip() or not pol.strip():
        return "empty"
    for tk in CHAT_TOKENS:
        if tk in pol:
            return "chat_template_token"
    if detect_script(raw) != detect_script(pol):
        return "script_changed"
    if detect_script(raw) == "unk":
        return "script_unknown"

    # Digit runs must survive verbatim.
    if Counter(DIGIT_RE.findall(raw)) - Counter(DIGIT_RE.findall(pol)):
        return "digits_lost"
    # URLs must survive verbatim.
    if set(URL_RE.findall(raw)) - set(URL_RE.findall(pol)):
        return "url_lost"

    rw, pw = raw.split(), pol.split()
    if len(rw) < 3:
        return "too_short"
    ratio = len(pw) / len(rw)
    if ratio < 0.65 or ratio > 1.35:
        return "length_ratio"

    # Degeneration: a 1-3gram repeated 4+ times in a row in the output but not
    # in the input.
    for n in (1, 2, 3):
        run, prev = 1, None
        for i in range(len(pw) - n + 1):
            g = tuple(w.lower() for w in pw[i:i + n])
            if g == prev:
                run += 1
                if run >= 4:
                    src = " ".join(g)
                    if raw.lower().count(src) < 3:
                        return "degeneration"
            else:
                run, prev = 1, g

    # A "Correct" pass should still be recognisably the same sentence.
    sm = difflib.SequenceMatcher(
        a=[split_word(w).key for w in rw], b=[split_word(w).key for w in pw],
        autojunk=False)
    if sm.ratio() < 0.55:
        return "not_a_correction"
    return None


def align_pair(raw: str, pol: str, script: str, source: str) -> Optional[Example]:
    """Derive per-word edit labels from a (raw, polished) pair.

    Only alignment-preserving edits are labelled. Lexical substitutions and
    insertions are MASKED (IGNORE) -- this scheme cannot express them, and the
    plan sequences grammar/spelling last anyway.
    """
    rws = tokenize_words(raw)
    pws = tokenize_words(pol)
    if not rws or not pws:
        return None
    sm = difflib.SequenceMatcher(a=[w.key for w in rws], b=[w.key for w in pws],
                                 autojunk=False)
    n = len(rws)
    tgt_p: List[Optional[int]] = [None] * n
    tgt_c: List[Optional[int]] = [None] * n
    tgt_d: List[Optional[bool]] = [None] * n

    ops = sm.get_opcodes()
    strong = STRONG_FILLERS.get(script, set())

    for oi, (tag, i1, i2, j1, j2) in enumerate(ops):
        if tag == "equal":
            for k in range(i2 - i1):
                src, dst = rws[i1 + k], pws[j1 + k]
                tgt_p[i1 + k] = dst.punct_state
                tgt_c[i1 + k] = dst.case_state
                tgt_d[i1 + k] = False
        elif tag == "delete":
            span = rws[i1:i2]
            for k, w in enumerate(span):
                is_rep = (i1 + k > 0 and w.key == rws[i1 + k - 1].key) or \
                         (i1 + k + 1 < n and w.key == rws[i1 + k + 1].key)
                if w.key in strong or is_rep:
                    tgt_d[i1 + k] = True      # a real disfluency deletion
                    tgt_p[i1 + k] = None
                    tgt_c[i1 + k] = None
                else:
                    tgt_d[i1 + k] = None      # lexical deletion -> masked
        else:
            # replace / insert -> lexical rewrite, out of scope. Mask the span
            # and also the punctuation of the word immediately before it, since
            # the teacher may have moved a mark across the boundary.
            for k in range(i1, i2):
                tgt_p[k] = tgt_c[k] = tgt_d[k] = None
            if i1 > 0:
                tgt_p[i1 - 1] = None
            if tag == "insert" and i1 > 0:
                tgt_p[i1 - 1] = None

    if all(p is None and d is None for p, d in zip(tgt_p, tgt_d)):
        return None
    return build_example(rws, tgt_p, tgt_c, tgt_d, script, source)


def build_teacher_set(rows: List[dict]) -> Tuple[List[Example], Counter]:
    kept, reasons = [], Counter()
    for r in rows:
        raw = (r.get("ZTRANSCRIPTION") or "").strip()
        pol = (r.get("ZAIENHANCEDTEXT") or "").strip()
        mode = r.get("ZAIMODENAME") or ""
        if not raw or not pol:
            continue
        reasons["_have_pair"] += 1
        # Only the "Correct" mode is the polishing task. Rewrite / Translate /
        # Custom are different tasks and would teach the model to paraphrase.
        if mode != "Correct":
            reasons[f"mode_{mode or 'none'}"] += 1
            continue
        reasons["_correct_mode"] += 1
        why = teacher_quality_reject(raw, pol)
        if why:
            reasons[why] += 1
            continue
        sc = detect_script(raw)
        ex = align_pair(raw, pol, sc, "teacher")
        if ex is None:
            reasons["no_usable_labels"] += 1
            continue
        kept.append(ex)
        reasons["_kept"] += 1
    return kept, reasons


# =========================================================================
# 3. SYNTHETIC CORRUPTION
# =========================================================================

class Corruptor:
    """Turns clean, well-formed text into ASR-looking text.

    Rates are anchored on the measured statistics of the app's own raw whisper
    output (artifacts/asr_stats.json), not invented. whisper.cpp already emits
    punctuation and casing, so the corruption is PARTIAL -- most marks survive.
    That keeps the KEEP class dominant, which is what we want the model's prior
    to be.
    """

    # ---- MEASURED on the 423 surviving (raw ASR -> 4B "Correct") pairs ----
    # Probability a mark present in the clean text is MISSING from ASR output.
    # Measured as (marks the teacher had to insert) / (marks in the target).
    DROP = {".": 0.54, ",": 0.63, "?": 0.28, "!": 0.50, ";": 0.67,
            ":": 0.74, "…": 0.50, "—": 0.75}
    # Probability whisper emits a mark where the target has none.
    # Measured: 13 teacher removals / 20628 words = 0.00063.
    SPURIOUS_ADD = 0.0008
    # Probability whisper emits the WRONG mark. Measured: 72/20628 = 0.0035.
    SPURIOUS_WRONG = 0.0035
    # Probability a word whose target casing is CAP comes back lowercased.
    # Measured: 386 LOWER->CAP fixes / 1850 CAP targets = 0.209.
    CAP_LOWERED = 0.21
    # Probability a word whose target casing is LOWER comes back capitalised.
    # Measured: 101 CAP->LOWER fixes / 16343 LOWER targets = 0.0062.
    MID_CAP = 0.0062
    # Per-word probability of an inserted filler / an immediate repetition.
    # The teacher's own deletion rate is 0.0084/word; we stay near it so the
    # DELETE class is not over-represented (which would cost precision).
    FILLER_STRONG = 0.006     # "um", "uh" -- labelled DELETE
    FILLER_SOFT = 0.010       # "like", "so" -- label MASKED (genuinely ambiguous)
    REPEAT = 0.004            # immediate repetition -- labelled DELETE

    # Contraction → expansion map (inverts repl/CONTRACT). Keys are lowercase.
    _CONTRACTION_MAP: dict = {
        "don't": "do not", "doesn't": "does not", "didn't": "did not",
        "won't": "will not", "wouldn't": "would not", "shouldn't": "should not",
        "couldn't": "could not", "wasn't": "was not", "weren't": "were not",
        "haven't": "have not", "hasn't": "has not", "hadn't": "had not",
        "i'm": "i am", "i've": "i have", "i'll": "i will", "i'd": "i would",
        "you're": "you are", "you've": "you have", "you'll": "you will",
        "he's": "he is", "she's": "she is", "it's": "it is",
        "we're": "we are", "we've": "we have", "we'll": "we will",
        "they're": "they are", "they've": "they have", "they'll": "they will",
        "that's": "that is", "there's": "there is", "here's": "here is",
        "let's": "let us", "isn't": "is not", "aren't": "are not",
    }

    # Compound → split map (inverts merge/MERGE_SPACE).
    _COMPOUND_MAP: dict = {
        "dropdown": "drop down", "startup": "start up", "login": "log in",
        "logout": "log out", "setup": "set up", "checkup": "check up",
        "backup": "back up", "followup": "follow up", "callback": "call back",
        "pushback": "push back", "feedback": "feed back", "layout": "lay out",
        "output": "out put", "input": "in put", "rollout": "roll out",
        "rollback": "roll back", "handoff": "hand off", "handover": "hand over",
        "takeaway": "take away", "breakdown": "break down",
        "workaround": "work around", "workflow": "work flow",
        "touchpoint": "touch point", "hotspot": "hot spot",
        "chatbot": "chat bot", "dataset": "data set", "database": "data base",
        "timeline": "time line", "frontend": "front end", "backend": "back end",
    }

    def __init__(self, rng: random.Random, script: str):
        self.rng = rng
        self.script = script
        self.strong = sorted(STRONG_FILLERS.get(script, STRONG_FILLERS["en"]))
        self.soft = sorted(set(FILLERS.get(script, FILLERS["en"])) - set(self.strong))
        self.other_marks = [".", ",", "?", ";", ":"]

    def __call__(self, clean: str, source: str) -> Optional[Example]:
        rng = self.rng

        # --- paragraph collapse pre-pass (inverts para/PARA_BREAK) ---
        # When loading text with newlines, occasionally strip paragraph breaks so
        # the model must predict PARA_BREAK at those positions. Rate: 0.15/break.
        para_break_after: set = set()  # word indices where a break was collapsed
        if "\n" in clean:
            paras = [p.strip() for p in clean.split("\n") if p.strip()]
            all_words: List[Word] = []
            for pi, para in enumerate(paras):
                pw = tokenize_words(para)
                if pi > 0 and all_words and rng.random() < 0.15:
                    # collapsed break: last word of prev para gets PARA_BREAK label
                    para_break_after.add(len(all_words) - 1)
                all_words.extend(pw)
            cws = all_words if all_words else tokenize_words(clean)
        else:
            cws = tokenize_words(clean)

        if len(cws) < 4:
            return None

        # --- article deletion pre-pass (inverts append) ---
        # Delete "the"/"a"/"an" from the corrupted input at rate 0.08/eligible
        # position; the following word gets the corresponding append label.
        skip_word: List[bool] = [False] * len(cws)
        article_label: List[int] = [0] * len(cws)
        pending_art: Optional[str] = None
        for i, w in enumerate(cws):
            if pending_art is not None:
                article_label[i] = APPEND2ID.get(pending_art, 0)
                pending_art = None
            if w.key in ("the", "a", "an") and self.script == "en":
                if rng.random() < 0.08:
                    skip_word[i] = True
                    pending_art = w.key

        in_words: List[Word] = []
        tp: List[Optional[int]] = []
        tc: List[Optional[int]] = []
        td: List[Optional[bool]] = []
        ta: List[Optional[int]] = []   # append head labels
        tr: List[Optional[int]] = []   # repl head labels
        tm: List[Optional[int]] = []   # merge head labels
        tpa: List[Optional[int]] = []  # para head labels

        sent_start = True
        for i, w in enumerate(cws):
            if skip_word[i]:
                continue

            gold_p = w.punct_state
            gold_c = w.case_state
            mark = PUNCT_LABELS[gold_p]

            # --- corrupt punctuation ---
            new_mark = mark
            if mark:
                r = rng.random()
                if r < self.DROP.get(mark, 0.5):
                    new_mark = ""
                elif r < self.DROP.get(mark, 0.5) + self.SPURIOUS_WRONG:
                    new_mark = rng.choice(
                        [m for m in self.other_marks if m != mark])
            elif rng.random() < self.SPURIOUS_ADD:
                new_mark = rng.choice([",", ",", ",", "."])

            # --- corrupt casing ---
            core = w.core
            if gold_c == CASE2ID["CAP"] and rng.random() < self.CAP_LOWERED:
                core = core.lower()
            elif gold_c == CASE2ID["LOWER"] and rng.random() < self.MID_CAP:
                core = core[:1].upper() + core[1:]

            lw = w.key

            # --- compound splitting (inverts merge/MERGE_SPACE) ---
            split_parts = None
            if lw in self._COMPOUND_MAP and rng.random() < 0.30:
                split_parts = self._COMPOUND_MAP[lw].split()

            # --- contraction expansion (inverts repl/CONTRACT) ---
            expanded = None
            if (self.script == "en" and split_parts is None
                    and lw in self._CONTRACTION_MAP and rng.random() < 0.03):
                expanded = self._CONTRACTION_MAP[lw].split()

            # --- inflection simplification (inverts repl/VERB_3SG, VERB_PAST) ---
            inflect_label = 0
            if (self.script == "en" and split_parts is None
                    and expanded is None and rng.random() < 0.02):
                cl = core.lower()
                if cl.endswith("ed") and len(cl) > 4:
                    core = core[:-2]
                    inflect_label = REPL2ID.get("VERB_PAST", 0)
                elif cl.endswith("es") and len(cl) > 4 and not cl.endswith("ses"):
                    core = core[:-2]
                    inflect_label = REPL2ID.get("VERB_3SG", 0)
                elif cl.endswith("s") and not cl.endswith("ss") and len(cl) > 3:
                    core = core[:-1]
                    inflect_label = REPL2ID.get("VERB_3SG", 0)

            art_lb = article_label[i]
            para_lb = PARA2ID.get("PARA_BREAK", 1) if i in para_break_after else 0

            # --- filler insertion (before current word) ---
            # STRONG fillers ("um", "uh") are labelled DELETE. SOFT fillers
            # ("like", "so") are inserted but MASKED: the teacher deletes them
            # only sometimes, so a hard label either way would be noise.
            if self.strong and rng.random() < self.FILLER_STRONG:
                in_words.append(split_word(rng.choice(self.strong)))
                tp.append(None); tc.append(None); td.append(True)
                ta.append(0); tr.append(0); tm.append(0); tpa.append(0)
            elif self.soft and rng.random() < self.FILLER_SOFT:
                in_words.append(split_word(rng.choice(self.soft)))
                tp.append(None); tc.append(None); td.append(None)
                ta.append(0); tr.append(0); tm.append(0); tpa.append(0)

            # --- emit word(s) ---
            if split_parts is not None and len(split_parts) == 2:
                # Compound split: two words; merge label on the first
                w1_str, w2_str = split_parts
                in_words.append(split_word(w1_str))
                tp.append(None); tc.append(gold_c); td.append(False)
                ta.append(art_lb); tr.append(0)
                tm.append(MERGE2ID.get("MERGE_SPACE", 1)); tpa.append(para_lb)
                in_words.append(split_word(w2_str + new_mark))
                tp.append(gold_p); tc.append(CASE2ID["LOWER"]); td.append(False)
                ta.append(0); tr.append(0); tm.append(0); tpa.append(0)
            elif expanded is not None:
                # Contraction expansion: emit all parts; CONTRACT label on first
                for ei, part in enumerate(expanded):
                    is_last = (ei == len(expanded) - 1)
                    in_words.append(split_word(part + (new_mark if is_last else "")))
                    if ei == 0:
                        tp.append(None); tc.append(gold_c); td.append(False)
                        ta.append(art_lb)
                        tr.append(REPL2ID.get("CONTRACT", 0))
                        tm.append(0); tpa.append(para_lb)
                    else:
                        tp.append(gold_p if is_last else None)
                        tc.append(CASE2ID["LOWER"]); td.append(None)
                        ta.append(0); tr.append(0); tm.append(0); tpa.append(0)
            else:
                # Normal word
                in_words.append(split_word(core + new_mark))
                tp.append(gold_p); tc.append(gold_c); td.append(False)
                ta.append(art_lb); tr.append(inflect_label)
                tm.append(0); tpa.append(para_lb)

            # --- immediate repetition (the model must DELETE the copy) ---
            if rng.random() < self.REPEAT:
                rep = split_word(core.lower())
                in_words.append(rep)
                tp.append(None); tc.append(None); td.append(True)
                ta.append(0); tr.append(0); tm.append(0); tpa.append(0)

            sent_start = mark in (".", "?", "!", "…")

        return build_example(in_words, tp, tc, td, self.script, source,
                             tgt_append=ta, tgt_repl=tr, tgt_merge=tm, tgt_para=tpa)


# =========================================================================
# Clean-text sources
# =========================================================================

SENT_SPLIT = re.compile(r"(?<=[.!?…])\s+")
BAD_LINE = re.compile(r"^\s*[=*#|]|\{\{|\}\}|\[\[|\]\]|\bhttps?://")



def golden_texts(path: Path = None) -> List[Tuple[str, str, str]]:
    """(clean_text, script, id) from the golden set, script-resolved."""
    d = json.loads((path or GOLDEN).read_text())
    out = []
    for e in d["entries"]:
        t = (e.get("goldenTranscript") or "").strip()
        if len(t.split()) < 5:
            continue
        out.append((t, detect_script(t), e["id"]))
    return out


# =========================================================================
# Main
# =========================================================================

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(HERE / "artifacts" / "data"))
    ap.add_argument("--seed", type=int, default=1234)
    # --wiki-* args are IGNORED and kept only for backward compatibility with
    # run_history_retrain.sh. The Wikipedia path has been removed permanently.
    # Wikipedia was 95.9% of the first corpus (163,337/170,396 rows) evaluated
    # 100% on real ASR; the domain gap produced the mismatch gradient that drove
    # the decision to remove it. Do not re-enable without a new argument.
    ap.add_argument("--wiki-en", type=int, default=0)  # ignored; backward compat
    ap.add_argument("--wiki-he", type=int, default=0)  # ignored; backward compat
    ap.add_argument("--wiki-ru", type=int, default=0)  # ignored; backward compat
    ap.add_argument("--wiki-eval", type=int, default=1500)  # ignored; backward compat
    ap.add_argument("--wispr-corpus", default=None,
                    help="path to artifacts/data/wispr_train.jsonl -- if provided, "
                         "merged into train at --indomain-repeats weight. "
                         "Primary source of labeled data for append/repl/merge/para heads.")
    ap.add_argument("--golden", default=str(GOLDEN),
                    help="golden-set JSON supplying in-domain clean text. Point at "
                         "artifacts/raw/history-golden.json for the whole recordings "
                         "history rather than the 400-entry benchmark corpus")
    ap.add_argument("--indomain-repeats", type=int, default=8,
                    help="how many differently-corrupted copies of each "
                         "in-domain clean utterance to emit")
    ap.add_argument("--teacher-repeat", type=int, default=6,
                    help="upweighting factor for real teacher pairs")
    ap.add_argument("--extra-train", action="append", default=[],
                    help="jsonl of already-labelled real pairs to fold into train "
                         "(e.g. data/train_real_large.jsonl, built by "
                         "build_eval_large.py under the strict alignment audit). "
                         "Repeatable.")
    ap.add_argument("--extra-train-repeat", type=int, default=6,
                    help="upweighting factor for --extra-train rows")
    ap.add_argument("--extra-train-weighted", action="append", default=[],
                    metavar="PATH:REPEAT",
                    help="like --extra-train but with a PER-FILE upweight, e.g. "
                         "data/gold_train.jsonl:12. Needed because the authored "
                         "reference pairs and the teacher-distilled pairs do not "
                         "deserve the same weight: one is authored under a strict "
                         "no-paraphrase constraint, the other is a 4B's own output. "
                         "Repeatable.")
    ap.add_argument("--holdout", action="append", default=[],
                    help="jsonl of held-out examples (e.g. data/eval_real_large.jsonl). "
                         "Any clean text whose norm_key matches one of them is kept out "
                         "of the corruption pool, so the held-out reference cannot reach "
                         "training as a synthetic target. Repeatable.")
    args = ap.parse_args()

    # Held-out keys, read before anything is built. Growing the clean-text pool to
    # the whole recordings history means the eval pairs' *reference* side is now a
    # candidate seed for synthetic corruption -- which would train the model on the
    # answer to its own eval. One key per pair covers both sides: `norm_key` strips
    # case, punctuation and fillers, which is precisely the set of differences a
    # usable teacher pair is allowed to have, so input and reference hash alike.
    holdout_keys: set = set()
    if args.holdout:
        # Deferred so the module-level import in build_eval_large (which imports
        # this file) does not become a cycle. By the time main() runs, this
        # module is fully initialised and the import is free.
        from build_eval_large import render_target
    for hp in args.holdout:
        p = Path(hp)
        if not p.exists():
            print(f"[holdout] missing, skipped: {p}")
            continue
        n = 0
        with p.open() as f:
            for line in f:
                d = json.loads(line)
                holdout_keys.add(norm_key(" ".join(d["words"])))
                # ...and the reference side. The two hash alike for a pair whose
                # only differences are case, punctuation and fillers, but the
                # audit tolerates up to 10% lexical drift, and a pair sitting in
                # that 10% would otherwise slip its reference into the clean pool.
                holdout_keys.add(norm_key(render_target(d)))
                n += 1
        print(f"[holdout] {p.name}: {n} examples -> {len(holdout_keys)} cumulative keys")
    holdout_keys.discard("")

    rng = random.Random(args.seed)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # ---------- 1. study ----------
    rows = load_db(SANDBOX_DB)
    if not rows:
        raise SystemExit(f"no rows in {SANDBOX_DB}")
    stats = study(rows)
    stats["_db"] = str(SANDBOX_DB)
    stats["_rows"] = len(rows)
    stats["_field_language_counts"] = dict(Counter(
        r.get("ZLANGUAGE") for r in rows))
    stats["_script_counts"] = dict(Counter(
        detect_script(r.get("ZTRANSCRIPTION") or "") for r in rows))
    (out.parent / "asr_stats.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=2))
    print("[study]", json.dumps({k: stats[k] for k in ("en", "he", "ru")},
                                ensure_ascii=False)[:900])
    print("[study] field-language counts:", stats["_field_language_counts"])
    print("[study] SCRIPT counts        :", stats["_script_counts"])

    # ---------- 2. teacher ----------
    teacher, reasons = build_teacher_set(rows)
    if holdout_keys:
        before = len(teacher)
        teacher = [e for e in teacher if norm_key(" ".join(e.words)) not in holdout_keys]
        print(f"[teacher] {before - len(teacher)} pairs withheld (in --holdout)")
    print("[teacher] filter report:", dict(reasons.most_common()))
    print("[teacher] kept", len(teacher), "by script",
          dict(Counter(e.script for e in teacher)))

    # Hold out a stratified eval slice of the REAL pairs. Never trained on.
    by_script = defaultdict(list)
    for e in teacher:
        by_script[e.script].append(e)
    teacher_eval, teacher_train = [], []
    for sc, lst in by_script.items():
        lst = sorted(lst, key=lambda x: " ".join(x.words))
        rng.shuffle(lst)
        k = max(2, int(round(0.20 * len(lst))))
        teacher_eval += lst[:k]
        teacher_train += lst[k:]
    print("[teacher] eval", len(teacher_eval), dict(Counter(e.script for e in teacher_eval)),
          "| train", len(teacher_train), dict(Counter(e.script for e in teacher_train)))

    # ---------- 3. clean text for synthetic corruption ----------
    clean: List[Tuple[str, str, str]] = []          # (text, script, source)

    # 3a. in-domain clean text: golden-set golden transcripts. The eval holdout
    #     is stratified BY SCRIPT (the file's `language` field is unreliable --
    #     it says he=93 but only 16 entries actually contain Hebrew script).
    gold = [g for g in golden_texts(Path(args.golden)) if g[1] in ("en", "he", "ru")]
    gold_by_sc = defaultdict(list)
    for g in gold:
        gold_by_sc[g[1]].append(g)
    gold_eval_ids = set()
    for sc, lst in gold_by_sc.items():
        lst = sorted(lst, key=lambda x: x[2])
        rng.shuffle(lst)
        gold_eval_ids |= {i for _, _, i in lst[: max(3, int(0.25 * len(lst)))]}
    n_gold_held = 0
    for t, sc, gid in gold:
        if norm_key(t) in holdout_keys:
            n_gold_held += 1
            continue
        clean.append((t, sc, "golden_eval" if gid in gold_eval_ids else "golden"))
    if n_gold_held:
        print(f"[clean] {n_gold_held} golden transcripts withheld (in --holdout)")

    # 3b. in-domain clean text: the teacher's polished outputs from the TRAIN
    #     split only (they are well-formed text; corrupting them gives in-domain
    #     synthetic pairs without leaking the eval slice).
    eval_keys = set(" ".join(e.words) for e in teacher_eval)
    for r in rows:
        if (r.get("ZAIMODENAME") or "") != "Correct":
            continue
        raw = (r.get("ZTRANSCRIPTION") or "").strip()
        pol = (r.get("ZAIENHANCEDTEXT") or "").strip()
        if not raw or not pol or teacher_quality_reject(raw, pol):
            continue
        if " ".join(w.raw for w in tokenize_words(raw)) in eval_keys:
            continue
        if norm_key(pol) in holdout_keys or norm_key(raw) in holdout_keys:
            continue
        sc = detect_script(pol)
        if sc in ("en", "he", "ru"):
            clean.append((pol, sc, "db_clean"))

    n_indomain = len(clean)
    print("[clean] in-domain utterances:", n_indomain,
          dict(Counter(s for _, s, _ in clean)))

    # ---------- 4. corrupt ----------
    corr = {sc: Corruptor(random.Random(args.seed + 7 * i), sc)
            for i, sc in enumerate(("en", "he", "ru"))}

    train: List[Example] = []
    val: List[Example] = []
    syn_eval: List[Example] = []       # in-domain (golden-set) synthetic eval
    wiki_eval: List[Example] = []      # out-of-domain synthetic eval, per script

    for text, sc, src in clean:
        reps = args.indomain_repeats if src in ("golden", "db_clean") else 1
        if src == "golden_eval":
            reps = 3
        for _ in range(reps):
            ex = corr[sc](text, src)
            if ex is None:
                continue
            if src == "golden_eval":
                syn_eval.append(ex)
            elif src == "wiki_eval":
                wiki_eval.append(ex)
            elif rng.random() < 0.01:
                val.append(ex)
            else:
                train.append(ex)

    # ---------- 5. teacher upweighting ----------
    train += teacher_train * args.teacher_repeat

    # 5b. externally-labelled real pairs (the strict-audit set). These are the
    #     highest-value rows in the corpus -- real ASR text on the input side,
    #     scored by the same alignment audit as eval -- so they are folded in at
    #     the same upweight as the teacher pairs, minus anything held out.
    extra_specs = [(xp, args.extra_train_repeat) for xp in args.extra_train]
    for spec in args.extra_train_weighted:
        path_s, _, rep_s = spec.rpartition(":")
        if not path_s:
            raise SystemExit(f"--extra-train-weighted wants PATH:REPEAT, got {spec!r}")
        extra_specs.append((path_s, int(rep_s)))
    for xp, repeat in extra_specs:
        p = Path(xp)
        if not p.exists():
            print(f"[extra] missing, skipped: {p}")
            continue
        got, skipped = [], 0
        with p.open() as f:
            for line in f:
                d = json.loads(line)
                if norm_key(" ".join(d["words"])) in holdout_keys:
                    skipped += 1
                    continue
                got.append(Example.from_json(d))
        train += got * repeat
        print(f"[extra] {p.name}: +{len(got)} pairs x{repeat} "
              f"({skipped} withheld) scripts={dict(Counter(e.script for e in got))}")

    # ---------- 5b. Wispr corpus ----------
    # In-domain labeled pairs for the new heads (append/repl/merge/para).
    # Weighted at the same rate as golden in-domain text (--indomain-repeats).
    if args.wispr_corpus:
        p = Path(args.wispr_corpus)
        if not p.exists():
            print(f"[wispr] missing, skipped: {p}")
        else:
            got, skipped = [], 0
            with p.open() as f:
                for line in f:
                    d = json.loads(line)
                    if norm_key(" ".join(d["words"])) in holdout_keys:
                        skipped += 1
                        continue
                    e = Example.from_json(d)
                    e = e._replace(source="wispr") if hasattr(e, "_replace") else e
                    got.append(e)
            repeat = args.indomain_repeats
            train += got * repeat
            print(f"[wispr] {p.name}: +{len(got)} pairs x{repeat} "
                  f"({skipped} withheld) "
                  f"scripts={dict(Counter(e.script for e in got))}")

    # Zero-Wikipedia assertion: the wiki path was permanently removed.
    wiki_rows = sum(1 for r in train if r.source == "wiki")
    assert wiki_rows == 0, f"BUG: {wiki_rows} Wikipedia rows crept in"

    rng.shuffle(train)

    def dump(name: str, xs: Sequence[Example]) -> None:
        p = out / f"{name}.jsonl"
        with p.open("w") as f:
            for e in xs:
                f.write(json.dumps(e.to_json(), ensure_ascii=False) + "\n")
        print(f"[write] {p}  n={len(xs)}  scripts={dict(Counter(e.script for e in xs))}"
              f"  sources={dict(Counter(e.source for e in xs))}")

    dump("train", train)
    dump("val", val)
    dump("eval_synth", syn_eval)
    dump("eval_wiki", wiki_eval)
    dump("eval_real", teacher_eval)

    meta = {
        "seed": args.seed,
        "teacher_filter": dict(reasons.most_common()),
        "teacher_kept": len(teacher),
        "teacher_train": len(teacher_train),
        "teacher_eval": len(teacher_eval),
        "teacher_eval_by_script": dict(Counter(e.script for e in teacher_eval)),
        "teacher_train_by_script": dict(Counter(e.script for e in teacher_train)),
        "train": len(train), "val": len(val),
        "eval_synth": len(syn_eval), "eval_wiki": len(wiki_eval),
        "eval_real": len(teacher_eval),
        "train_by_script": dict(Counter(e.script for e in train)),
        "corruption": {k: v for k, v in vars(Corruptor).items()
                       if k.isupper()},
    }
    (out.parent / "corpus_meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2, default=str))
    print("[done]", json.dumps({k: meta[k] for k in
                                ("teacher_kept", "train", "val", "eval_synth",
                                 "eval_wiki", "eval_real",
                                 "train_by_script")}))


if __name__ == "__main__":
    main()

"""
Shared primitives for the mmBERT transcript-polishing edit tagger.

Label scheme (GECToR-style, one label set per head, emitted on the FIRST subword
of each whitespace word; all other subwords are masked with -100):

  error : binary  {0 = no change needed, 1 = this word needs some edit}
  punct : 9-way   absolute TARGET trailing punctuation for this word
  case  : 4-way   absolute TARGET casing for this word's alphabetic core
  disf  : binary  {0 = keep the word, 1 = delete it (filler / repetition)}

`punct` and `case` are ABSOLUTE targets, not deltas. The edit that actually gets
applied at inference is `predicted_state != current_state_of_the_input_word`, so
precision is measured over real applied changes -- which is what the release gate
is about. The KEEP bias is implemented as an additive logit prior on the class
that equals the input's current state (see train.py / MMBERTEditingModel).
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

# --------------------------------------------------------------------------
# Label vocabularies
# --------------------------------------------------------------------------

PUNCT_LABELS = ["", ".", ",", "?", "!", ";", ":", "…", "—"]
PUNCT2ID = {p: i for i, p in enumerate(PUNCT_LABELS)}
N_PUNCT = len(PUNCT_LABELS)

CASE_LABELS = ["LOWER", "CAP", "UPPER"]
CASE2ID = {c: i for i, c in enumerate(CASE_LABELS)}
N_CASE = len(CASE_LABELS)

N_ERROR = 2
N_DISF = 2

IGNORE = -100

# Trailing characters we treat as "punctuation attached to the previous word".
_TRAIL = ".,?!;:…—-–"
_QUOTES = "\"'“”’»«)]}"


# --------------------------------------------------------------------------
# Script / language resolution -- NEVER trust the DB `ZLANGUAGE` field, it
# records the routed model, not the speech. Resolve by Unicode script.
# --------------------------------------------------------------------------

def detect_script(text: str) -> str:
    """Return 'he', 'ru', 'en' or 'unk' from the character mix of `text`."""
    he = ru = la = 0
    for ch in text:
        o = ord(ch)
        if 0x0590 <= o <= 0x05FF or 0xFB1D <= o <= 0xFB4F:
            he += 1
        elif 0x0400 <= o <= 0x04FF or 0x0500 <= o <= 0x052F:
            ru += 1
        elif ch.isalpha() and ch.isascii():
            la += 1
    total = he + ru + la
    if total < 3:
        return "unk"
    if he / total > 0.20:
        return "he"
    if ru / total > 0.20:
        return "ru"
    return "en"


def has_case(word: str) -> bool:
    """True if the word contains at least one character that HAS a case pair.

    Hebrew has no casing, so every Hebrew word returns False and its `case`
    label is masked out. This is how the casing head is made an explicit no-op
    for Hebrew rather than a source of noise.
    """
    for ch in word:
        if ch.lower() != ch.upper():
            return True
    return False


# --------------------------------------------------------------------------
# Word model: a word is (leading junk, alphabetic core, trailing punctuation)
# --------------------------------------------------------------------------

@dataclass
class Word:
    raw: str            # exactly as it appeared, whitespace-stripped
    core: str           # the word with trailing punctuation removed
    trail: str          # the trailing punctuation string ("" if none)

    @property
    def key(self) -> str:
        """Case- and punctuation-insensitive identity, for alignment."""
        return strip_accents(self.core.lower())

    @property
    def punct_state(self) -> int:
        """Index into PUNCT_LABELS for the punctuation currently attached."""
        return PUNCT2ID.get(normalise_punct(self.trail), PUNCT2ID[""])

    @property
    def case_state(self) -> Optional[int]:
        if not has_case(self.core):
            return None
        letters = [c for c in self.core if c.lower() != c.upper()]
        if not letters:
            return None
        if all(c.isupper() for c in letters) and len(letters) > 1:
            return CASE2ID["UPPER"]
        if letters[0].isupper():
            return CASE2ID["CAP"]
        return CASE2ID["LOWER"]


def strip_accents(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if unicodedata.category(c) != "Mn")


def normalise_punct(trail: str) -> str:
    """Collapse a trailing-punctuation run to a single canonical label."""
    t = trail.strip(_QUOTES)
    if not t:
        return ""
    if "..." in t or "…" in t:
        return "…"
    # Strongest mark wins, in this order.
    for ch in "?!.;:,":
        if ch in t:
            return ch
    if "—" in t or "–" in t or "-" in t:
        return "—"
    return ""


def split_word(raw: str) -> Word:
    m = re.search(r"[" + re.escape(_TRAIL + _QUOTES) + r"]+$", raw)
    if m and m.start() > 0:
        return Word(raw=raw, core=raw[: m.start()], trail=raw[m.start():])
    return Word(raw=raw, core=raw, trail="")


def tokenize_words(text: str) -> List[Word]:
    return [split_word(w) for w in text.split() if w.strip()]


def apply_case(core: str, case_id: int) -> str:
    if case_id == CASE2ID["UPPER"]:
        return core.upper()
    if case_id == CASE2ID["CAP"]:
        # Capitalise the first cased character, leave the rest alone.
        for i, ch in enumerate(core):
            if ch.lower() != ch.upper():
                return core[:i] + ch.upper() + core[i + 1:]
        return core
    # LOWER
    return core.lower()


def render(words: Sequence[Word], punct: Sequence[int], case: Sequence[Optional[int]],
           delete: Sequence[bool]) -> str:
    out = []
    for w, p, c, d in zip(words, punct, case, delete):
        if d:
            continue
        core = apply_case(w.core, c) if c is not None else w.core
        out.append(core + PUNCT_LABELS[p])
    return " ".join(out)


# --------------------------------------------------------------------------
# Example container
# --------------------------------------------------------------------------

@dataclass
class Example:
    words: List[str]                    # the INPUT words (corrupted / raw ASR)
    punct: List[int]                    # target punct id per word, or IGNORE
    case: List[int]                     # target case id per word, or IGNORE
    disf: List[int]                     # 1 = delete, or IGNORE
    error: List[int]                    # 1 = any edit needed, or IGNORE
    script: str
    source: str                         # 'wiki' | 'golden' | 'teacher' | 'db'

    def to_json(self) -> dict:
        return {
            "words": self.words, "punct": self.punct, "case": self.case,
            "disf": self.disf, "error": self.error,
            "script": self.script, "source": self.source,
        }

    @staticmethod
    def from_json(d: dict) -> "Example":
        return Example(d["words"], d["punct"], d["case"], d["disf"],
                       d["error"], d["script"], d["source"])


def build_example(input_words: Sequence[Word],
                  tgt_punct: Sequence[int],
                  tgt_case: Sequence[Optional[int]],
                  tgt_delete: Sequence[Optional[bool]],
                  script: str, source: str) -> Example:
    """Assemble an Example, masking case labels for uncased scripts."""
    words, punct, case, disf, error = [], [], [], [], []
    for w, p, c, d in zip(input_words, tgt_punct, tgt_case, tgt_delete):
        words.append(w.raw)
        pl = IGNORE if p is None else p
        # Casing head is a hard no-op for words with no cased characters
        # (all of Hebrew, digits, symbols).
        if not has_case(w.core) or c is None:
            cl = IGNORE
        else:
            cl = c
        dl = IGNORE if d is None else int(d)
        punct.append(pl)
        case.append(cl)
        disf.append(dl)
        changed = 0
        if pl != IGNORE and pl != w.punct_state:
            changed = 1
        if cl != IGNORE and cl != w.case_state:
            changed = 1
        if dl == 1:
            changed = 1
        # If every head is masked we cannot say anything about `error`.
        if pl == IGNORE and cl == IGNORE and dl == IGNORE:
            error.append(IGNORE)
        else:
            error.append(changed)
    return Example(words, punct, case, disf, error, script, source)


# --------------------------------------------------------------------------
# Subword encoding
# --------------------------------------------------------------------------

HEADS = ["error", "punct", "case", "disf"]
HEAD_SIZES = {"error": N_ERROR, "punct": N_PUNCT, "case": N_CASE, "disf": N_DISF}


def encode(example: Example, tokenizer, max_len: int) -> Optional[dict]:
    """Tokenise word-by-word, putting labels on the first subword of each word.

    Also emits `punct_state` / `case_state`: the input's CURRENT state per word,
    used both for the KEEP logit prior and for deciding whether a prediction is
    an actual edit at inference time.
    """
    ids = [tokenizer.cls_token_id if tokenizer.cls_token_id is not None
           else tokenizer.bos_token_id]
    lab = {h: [IGNORE] for h in HEADS}
    p_state = [0]
    c_state = [0]
    word_index = [-1]

    for wi, raw in enumerate(example.words):
        # Leading space matters for SentencePiece-style vocabularies.
        piece = tokenizer.encode(" " + raw if wi > 0 else raw,
                                 add_special_tokens=False)
        if not piece:
            continue
        if len(ids) + len(piece) + 1 > max_len:
            break
        w = split_word(raw)
        for k, tid in enumerate(piece):
            ids.append(tid)
            first = (k == 0)
            for h in HEADS:
                lab[h].append(getattr(example, h)[wi] if first else IGNORE)
            p_state.append(w.punct_state)
            cs = w.case_state
            c_state.append(cs if cs is not None else 0)
            word_index.append(wi if first else -1)

    eos = tokenizer.sep_token_id if tokenizer.sep_token_id is not None \
        else tokenizer.eos_token_id
    ids.append(eos)
    for h in HEADS:
        lab[h].append(IGNORE)
    p_state.append(0)
    c_state.append(0)
    word_index.append(-1)

    if len(ids) <= 2:
        return None
    return {
        "input_ids": ids,
        "attention_mask": [1] * len(ids),
        **{f"labels_{h}": lab[h] for h in HEADS},
        "punct_state": p_state,
        "case_state": c_state,
        "word_index": word_index,
        "script": example.script,
        "source": example.source,
    }


SCRIPTS = ["en", "he", "ru"]
SCRIPT2ID = {s: i for i, s in enumerate(SCRIPTS)}

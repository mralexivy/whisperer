"""
Shared primitives for the mmBERT transcript-polishing edit tagger.

Label scheme (GECToR-style, one label set per head, emitted on the FIRST subword
of each whitespace word; all other subwords are masked with -100):

  error  : binary  {0 = no change needed, 1 = this word needs some edit}
  punct  : 9-way   absolute TARGET trailing punctuation for this word
  case   : 3-way   absolute TARGET casing for this word's alphabetic core
  disf   : binary  {0 = keep the word, 1 = delete it (filler / repetition)}
  append : 101-way absolute TARGET word to append after this word (0 = NONE)
  repl   : N_REPL-way replacement transform or literal (0 = NONE)
  merge  : 4-way   merge/split operation between this word and the next
  para   : 3-way   paragraph / list-item break after this word

`punct` and `case` are ABSOLUTE targets, not deltas. The edit that actually gets
applied at inference is `predicted_state != current_state_of_the_input_word`, so
precision is measured over real applied changes -- which is what the release gate
is about. The KEEP bias is implemented as an additive logit prior on the class
that equals the input's current state (see train.py / MMBERTEditingModel).
"""

from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
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

# --- Append vocab ---
APPEND_VOCAB = ["NONE","the","a","is","are","an","to","in","of","that","it",
  "not","for","on","you","was","with","at","this","have","we","they","or","be",
  "as","but","by","can","had","his","from","she","what","their","do","which",
  "one","would","all","there","some","been","also","its","so","my","when","more",
  "up","no","if","out","about","who","get","your","said","could","them","into",
  "just","then","our","will","has","like","than","other","how","may","two",
  "these","should","her","him","any","were","now","here","over","time","first",
  "very","need","make","see","way","use","does","only","new","because","going",
  "back","people","well","know","want"]
N_APPEND = len(APPEND_VOCAB)  # 101
APPEND2ID = {w: i for i, w in enumerate(APPEND_VOCAB)}
APPEND_LABELS = APPEND_VOCAB  # alias used by calibrate.py

# --- G-transform vocab ---
GTRANSFORMS = ["NONE","PLURAL","SINGULAR","VERB_3SG","VERB_PAST","VERB_ING","CONTRACT","EXPAND"]
N_GTRANSFORM = len(GTRANSFORMS)  # 8

# --- Replacement vocab: g-transforms + literal replacements from data/repl_vocab.json ---
_REPL_VOCAB_PATH = Path(__file__).parent / "data" / "repl_vocab.json"
try:
    with _REPL_VOCAB_PATH.open() as _f:
        REPL_LITERALS: List[str] = json.load(_f)[:150]
except FileNotFoundError:
    REPL_LITERALS = []

N_REPL_LITERALS = len(REPL_LITERALS)
REPL_VOCAB: List[str] = GTRANSFORMS + REPL_LITERALS
N_REPL = len(REPL_VOCAB)  # 8 + up to 150 = up to 158
REPL2ID = {w: i for i, w in enumerate(REPL_VOCAB)}
REPL_LABELS = REPL_VOCAB  # alias used by calibrate.py

# --- Merge vocab ---
MERGE_LABELS = ["NONE","MERGE_SPACE","MERGE_HYPHEN","SPLIT"]
N_MERGE = len(MERGE_LABELS)  # 4
MERGE2ID = {m: i for i, m in enumerate(MERGE_LABELS)}

# --- Paragraph vocab ---
PARA_LABELS = ["NONE","PARA_BREAK","LIST_ITEM"]
N_PARA = len(PARA_LABELS)  # 3
PARA2ID = {p: i for i, p in enumerate(PARA_LABELS)}

# --- Destination conditioning ---
DEST_CLASSES = ["unknown","editor","chat","browser","messaging"]
N_DEST = len(DEST_CLASSES)  # 5
DEST2ID = {d: i for i, d in enumerate(DEST_CLASSES)}
BUNDLE_TO_DEST = {
    "com.microsoft.VSCode": "editor",
    "com.todesktop.230313mzl4w4u92": "editor",
    "com.sublimetext.4": "editor",
    "com.google.Chrome": "browser",
    "org.mozilla.firefox": "browser",
    "com.apple.Safari": "browser",
    "com.tinyspeck.slackmacgap": "messaging",
    "ru.keepcoder.Telegram": "messaging",
    "com.anthropic.claudefordesktop": "chat",
    "com.openai.chat": "chat",
}

# --- Head registry ---
HEADS = ["error","punct","case","disf","append","repl","merge","para"]
HEAD_SIZES = {
    "error": N_ERROR,
    "punct": N_PUNCT,
    "case": N_CASE,
    "disf": N_DISF,
    "append": N_APPEND,
    "repl": N_REPL,
    "merge": N_MERGE,
    "para": N_PARA,
}

# Trailing characters we treat as "punctuation attached to the previous word".
_TRAIL = ".,?!;:…—-–"
_QUOTES = "\"'""'»«)]}"


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
    append: List[int] = field(default_factory=list)   # target append id per word, or IGNORE
    repl: List[int] = field(default_factory=list)     # target repl id per word, or IGNORE
    merge: List[int] = field(default_factory=list)    # target merge id per word, or IGNORE
    para: List[int] = field(default_factory=list)     # target para id per word, or IGNORE
    dest: int = 0                                     # destination class id

    def __post_init__(self):
        n = len(self.words)
        if not self.append:
            self.append = [IGNORE] * n
        if not self.repl:
            self.repl = [IGNORE] * n
        if not self.merge:
            self.merge = [IGNORE] * n
        if not self.para:
            self.para = [IGNORE] * n

    def to_json(self) -> dict:
        return {
            "words": self.words, "punct": self.punct, "case": self.case,
            "disf": self.disf, "error": self.error,
            "script": self.script, "source": self.source,
            "append": self.append, "repl": self.repl,
            "merge": self.merge, "para": self.para,
            "dest": self.dest,
        }

    @staticmethod
    def from_json(d: dict) -> "Example":
        n = len(d["words"])
        return Example(
            words=d["words"],
            punct=d["punct"],
            case=d["case"],
            disf=d["disf"],
            error=d["error"],
            script=d["script"],
            source=d["source"],
            append=d.get("append", [IGNORE] * n),
            repl=d.get("repl", [IGNORE] * n),
            merge=d.get("merge", [IGNORE] * n),
            para=d.get("para", [IGNORE] * n),
            dest=d.get("dest", 0),
        )


def build_example(input_words: Sequence[Word],
                  tgt_punct: Sequence[int],
                  tgt_case: Sequence[Optional[int]],
                  tgt_delete: Sequence[Optional[bool]],
                  script: str, source: str,
                  tgt_append: Optional[Sequence[Optional[int]]] = None,
                  tgt_repl: Optional[Sequence[Optional[int]]] = None,
                  tgt_merge: Optional[Sequence[Optional[int]]] = None,
                  tgt_para: Optional[Sequence[Optional[int]]] = None,
                  dest: int = 0) -> Example:
    """Assemble an Example, masking case labels for uncased scripts."""
    words, punct, case, disf, error = [], [], [], [], []
    append_labels, repl_labels, merge_labels, para_labels = [], [], [], []
    for i, (w, p, c, d) in enumerate(zip(input_words, tgt_punct, tgt_case, tgt_delete)):
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

        # New heads — NONE class (0) is the default/no-op.
        al = IGNORE if (tgt_append is None or tgt_append[i] is None) else tgt_append[i]
        rl = IGNORE if (tgt_repl is None or tgt_repl[i] is None) else tgt_repl[i]
        ml = IGNORE if (tgt_merge is None or tgt_merge[i] is None) else tgt_merge[i]
        pal = IGNORE if (tgt_para is None or tgt_para[i] is None) else tgt_para[i]
        append_labels.append(al)
        repl_labels.append(rl)
        merge_labels.append(ml)
        para_labels.append(pal)

    return Example(words, punct, case, disf, error, script, source,
                   append_labels, repl_labels, merge_labels, para_labels, dest)


# --------------------------------------------------------------------------
# Subword encoding
# --------------------------------------------------------------------------

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
        "dest_id": example.dest,
    }


SCRIPTS = ["en", "he", "ru"]
SCRIPT2ID = {s: i for i, s in enumerate(SCRIPTS)}


# --------------------------------------------------------------------------
# Destination helper
# --------------------------------------------------------------------------

def bundle_id_to_dest(bundle_id: str) -> int:
    """Map a macOS bundle ID to a DEST2ID value.

    Checks BUNDLE_TO_DEST for an exact match first, then a prefix match for
    com.jetbrains (which covers all JetBrains IDEs). Returns DEST2ID['unknown']
    if nothing matches.
    """
    if bundle_id in BUNDLE_TO_DEST:
        return DEST2ID[BUNDLE_TO_DEST[bundle_id]]
    if bundle_id.startswith("com.jetbrains"):
        return DEST2ID["editor"]
    return DEST2ID["unknown"]


# --------------------------------------------------------------------------
# G-transform helpers
# --------------------------------------------------------------------------

try:
    import inflect as _inflect_mod
    _inflect = _inflect_mod.engine()
    _INFLECT_AVAILABLE = True
except ImportError:
    _inflect = None
    _INFLECT_AVAILABLE = False

_CONTRACTIONS = {
    "do not": "don't", "does not": "doesn't", "did not": "didn't",
    "is not": "isn't", "are not": "aren't", "was not": "wasn't",
    "were not": "weren't", "have not": "haven't", "has not": "hasn't",
    "had not": "hadn't", "will not": "won't", "would not": "wouldn't",
    "can not": "can't", "cannot": "can't", "could not": "couldn't",
    "should not": "shouldn't", "I am": "I'm", "you are": "you're",
    "he is": "he's", "she is": "she's", "it is": "it's",
    "we are": "we're", "they are": "they're", "I will": "I'll",
    "I have": "I've", "I would": "I'd", "I had": "I'd",
}
_EXPANSIONS = {
    "don't": "do not", "doesn't": "does not", "didn't": "did not",
    "isn't": "is not", "aren't": "are not", "wasn't": "was not",
    "weren't": "were not", "haven't": "have not", "hasn't": "has not",
    "hadn't": "had not", "won't": "will not", "wouldn't": "would not",
    "can't": "cannot", "couldn't": "could not", "shouldn't": "should not",
    "I'm": "I am", "you're": "you are", "he's": "he is", "she's": "she is",
    "it's": "it is", "we're": "we are", "they're": "they are",
    "I'll": "I will", "I've": "I have", "I'd": "I would",
    "'ve": "have", "'re": "are", "'ll": "will", "'m": "am",
}


def apply_gtransform(word: str, transform: str) -> Optional[str]:
    """Apply a g-transform to a word. Returns None if not applicable."""
    w = word.strip(".,!?;:\"'")
    if transform == "PLURAL":
        if not _INFLECT_AVAILABLE:
            return None
        r = _inflect.plural(w)
        return r if r and r != w else None
    if transform == "SINGULAR":
        if not _INFLECT_AVAILABLE:
            return None
        r = _inflect.singular_noun(w)
        return r if r and r != w else None
    if transform == "VERB_3SG":
        if w.endswith(('s', 'x', 'z', 'ch', 'sh')):
            r = w + "es"
        elif w.endswith('y') and len(w) > 1 and w[-2] not in 'aeiou':
            r = w[:-1] + "ies"
        else:
            r = w + "s"
        return r if r != w else None
    if transform == "VERB_PAST":
        if w.endswith('e'):
            r = w + "d"
        elif w.endswith('y') and len(w) > 1 and w[-2] not in 'aeiou':
            r = w[:-1] + "ied"
        else:
            r = w + "ed"
        return r if r != w else None
    if transform == "VERB_ING":
        if w.endswith('ie'):
            r = w[:-2] + "ying"
        elif w.endswith('e') and len(w) > 1:
            r = w[:-1] + "ing"
        else:
            r = w + "ing"
        return r if r != w else None
    if transform == "CONTRACT":
        return _CONTRACTIONS.get(word)
    if transform == "EXPAND":
        return _EXPANSIONS.get(word)
    return None

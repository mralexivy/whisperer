#!/usr/bin/env python3
"""One table: every engine x he/ru/en on the same FLEURS clips, same normalisation as score.py.
Per cell: corpus WER%, median per-clip WER%, wrong-script%. Plus overall mean RTF and punctuation%.
usage: matrix.py [key ...]   (defaults to the app-* hyps plus the Omni and Nemotron reference runs)"""
import glob, json, os, re, statistics, sys, unicodedata
here = os.path.dirname(os.path.abspath(__file__))
def norm(s):
    s = unicodedata.normalize("NFKD", s.lower())
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = "".join(" " if unicodedata.category(ch)[0] in "PS" else ch for ch in s)
    return re.sub(r"\s+", " ", s).strip()
def lev(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (x != y)))
        prev = cur
    return prev[-1]
SCRIPT = {"he": r"[֐-׿]", "ru": r"[Ѐ-ӿ]", "en": r"[A-Za-z]"}
def wrong_script(text, lang):
    letters = [c for c in text if c.isalpha()]
    if not letters: return True
    return sum(bool(re.match(SCRIPT[lang], c)) for c in letters) / len(letters) < 0.5
refs = {}
for f in glob.glob(os.path.join(here, "manifests", "*.jsonl")):
    for l in open(f, encoding="utf-8"):
        c = json.loads(l); refs[c["id"]] = c
LABEL = {"app-whisper-q5": "Whisper V3 Turbo Q5 (app)", "app-whisper-q8": "Whisper V3 Turbo Q8_0 (same bridge, not shipped)", "app-ivrit": "ivrit-v3-turbo (app)",
         "app-qwen3": "Qwen3-ASR 1.7B 8-bit (app)", "app-parakeet-v3": "Parakeet v3 (app)",
         "omni-7b-4": "Omni CTC 7B 4-bit (not in app)", "omni-3b-4": "Omni CTC 3B 4-bit (not in app)",
         "nemotron-auto": "Nemotron 0.6B, no hint (app, streaming)", "nemotron-hint": "Nemotron 0.6B, lang hint (app, streaming)"}
EXCLUDE = set(filter(None, os.environ.get("EXCLUDE", "").split(",")))  # e.g. EXCLUDE=ru-1795 to drop a clip from every row
keys = sys.argv[1:] or [k for k in LABEL if os.path.exists(os.path.join(here, "hyp", k + ".jsonl"))]
print(f"{'engine':<42}" + "".join(f"{l:>26}" for l in ("Hebrew", "Russian", "English")) + f"{'RTF':>8}{'punct%':>8}")
print(f"{'':<42}" + "".join(f"{'WER / med / wrongscr':>26}" for _ in range(3)))
for k in keys:
    rows = [json.loads(l) for l in open(os.path.join(here, "hyp", k + ".jsonl"), encoding="utf-8")]
    cells, rtfs, punct, n = [], [], 0, 0
    for lang in ("he", "ru", "en"):
        rs = [r for r in rows if r["lang"] == lang and r.get("ok", True) and r["id"] not in EXCLUDE]
        if not rs: cells.append(f"{'n/a':>26}"); continue
        we = wn = 0; per = []; ws = 0
        for r in rs:
            ref, hyp = norm(refs[r["id"]]["ref"]).split(), norm(r["text"]).split()
            e = lev(ref, hyp); we += e; wn += len(ref); per.append(e / max(len(ref), 1))
            ws += wrong_script(r["text"], lang)
            if r.get("rtf") is not None: rtfs.append(r["rtf"])
            punct += bool(re.search(r"[.,?!;:]", r["text"])); n += 1
        cells.append(f"{100*we/wn:>8.1f} /{100*statistics.median(per):>6.1f} /{100*ws/len(rs):>5.0f}%  ({len(rs)})".rjust(26))
    print(f"{LABEL.get(k, k):<42}" + "".join(cells) + f"{(sum(rtfs)/len(rtfs) if rtfs else 0):>8.3f}{100*punct/max(n,1):>8.0f}")

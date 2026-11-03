#!/usr/bin/env python3
"""Corpus-level WER/CER per engine x language. usage: score.py [engine ...]"""
import glob, json, os, re, sys, unicodedata
here = os.path.dirname(os.path.abspath(__file__))
def norm(s):
    s = unicodedata.normalize("NFKD", s.lower())
    s = "".join(ch for ch in s if not unicodedata.combining(ch) or ch == "̆" and False)  # strips niqqud/accents
    s = "".join(" " if unicodedata.category(ch)[0] in "PS" else ch for ch in s)
    return re.sub(r"\s+", " ", s).strip()
def lev(a, b):
    prev = list(range(len(b)+1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j]+1, cur[j-1]+1, prev[j-1]+(x != y)))
        prev = cur
    return prev[-1]
refs = {}
for f in glob.glob(os.path.join(here, "manifests", "*.jsonl")):
    for l in open(f, encoding="utf-8"):
        c = json.loads(l); refs[c["id"]] = c
keys = sys.argv[1:] or sorted(os.path.basename(p)[:-6] for p in glob.glob(os.path.join(here, "hyp", "*.jsonl")))
print(f"{'engine':<14}{'lang':<5}{'n':>4}{'WER%':>8}{'CER%':>8}{'RTF':>8}{'empty':>7}{'punct%':>8}{'upper%':>8}")
for k in keys:
    rows = [json.loads(l) for l in open(os.path.join(here, "hyp", f"{k}.jsonl"), encoding="utf-8")]
    for lang in ("he", "ru", "en", "cs"):
        rs = [r for r in rows if r["lang"] == lang and r["ok"]]
        if not rs: continue
        we = wn = ce = cn = empty = 0; rtfs = []; punct = upper = 0
        for r in rs:
            ref, hyp = norm(refs[r["id"]]["ref"]), norm(r["text"])
            if not hyp: empty += 1
            rw, hw = ref.split(), hyp.split()
            we += lev(rw, hw); wn += len(rw)
            ce += lev(ref, hyp); cn += len(ref)
            if r["rtf"] is not None: rtfs.append(r["rtf"])
            punct += bool(re.search(r"[.,?!;:]", r["text"])); upper += bool(re.search(r"[A-ZА-Я]", r["text"]))
        print(f"{k:<14}{lang:<5}{len(rs):>4}{100*we/wn:>8.1f}{100*ce/cn:>8.1f}{sum(rtfs)/max(len(rtfs),1):>8.3f}{empty:>7}{100*punct/len(rs):>8.0f}{100*upper/len(rs):>8.0f}")

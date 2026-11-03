#!/usr/bin/env python3
"""CER with all whitespace removed from ref and hyp, on the ids common to every listed engine.
Separates content errors from word-boundary errors (the CrispASR Omni LLM path emits no spaces for he/ru).
usage: score_nospace.py <engine> [engine ...]"""
import json, os, re, sys, unicodedata
here = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(here, "score.py")).read().split("refs = {}")[0])  # norm, lev
refs = {}
for lang in ("he", "ru", "en", "cs"):
    for l in open(os.path.join(here, "manifests", f"{lang}.jsonl"), encoding="utf-8"):
        c = json.loads(l); refs[c["id"]] = c
rows = {k: {r["id"]: r for r in map(json.loads, open(os.path.join(here, "hyp", f"{k}.jsonl"), encoding="utf-8")) if r["ok"]} for k in sys.argv[1:]}
def common_for(lang):
    sets = [{i for i in v if i.startswith(lang + "-")} for v in rows.values()]
    return set.intersection(*[x for x in sets if x]) if any(sets) else set()
print("common clips per lang:", {l: len(common_for(l)) for l in ("he","ru","en")})
print(f"{'engine':<18}" + "".join(f"{l:>9}" for l in ("he", "ru", "en")))
for k, v in rows.items():
    cells = []
    for lang in ("he", "ru", "en"):
        ids = [i for i in common_for(lang) if i in v]
        e = n = 0
        for i in ids:
            ref = norm(refs[i]["ref"]).replace(" ", ""); hyp = norm(v[i]["text"]).replace(" ", "")
            e += lev(ref, hyp); n += len(ref)
        cells.append(f"{100*e/n:9.1f}" if n else f"{'-':>9}")
    print(f"{k:<18}" + "".join(cells))

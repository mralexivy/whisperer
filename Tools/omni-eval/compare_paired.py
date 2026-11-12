#!/usr/bin/env python3
"""Paired comparison of two engines on the same FLEURS clips, with 95% bootstrap intervals.
usage: compare_paired.py engineA engineB    (hyp/<engine>.jsonl)
Per language: WER and CER of each, the difference, and its 95% interval (2000 resamples of clips).
'Case+punct WER' scores the raw transcript against FLEURS' punctuated, cased reference, so
missing punctuation and capitals count — what a user reading the text sees."""
import json, random, re, sys
exec(open(__file__.replace("compare_paired.py", "score.py")).read().split("refs = {}")[0])
man = {}
for f in ["manifests/he.jsonl", "manifests/ru.jsonl", "manifests/en.jsonl"]:
    for l in open(f, encoding="utf-8"):
        c = json.loads(l); man[c["id"]] = c
def load(e): return {r["id"]: r for r in (json.loads(l) for l in open(f"hyp/{e}.jsonl", encoding="utf-8")) if r.get("set", r["lang"]) == r["lang"]}
A, B = sys.argv[1], sys.argv[2]; a, b = load(A), load(B)
def rawtok(t): return re.findall(r"\w+|[^\w\s]", t.replace("‏", ""))
def clip_errors(i, eng, kind):
    r = man[i]; h = eng[i]["text"]
    if kind == "wer": ref, hyp = norm(r["ref"]).split(), norm(h).split()
    elif kind == "cer": ref, hyp = list(norm(r["ref"])), list(norm(h))
    else: ref, hyp = rawtok(r["ref_raw"]), rawtok(h)
    return lev(ref, hyp), len(ref)
random.seed(7)
print(f"{'lang':<5}{'metric':<17}{A:>12}{B:>12}{'diff':>8}  95% interval of diff")
for lang in ("he", "ru", "en"):
    ids = [i for i in man if man[i]["lang"] == lang and i in a and i in b]
    for kind, label in (("wer", "WER"), ("cer", "CER"), ("raw", "case+punct WER")):
        ea = [clip_errors(i, a, kind) for i in ids]; eb = [clip_errors(i, b, kind) for i in ids]
        rate = lambda xs: 100 * sum(x[0] for x in xs) / max(sum(x[1] for x in xs), 1)
        va, vb = rate(ea), rate(eb)
        diffs = []
        for _ in range(2000):
            pick = [random.randrange(len(ids)) for _ in ids]
            diffs.append(rate([ea[k] for k in pick]) - rate([eb[k] for k in pick]))
        diffs.sort(); lo, hi = diffs[50], diffs[1949]
        sig = "real" if lo > 0 or hi < 0 else "not significant"
        print(f"{lang:<5}{label:<17}{va:>11.1f}%{vb:>11.1f}%{va-vb:>+8.1f}  [{lo:+.1f}, {hi:+.1f}]  {sig}")

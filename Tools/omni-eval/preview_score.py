#!/usr/bin/env python3
"""Accuracy of live-preview candidates (hyp/<engine>.jsonl from LivePreviewEngineBenchmarkTests).
usage: preview_score.py engine [engine ...]
WER/CER with score.py's normalisation, per set (he/ru/en, cs = code-switched, noisy split by condition),
plus: wrong script (>40% of letters outside the clip's script; cs excluded), language detected right."""
import glob, json, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(here, "score.py")).read().split("refs = {}")[0])
refs = {}
for f in glob.glob(os.path.join(here, "manifests", "*.jsonl")) + glob.glob(os.path.join(here, "manifests_hard", "noisy.jsonl")):
    for l in open(f, encoding="utf-8"):
        c = json.loads(l); refs[c["id"]] = c
script = {"he": r"[֐-׿]", "ru": r"[Ѐ-ӿ]", "en": r"[A-Za-z]"}
print(f"{'engine':<14}{'set':<16}{'n':>4}{'WER%':>7}{'CER%':>7}{'RTF':>7}{'empty':>6}{'wrongScript':>12}{'langOK':>8}")
for k in sys.argv[1:]:
    rows = [json.loads(l) for l in open(os.path.join(here, "hyp", f"{k}.jsonl"), encoding="utf-8")]
    keys = []
    for r in rows:
        s = r.get("set", r["lang"]); s = f"noisy-{r.get('cond','')}" if s == "noisy" else s
        if s not in keys: keys.append(s)
    for s in keys:
        rs = [r for r in rows if (f"noisy-{r.get('cond','')}" if r.get("set") == "noisy" else r.get("set", r["lang"])) == s and r["id"] in refs]
        we = wn = ce = cn = empty = wrong = langok = langn = 0; rtf = []
        for r in rs:
            ref, hyp = norm(refs[r["id"]]["ref"]), norm(r["text"])
            we += lev(ref.split(), hyp.split()); wn += len(ref.split()); ce += lev(ref, hyp); cn += len(ref)
            empty += not hyp; rtf.append(r.get("rtf") or 0)
            if r["lang"] in script:
                letters = re.findall(r"[^\W\d_]", r["text"])
                if letters and len(re.findall(script[r["lang"]], r["text"])) / len(letters) < 0.6: wrong += 1
                if r.get("detected"): langn += 1; langok += r["detected"] == r["lang"]
        print(f"{k:<14}{s:<16}{len(rs):>4}{100*we/max(wn,1):>7.1f}{100*ce/max(cn,1):>7.1f}{sum(rtf)/max(len(rtf),1):>7.3f}{empty:>6}{wrong:>12}{(f'{langok}/{langn}' if langn else '-'):>8}")

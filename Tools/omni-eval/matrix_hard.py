#!/usr/bin/env python3
"""Tables for the hard sets. usage: matrix_hard.py noisy|meeting"""
import collections, glob, json, os, re, sys, unicodedata
here = os.path.dirname(os.path.abspath(__file__))
def norm(s):
    s = unicodedata.normalize("NFKD", s.lower()); s = "".join(c for c in s if not unicodedata.combining(c))
    s = "".join(" " if unicodedata.category(c)[0] in "PS" else c for c in s); return re.sub(r"\s+", " ", s).strip()
def ops(ref, hyp):
    """(substitutions, deletions, insertions) via full edit-distance backtrace."""
    n, m = len(ref), len(hyp); d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (ref[i-1] != hyp[j-1]))
    i, j, S, D, I = n, m, 0, 0, 0
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1] + (ref[i-1] != hyp[j-1]): S += ref[i-1] != hyp[j-1]; i -= 1; j -= 1
        elif i and d[i][j] == d[i-1][j] + 1: D += 1; i -= 1
        else: I += 1; j -= 1
    return S, D, I
def lev(a, b): s, d, i = ops(a, b); return s + d + i
LABEL = {"app-whisper-q5": "Whisper V3 Turbo Q5 (shipped)", "app-whisper-q8": "Whisper V3 Turbo Q8_0",
         "app-ivrit": "ivrit-v3-turbo", "app-qwen3": "Qwen3-ASR 1.7B 8-bit", "app-parakeet-v3": "Parakeet v3",
         "omni-7b-4": "Omni CTC 7B (not in app)"}
st = sys.argv[1]
def rows(k):
    p = os.path.join(here, "hyp", f"{k}-{st}.jsonl")
    return [json.loads(l) for l in open(p, encoding="utf-8")] if os.path.exists(p) else []
engines = [k for k in LABEL if rows(k)]

if st == "noisy":
    ref = {}
    for l in open(os.path.join(here, "manifests_hard", "noisy.jsonl"), encoding="utf-8"):
        c = json.loads(l); ref[c["id"]] = c
    clean_ref = {}
    for f in glob.glob(os.path.join(here, "manifests", "*.jsonl")):
        for l in open(f, encoding="utf-8"):
            c = json.loads(l); clean_ref[c["id"]] = c
    def wer(rs, refs):
        e = n = 0
        for r in rs:
            rw = norm(refs[r["id"]]["ref"]).split(); e += lev(rw, norm(r["text"]).split()); n += len(rw)
        return 100 * e / n if n else None
    print("NOISY DICTATION — WER%, clean -> noisy, same 30 clips per language (noisy = mean over 3 conditions, 90 decodes)")
    print(f"{'engine':<34}{'Hebrew':>16}{'Russian':>16}{'English':>16}")
    for k in engines:
        rs = rows(k); cells = []
        clean = {}
        cp = os.path.join(here, "hyp", f"{k}.jsonl")
        if os.path.exists(cp): clean = {r["id"]: r for r in map(json.loads, open(cp, encoding="utf-8"))}
        for lang in ("he", "ru", "en"):
            sub = [r for r in rs if r["lang"] == lang and r.get("ok", True)]
            if not sub: cells.append("n/a".rjust(16)); continue
            bases = sorted({r["base"] for r in sub})
            cw = wer([clean[b] for b in bases if b in clean], clean_ref) if any(b in clean for b in bases) else None
            cells.append(f"{'?' if cw is None else format(cw, '.1f')} -> {wer(sub, ref):.1f}".rjust(16))
        print(f"{LABEL[k]:<34}" + "".join(cells))
    print("\nBy condition (corpus WER% over the languages each engine ran; he+ru+en unless noted)")
    conds = ("babble10", "room_pink10", "laptop5")
    print(f"{'engine':<34}" + "".join(f"{c:>14}" for c in conds) + f"{'langs':>10}")
    for k in engines:
        rs = [r for r in rows(k) if r.get("ok", True)]
        langs = "".join(sorted({r['lang'][0] for r in rs}))
        print(f"{LABEL[k]:<34}" + "".join(f"{wer([r for r in rs if r['cond']==c], ref):>14.1f}" for c in conds) + f"{langs:>10}")
else:
    meet = json.load(open(os.path.join(here, "manifests_hard", "meetings.json"), encoding="utf-8"))
    names = list(meet)
    print("MEETINGS (~6 min each, 25 s chunks) — WER% | deletions% (dropped words) | longest repeated 4-gram run")
    print(f"{'engine':<34}" + "".join(f"{n.replace('mtg-',''):>16}" for n in names))
    for k in engines:
        rs = rows(k); cells = []
        for n in names:
            parts = sorted([r for r in rs if r.get("meeting") == n], key=lambda r: r["order"])
            if not parts: cells.append("n/a".rjust(16)); continue
            text = norm(" ".join(r["text"] for r in parts)).split(); rw = norm(meet[n]["ref"]).split()
            S, D, I = ops(rw, text)
            g = [tuple(text[i:i+4]) for i in range(len(text) - 3)]; run = best = 1
            for a, b in zip(g, g[1:]):
                run = run + 1 if a == b else 1; best = max(best, run)
            cells.append(f"{100*(S+D+I)/len(rw):.1f}|{100*D/len(rw):.0f}|{best}".rjust(16))
        print(f"{LABEL[k]:<34}" + "".join(cells))
    print("\nTime per engine (mean RTF over chunks):", {LABEL[k]: round(sum(r['rtf'] for r in rows(k) if r.get('rtf'))/max(1, len([r for r in rows(k) if r.get('rtf')])), 3) for k in engines})

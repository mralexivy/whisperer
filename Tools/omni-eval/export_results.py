#!/usr/bin/env python3
"""All benchmark runs -> one long-format results file for the results page.
usage: export_results.py [out.json]   (default results/benchmark.json)
Rows: {engine, label, in_app, test, lang, cond, wer, median_wer, wrong_script, deletions,
       max_repeat, rtf, punct, n}. test: clean (FLEURS 100/lang) | noisy (30/lang x 3 conditions,
       cond per row plus cond="all") | meeting (per meeting, plus lang aggregate with cond="all")."""
import glob, json, os, re, statistics, sys, unicodedata
here = os.path.dirname(os.path.abspath(__file__))
def norm(s):
    s = unicodedata.normalize("NFKD", s.lower()); s = "".join(c for c in s if not unicodedata.combining(c))
    s = "".join(" " if unicodedata.category(c)[0] in "PS" else c for c in s); return re.sub(r"\s+", " ", s).strip()
def ops(ref, hyp):
    n, m = len(ref), len(hyp); d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        ri = ref[i-1]; di = d[i]; dp = d[i-1]
        for j in range(1, m + 1):
            di[j] = min(dp[j] + 1, di[j-1] + 1, dp[j-1] + (ri != hyp[j-1]))
    i, j, S, D, I = n, m, 0, 0, 0
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1] + (ref[i-1] != hyp[j-1]): S += ref[i-1] != hyp[j-1]; i -= 1; j -= 1
        elif i and d[i][j] == d[i-1][j] + 1: D += 1; i -= 1
        else: I += 1; j -= 1
    return S, D, I
SCRIPT = {"he": r"[֐-׿]", "ru": r"[Ѐ-ӿ]", "en": r"[A-Za-z]"}
def wrong_script(text, lang):
    letters = [c for c in text if c.isalpha()]
    return not letters or sum(bool(re.match(SCRIPT[lang], c)) for c in letters) / len(letters) < 0.5
def max_repeat(words):
    g = [tuple(words[i:i+4]) for i in range(len(words) - 3)]; run = best = 1 if g else 0
    for a, b in zip(g, g[1:]):
        run = run + 1 if a == b else 1; best = max(best, run)
    return best
ENGINES = [  # key, label, in_app
    ("app-whisper-q5", "Whisper V3 Turbo Q5", True), ("app-whisper-q8", "Whisper V3 Turbo Q8_0", False),
    ("app-ivrit", "ivrit-v3-turbo (Hebrew)", True), ("app-qwen3", "Qwen3-ASR 1.7B", True),
    ("app-parakeet-v3", "Parakeet v3", True), ("omni-7b-4", "Omni CTC 7B", False)]
def load(path):
    return [json.loads(l) for l in open(path, encoding="utf-8")] if os.path.exists(path) else []
clean_ref = {}
for f in glob.glob(os.path.join(here, "manifests", "*.jsonl")):
    for c in load(f): clean_ref[c["id"]] = c
noisy_ref = {c["id"]: c for c in load(os.path.join(here, "manifests_hard", "noisy.jsonl"))}
meetings = json.load(open(os.path.join(here, "manifests_hard", "meetings.json"), encoding="utf-8"))

def score(rows, refs, lang):
    e = n = D = 0; per = []; ws = 0; rtfs = []; punct = 0
    for r in rows:
        rw, hw = norm(refs[r["id"]]["ref"]).split(), norm(r["text"]).split()
        s_, d_, i_ = ops(rw, hw); e += s_ + d_ + i_; D += d_; n += len(rw)
        per.append((s_ + d_ + i_) / max(len(rw), 1)); ws += wrong_script(r["text"], lang)
        if r.get("rtf") is not None: rtfs.append(r["rtf"])
        punct += bool(re.search(r"[.,?!;:]", r["text"]))
    return dict(wer=round(100 * e / n, 1), median_wer=round(100 * statistics.median(per), 1),
                wrong_script=round(100 * ws / len(rows)), deletions=round(100 * D / n, 1), max_repeat=None,
                rtf=round(statistics.mean(rtfs), 3) if rtfs else None, punct=round(100 * punct / len(rows)), n=len(rows))

out = []
for key, label, in_app in ENGINES:
    base = dict(engine=key, label=label, in_app=in_app)
    clean = [r for r in load(os.path.join(here, "hyp", key + ".jsonl")) if r.get("ok", True)]
    for lang in ("he", "ru", "en"):
        rs = [r for r in clean if r["lang"] == lang]
        if rs: out.append({**base, "test": "clean", "lang": lang, "cond": "all", **score(rs, clean_ref, lang)})
    noisy = [r for r in load(os.path.join(here, "hyp", key + "-noisy.jsonl")) if r.get("ok", True)]
    for lang in ("he", "ru", "en"):
        rs = [r for r in noisy if r["lang"] == lang]
        if not rs: continue
        out.append({**base, "test": "noisy", "lang": lang, "cond": "all", **score(rs, noisy_ref, lang)})
        for cond in ("babble10", "room_pink10", "laptop5"):
            sub = [r for r in rs if r["cond"] == cond]
            if sub: out.append({**base, "test": "noisy", "lang": lang, "cond": cond, **score(sub, noisy_ref, lang)})
    mrows = load(os.path.join(here, "hyp", key + "-meeting.jsonl"))
    agg = {}
    for name, m in meetings.items():
        parts = sorted([r for r in mrows if r.get("meeting") == name], key=lambda r: r["order"])
        if not parts: continue
        text = norm(" ".join(r["text"] for r in parts)).split(); rw = norm(m["ref"]).split()
        S, D, I = ops(rw, text)
        rtfs = [r["rtf"] for r in parts if r.get("rtf") is not None]
        row = dict(test="meeting", lang=m["lang"], cond=name, wer=round(100 * (S + D + I) / len(rw), 1), median_wer=None,
                   wrong_script=None, deletions=round(100 * D / len(rw), 1), max_repeat=max_repeat(text),
                   rtf=round(statistics.mean(rtfs), 3) if rtfs else None,
                   punct=None, n=len(parts))
        out.append({**base, **row})
        a = agg.setdefault(m["lang"], [0, 0, 0, 0, []]); a[0] += S + D + I; a[1] += D; a[2] += len(rw); a[3] = max(a[3], row["max_repeat"]); a[4] += rtfs
    for lang, (e, D, n, rep, rtfs) in agg.items():
        out.append({**base, "test": "meeting", "lang": lang, "cond": "all", "wer": round(100 * e / n, 1), "median_wer": None,
                    "wrong_script": None, "deletions": round(100 * D / n, 1), "max_repeat": rep,
                    "rtf": round(statistics.mean(rtfs), 3) if rtfs else None, "punct": None, "n": n})
dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "results", "benchmark.json")
json.dump(out, open(dest, "w", encoding="utf-8"), ensure_ascii=False, indent=0)
print(len(out), "rows ->", dest)

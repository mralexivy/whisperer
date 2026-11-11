#!/usr/bin/env python3
"""Transcription metrics that matter for a live meeting preview, beyond WER.
usage: preview_metrics.py engine [engine ...]       (hyp/<engine>.jsonl from LivePreviewEngineBenchmarkTests)

CER        character error rate — the fair primary for Hebrew/Russian, where one wrong prefix letter
           (ו, ה, ב) or case ending fails a whole word under WER
WER        word error rate, for comparison with earlier benchmarks
Meaning    recall of reference words weighted by rarity (IDF over the language's whole FLEURS test
           set): keeping "Mendoza", "lavatory" counts, keeping "the" barely does
Names      recall of proper nouns (en/ru: capitalised words not starting a sentence; he/ru: Latin words)
Ins/100    words the engine invented, per 100 reference words (hallucination pressure)
Comma F1 / End F1   punctuation against the human transcript, at aligned word positions:
           commas, and sentence ends inside the clip (what paragraphs need); Closes = clip ends
           with . ? or !
Noisy and code-switched sets have no punctuated reference, so their punctuation columns are blank."""
import glob, json, math, os, re, sys, collections
here = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(here, "score.py")).read().split("def lev")[0])          # norm
man = {}
for f in glob.glob(os.path.join(here, "manifests", "*.jsonl")) + [os.path.join(here, "manifests_hard", "noisy.jsonl")]:
    for l in open(f, encoding="utf-8"):
        c = json.loads(l); man[c["id"]] = c
raw_by_base = {k: v.get("ref_raw") for k, v in man.items() if v.get("ref_raw")}
# IDF per language from the full FLEURS test transcripts
idf = {}
for lang, d in (("en", "en_us"), ("he", "he_il"), ("ru", "ru_ru")):
    df = collections.Counter(); n = 0
    for line in open(os.path.join(here, f"corpus/fleurs/{d}/test.tsv"), encoding="utf-8"):
        cols = line.split("\t")
        if len(cols) > 3: n += 1; df.update(set(norm(cols[2]).split()))
    idf[lang] = (df, n)
def w_idf(lang, w):
    df, n = idf.get(lang, (collections.Counter(), 1)); return math.log((n + 1) / (df.get(w, 0) + 1)) + 1

def align(a, b):
    """Levenshtein alignment of word lists → list of (i or None, j or None)."""
    n, m = len(a), len(b)
    D = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): D[i][0] = i
    for j in range(m + 1): D[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            D[i][j] = min(D[i-1][j] + 1, D[i][j-1] + 1, D[i-1][j-1] + (a[i-1] != b[j-1]))
    out = []; i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and D[i][j] == D[i-1][j-1] + (a[i-1] != b[j-1]): out.append((i-1, j-1)); i -= 1; j -= 1
        elif i > 0 and D[i][j] == D[i-1][j] + 1: out.append((i-1, None)); i -= 1
        else: out.append((None, j-1)); j -= 1
    return out[::-1], D[n][m]
def lev_chars(a, b): return align(list(a), list(b))[1]

def tokens_with_punct(raw):
    """[(normalized word, punct mark after it)] for a raw punctuated string."""
    out = []
    for t in raw.split():
        w = norm(t)
        if not w: 
            if out and re.search(r"[.?!,]", t): out[-1] = (out[-1][0], "." if re.search(r"[.?!]", t) else ",")
            continue
        p = "." if re.search(r"[.?!]['\"”»)]*$", t) else ("," if re.search(r"[,;:]['\"”»)]*$", t) else "")
        for k, sub in enumerate(w.split()): out.append((sub, p if k == len(w.split()) - 1 else ""))
    return out

def f1(tp, fp, fn):
    p = tp / (tp + fp) if tp + fp else 0; r = tp / (tp + fn) if tp + fn else 0
    return (2 * p * r / (p + r) if p + r else 0), tp + fn

hdr = f"{'engine':<14}{'set':<16}{'n':>4}{'CER%':>7}{'WER%':>7}{'Meaning%':>9}{'Names%':>8}{'Ins/100':>8}{'CommaF1':>8}{'EndF1':>7}{'Closes%':>8}"
print(__doc__.split("\n\n")[0]); print(hdr)
for k in sys.argv[1:]:
    rows = [json.loads(l) for l in open(os.path.join(here, "hyp", f"{k}.jsonl"), encoding="utf-8")]
    groups = collections.OrderedDict()
    for r in rows:
        s = f"noisy-{r.get('cond','')}" if r.get("set") == "noisy" else r.get("set", r["lang"])
        groups.setdefault(s, []).append(r)
    for s, rs in groups.items():
        ce = cn = we = wn = ins = 0; mi = mt = 0.0; nh = nt = 0
        ctp = cfp = cfn = etp = efp = efn = 0; closes = closable = 0
        for r in rs:
            m = man.get(r["id"]); 
            if not m: continue
            lang = r["lang"] if r["lang"] in idf else "en"
            ref = norm(m["ref"]).split(); hypraw = r["text"]; hyp = norm(hypraw).split()
            pairs, dist = align(ref, hyp)
            we += dist; wn += len(ref); ce += lev_chars(" ".join(ref), " ".join(hyp)); cn += len(" ".join(ref))
            ins += sum(1 for i, j in pairs if i is None)
            for i, j in pairs:
                if i is None: continue
                w = w_idf(lang, ref[i]); mt += w
                if j is not None and hyp[j] == ref[i]: mi += w
            raw = m.get("ref_raw")
            if raw:
                rt = tokens_with_punct(raw)
                names = {n for n, (w, _) in enumerate(rt) if False}
                rawtoks = raw.split()
                # names: capitalised (en/ru) not sentence-initial, or Latin inside he/ru
                cap_idx = set(); prev_end = True; idx = 0
                for t in rawtoks:
                    w = norm(t).split()
                    if not w: continue
                    if (lang in ("en", "ru") and t[:1].isupper() and not prev_end) or (lang in ("he", "ru") and re.search(r"[A-Za-z]", t)):
                        cap_idx.update(range(idx, idx + len(w)))
                    idx += len(w); prev_end = bool(re.search(r"[.?!]['\"”»)]*$", t))
                ht = tokens_with_punct(hypraw)
                pp, _ = align([w for w, _ in rt], [w for w, _ in ht])
                for i, j in pp:
                    if i is None: continue
                    if i in cap_idx:
                        nt += 1; nh += j is not None and ht[j][0] == rt[i][0]
                    last = i == len(rt) - 1
                    rp = rt[i][1]; hp = ht[j][1] if j is not None else ""
                    if last: continue
                    if rp == ",": ctp += hp == ","; cfn += hp != ","
                    elif hp == ",": cfp += 1
                    if rp == ".": etp += hp == "."; efn += hp != "."
                    elif hp == ".": efp += 1
                closable += 1; closes += bool(re.search(r"[.?!]['\"”»)]*\s*$", hypraw.strip()))
        cf, csup = f1(ctp, cfp, cfn); ef, esup = f1(etp, efp, efn)
        pun = closable > 0
        print(f"{k:<14}{s:<16}{len(rs):>4}{100*ce/max(cn,1):>7.1f}{100*we/max(wn,1):>7.1f}{100*mi/max(mt,1):>9.1f}"
              f"{(f'{100*nh/nt:.0f}' if nt else '-'):>8}{100*ins/max(wn,1):>8.1f}"
              f"{(f'{100*cf:.0f}' if pun and csup else '-'):>8}{(f'{100*ef:.0f}' if pun and esup else '-'):>7}{(f'{100*closes/closable:.0f}' if pun else '-'):>8}")

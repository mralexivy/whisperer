#!/usr/bin/env python3
"""Contention and edge-case tables for LivePreviewEngineBenchmarkTests.
usage: preview_bench_report.py   (reads results/load-*.jsonl, results/energy-*.jsonl, results/edge-*.jsonl)"""
import glob, json, os, re, statistics as st
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "score.py")).read().split("refs = {}")[0])  # norm, lev
def pct(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(round(p * (len(v) - 1))))] if v else float("nan")
print("## Main engine (whisper.cpp V3, 15 s clip) decode time while a preview streams")
print(f"{'preview running':<22}{'n':>4}{'p50 s':>8}{'p95 s':>8}{'vs alone':>10}")
alone = [json.loads(l)["decode_s"] for l in open("results/load-alone.jsonl")] if os.path.exists("results/load-alone.jsonl") else []
base = st.median(alone) if alone else None
for f in sorted(glob.glob("results/load-*.jsonl")):
    rows = [json.loads(l)["decode_s"] for l in open(f)]
    if not rows: continue
    name = os.path.basename(f)[5:-6]
    rel = f"{100 * (st.median(rows) / base - 1):+.0f}%" if base and name != "alone" else ""
    print(f"{name:<22}{len(rows):>4}{st.median(rows):>8.2f}{pct(rows, .95):>8.2f}{rel:>10}")
print("\n## Energy over each real-time run (Whisperer process; Apple's recognizer runs out of process)")
for f in sorted(glob.glob("results/energy-*.jsonl")):
    for l in open(f):
        r = json.loads(l)
        print(f"{r['engine']:<14}{r['tag']:<8} {r['wall']:6.0f}s wall  {r['joules']/r['wall']:5.2f} W  GPU {r['gpu_s']:5.1f}s  speech-service CPU total {r['speechd_cpu_s']:.0f}s")
print("\n## Edge cases")
script = {"he": r"[֐-׿]", "ru": r"[Ѐ-ӿ]", "en": r"[A-Za-z]"}
for f in sorted(glob.glob("results/edge-*.jsonl")):
    rows = [json.loads(l) for l in open(f)]
    eng = os.path.basename(f)[5:-6]
    by = {}
    for r in rows: by.setdefault(r["kind"], []).append(r)
    for kind, rs in by.items():
        if kind == "silence":
            words = [len(norm(r["final_text"]).split()) for r in rs]
            print(f"{eng:<14}{kind:<14} hallucinated words per clip: {words}")
        elif kind == "switching":
            for r in rs:
                ev = r["events"]; secs = r["seconds"]
                gaps = []; last = 0; lastn = 0
                for e in ev:
                    n = len(norm(e["text"]).split())
                    if n > lastn: gaps.append(e["wall"] - last); last = e["wall"]; lastn = n
                print(f"{eng:<14}{kind:<14} {secs:.0f}s audio  {len(norm(r['final_text']).split())} words  longest wait for new words {max(gaps) if gaps else float('nan'):.1f}s  final+{r['final_wall']-secs:.1f}s")
        else:
            we = wn = 0; right = 0; empty = 0; first = []
            for r in rs:
                ref, hyp = norm(r["ref"]).split(), norm(r["final_text"]).split()
                we += lev(ref, hyp); wn += max(len(ref), 1)
                if not hyp: empty += 1
                letters = re.findall(r"\w", r["final_text"])
                if letters and len(re.findall(script[r["lang"]], r["final_text"])) / len(letters) > 0.6: right += 1
                fp = next((e["wall"] for e in r["events"] if norm(e["text"])), None)
                if fp is not None: first.append(fp)
            print(f"{eng:<14}{kind:<14} n={len(rs):<3} WER {100*we/wn:5.1f}%  right script {right}/{len(rs)}  empty {empty}  first text {st.median(first) if first else float('nan'):.2f}s")

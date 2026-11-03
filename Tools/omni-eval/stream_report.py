#!/usr/bin/env python3
"""Aggregate results/stream-<engine>-<tag>.jsonl. usage: stream_report.py <tag> <engine> [engine ...]"""
import json, sys, statistics as st, collections
tag = sys.argv[1]
def pct(v, p): v = sorted(v); return v[min(len(v) - 1, int(round(p * (len(v) - 1))))] if v else float("nan")
print(f"{'engine':<16}{'lang':<5}{'n':>3}{'1stPartial':>11}{'1stCorrect':>11}{'1stCommit':>10}{'flicker%':>9}{'finalWER':>9}{'commWER':>8}{'compute p50/p95 s':>19}")
for k in sys.argv[2:]:
    rows = [json.loads(l) for l in open(f"results/stream-{k}-{tag}.jsonl")]
    for lang in ("he", "ru", "en", "all"):
        rs = [r for r in rows if lang == "all" or r["lang"] == lang]
        if not rs: continue
        f = lambda key: [r[key] for r in rs if r[key] is not None]
        comp = [c for r in rs for c in r["comp"] if c is not None]
        fmt = lambda v: f"{st.mean(v):.1f}" if v else "-"
        print(f"{k:<16}{lang:<5}{len(rs):>3}{fmt(f('first_partial_s')):>11}{fmt(f('first_correct_s')):>11}{fmt(f('first_commit_s')):>10}"
              f"{100*st.mean(f('flicker')) if f('flicker') else float('nan'):>9.1f}{100*st.mean(f('final_wer')):>9.1f}{100*st.mean(f('committed_wer')):>8.1f}"
              f"{pct(comp,.5):>10.2f}/{pct(comp,.95):<8.2f}")

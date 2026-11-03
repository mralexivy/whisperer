#!/usr/bin/env python3
"""Metrics from the in-process real-time harness (results/rt-<engine>-<tag>.jsonl, written by streambench).
usage: stream_events_report.py <tag> <engine> [engine ...]

Every event is a text update with the wall-clock second (since the clip started playing at 1x) it appeared.
  first partial     wall time of the first non-empty update
  first correct     wall time of the first update whose first word equals the reference's first word
  first committed   wall time of the first word held by two consecutive updates (LocalAgreement-2); for the native
                    streaming engine this is reported too, so all engines share one rule
  lag               wall time an update appeared minus the audio second it covers (how far behind the speaker)
  finalization      wall time the final text is available minus the end of the clip
  flicker           share of words, excluding the last two of the previous update, that change in the next update
  compute           model time per update (p50/p95)"""
import json, sys, statistics as st
exec(open(__file__.replace("stream_events_report.py", "score.py")).read().split("refs = {}")[0])  # norm, lev
tag = sys.argv[1]
def pct(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(round(p * (len(v) - 1))))] if v else float("nan")
def metrics(r):
    ref = norm(r["ref"]).split(); ev = r["events"]; w = [norm(e["text"]).split() for e in ev]
    fp = next((e["wall"] for e, x in zip(ev, w) if x), None)
    fc = next((e["wall"] for e, x in zip(ev, w) if x and ref and x[0] == ref[0]), None)
    committed, fcom = [], None
    for i in range(1, len(ev)):
        n = 0
        while n < min(len(w[i - 1]), len(w[i])) and w[i - 1][n] == w[i][n]: n += 1
        if n > len(committed):
            committed = w[i][:n]
            if fcom is None: fcom = ev[i]["wall"]
    ch = tot = 0
    for i in range(1, len(ev)):
        s = w[i - 1][:-2]; tot += len(s); ch += sum(1 for j, x in enumerate(s) if j >= len(w[i]) or w[i][j] != x)
    final = norm(r["final_text"]).split()
    lags = [e["wall"] - e["covered"] for e in ev if e["text"].strip()]
    return {"fp": fp, "fc": fc, "fcom": fcom, "flick": ch / tot if tot else None, "wer": lev(ref, final) / max(len(ref), 1),
            "cwer": lev(ref, committed) / max(len(ref), 1), "fin": r["final_wall"] - r["clip_end_wall"], "lag": lags,
            "comp": [e["compute"] for e in ev], "n": len(ev)}
print(f"{'engine':<10}{'lang':<5}{'n':>3}{'1stPart':>8}{'1stCorr':>8}{'1stComm':>8}{'lag s':>7}{'final+s':>8}{'flick%':>7}{'WER':>6}{'commWER':>8}{'upd/clip':>9}{'compute p50/p95':>17}")
for k in sys.argv[2:]:
    rows = [json.loads(l) for l in open(f"results/rt-{k}-{tag}.jsonl")]
    for lang in ("he", "ru", "en", "all"):
        rs = [metrics(r) for r in rows if lang == "all" or r["lang"] == lang]
        if not rs: continue
        m = lambda key: [x[key] for x in rs if x[key] is not None]
        f = lambda v: f"{st.mean(v):.2f}" if v else "-"
        lag = [x for r in rs for x in r["lag"]]; comp = [x for r in rs for x in r["comp"]]
        print(f"{k:<10}{lang:<5}{len(rs):>3}{f(m('fp')):>8}{f(m('fc')):>8}{f(m('fcom')):>8}{(st.median(lag) if lag else float('nan')):>7.2f}"
              f"{f(m('fin')):>8}{100*st.mean(m('flick')) if m('flick') else float('nan'):>7.1f}{100*st.mean(m('wer')):>6.1f}{100*st.mean(m('cwer')):>8.1f}"
              f"{st.mean(m('n')):>9.1f}{pct(comp,.5):>10.3f}/{pct(comp,.95):<6.3f}")

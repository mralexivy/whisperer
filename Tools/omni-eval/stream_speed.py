#!/usr/bin/env python3
"""Streaming speed as a dictating user feels it, from results/rt-<engine>-<tag>.jsonl.
behind     seconds the text on screen trails the speaker: at each update, wall time minus the moment the
           speaker had said that many words (even pace over the clip's speech); median over updates
behind p90 the same, 90th percentile (the bad moments)
gap        median seconds between updates that add words while the clip plays; max = longest freeze
words/upd  median words added per update (1 = word by word, 5+ = bursts)
first      wall time of the first word on screen
done       seconds after the speaker stops until the final text
usage: stream_speed.py engine:tag [engine:tag ...]"""
import json, sys, statistics as st
exec(open(__file__.replace("stream_speed.py", "score.py")).read().split("refs = {}")[0])
def pct(v, p):
    v = sorted(v); return v[min(len(v)-1, int(p*(len(v)-1)))] if v else float("nan")
print(f"{'engine':<22}{'behind':>8}{'p90':>7}{'gap':>7}{'max gap':>9}{'words/upd':>10}{'first':>7}{'done':>7}")
for spec in sys.argv[1:]:
    eng, tag = spec.split(":")
    rows = [json.loads(l) for l in open(f"results/rt-{eng}-{tag}.jsonl")]
    behind, gaps, maxgaps, adds, firsts, dones = [], [], [], [], [], []
    for r in rows:
        ref = len(norm(r["ref"]).split()); secs = r["seconds"]
        # speech occupies the clip minus ~0.4 s of edge silence on each side (FLEURS)
        s0, s1 = 0.4, max(0.8, secs - 0.4)
        last_n, last_t, mg = 0, None, 0
        for e in r["events"]:
            n = len(norm(e["text"]).split())
            if n <= last_n or e["wall"] > secs: 
                last_n = max(last_n, n); continue
            said_at = s0 + (s1 - s0) * min(1, n / max(ref, 1))
            behind.append(e["wall"] - said_at)
            if last_t is not None: gaps.append(e["wall"] - last_t); mg = max(mg, e["wall"] - last_t)
            adds.append(n - last_n); last_n, last_t = n, e["wall"]
            if len(firsts) < rows.index(r) + 1: firsts.append(e["wall"])
        maxgaps.append(mg); dones.append(r["final_wall"] - secs)
    print(f"{eng:<22}{st.median(behind):>8.2f}{pct(behind,.9):>7.2f}{st.median(gaps) if gaps else float('nan'):>7.2f}"
          f"{st.median(maxgaps):>9.2f}{st.median(adds):>10.0f}{st.median(firsts):>7.2f}{st.median(dones):>7.2f}")

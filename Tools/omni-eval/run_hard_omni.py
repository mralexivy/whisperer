#!/usr/bin/env python3
"""Omni (not in the app) over the hard sets via the `speech` CLI, same chunks/clips as the app engines.
usage: run_hard_omni.py <engine-key e.g. omni-7b-4> <noisy|meeting>   -> hyp/<key>-<set>.jsonl (resumable)"""
import json, os, re, subprocess, sys, time
sys.argv, args = sys.argv[:1], sys.argv[1:]
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "run_engine.py")).read().split("key = sys.argv[1]")[0])
key, st = args
man = os.path.join(here, "manifests_hard", "noisy.jsonl" if st == "noisy" else "meeting_chunks.jsonl")
out = os.path.join(here, "hyp", f"{key}-{st}.jsonl")
done = {json.loads(l)["id"] for l in open(out, encoding="utf-8")} if os.path.exists(out) else set()
with open(out, "a", encoding="utf-8") as fo:
    for line in open(man, encoding="utf-8"):
        c = json.loads(line)
        if c["id"] in done: continue
        t0 = time.time()
        p = subprocess.run(["speech", "transcribe", c["audio"]] + ENGINES[key], capture_output=True, text=True)
        txt = p.stdout + p.stderr
        m = re.search(r"Result: (.*?)\n\s*Time: ([\d.]+)s, RTF: ([\d.]+)", txt, re.S)
        rec = {"id": c["id"], "lang": c["lang"], "engine": key, "ok": bool(m) and p.returncode == 0,
               "text": m.group(1).strip() if m else "", "rtf": float(m.group(3)) if m else None,
               "wall": round(time.time() - t0, 2), "seconds": c["seconds"]}
        for k in ("cond", "meeting", "order", "base"):
            if k in c: rec[k] = c[k]
        if not m: rec["err"] = txt[-300:]
        fo.write(json.dumps(rec, ensure_ascii=False) + "\n"); fo.flush()
print("done", key, st)

#!/usr/bin/env python3
"""Run one engine over manifests, writing hyp/<engine>.jsonl. Resumable (skips done ids).
usage: run_engine.py <engine-key> [lang ...]"""
import json, os, re, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
ENGINES = {
  "omni-300m-4": ["--engine","omnilingual","--backend","mlx","--variant","300M","--bits","4"],
  "omni-1b-4":   ["--engine","omnilingual","--backend","mlx","--variant","1B","--bits","4"],
  "omni-1b-8":   ["--engine","omnilingual","--backend","mlx","--variant","1B","--bits","8"],
  "omni-3b-4":   ["--engine","omnilingual","--backend","mlx","--variant","3B","--bits","4"],
  "omni-3b-8":   ["--engine","omnilingual","--backend","mlx","--variant","3B","--bits","8"],
  "omni-7b-4":   ["--engine","omnilingual","--backend","mlx","--variant","7B","--bits","4"],
  "qwen3-1.7b":  ["--engine","qwen3","-m","1.7B"],
  "whisper-turbo": ["--engine","whisper","-m","turbo"],
  "omni300-cml-10": ["--engine","omnilingual","--backend","coreml","--window","10"],
  "omni300-cml-5":  ["--engine","omnilingual","--backend","coreml","--window","5"],
  "parakeet":    ["--engine","parakeet"],
}
key = sys.argv[1]; langs = sys.argv[2:] or ["he","ru","en"]
out = os.path.join(here, "hyp", f"{key}.jsonl")
done = set()
if os.path.exists(out):
    done = {json.loads(l)["id"] for l in open(out, encoding="utf-8")}
with open(out, "a", encoding="utf-8") as fo:
    for lang in langs:
        for line in open(os.path.join(here, "manifests", f"{lang}.jsonl"), encoding="utf-8"):
            c = json.loads(line)
            if c["id"] in done: continue
            t0 = time.time()
            p = subprocess.run(["speech","transcribe",c["audio"]] + ENGINES[key],
                               capture_output=True, text=True)
            wall = time.time() - t0
            txt = p.stdout + p.stderr
            m = re.search(r"Result: (.*?)\n\s*Time: ([\d.]+)s, RTF: ([\d.]+)", txt, re.S)
            rec = {"id": c["id"], "lang": lang, "engine": key, "ok": bool(m) and p.returncode == 0,
                   "text": m.group(1).strip() if m else "", "rtf": float(m.group(3)) if m else None,
                   "wall": round(wall, 2), "seconds": c["seconds"]}
            if not m: rec["err"] = txt[-300:]
            fo.write(json.dumps(rec, ensure_ascii=False) + "\n"); fo.flush()
print("done", key)

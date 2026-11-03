#!/usr/bin/env python3
"""Final-ASR load generator: transcribe the 30 s English clip with Qwen3-1.7B 8-bit back-to-back, logging model time.
usage: qwen_loop.py <tag> [--n N | --until-file path]   -> results/qwen-loop-<tag>.jsonl"""
import json, re, subprocess, sys, os, time
here = os.path.dirname(os.path.abspath(__file__))
tag = sys.argv[1]; n = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--n" else None
stop = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--until-file" else None
wav = f"{here}/corpus/dur/en-30s.wav"; i = 0
with open(f"{here}/results/qwen-loop-{tag}.jsonl", "a") as fo:
    while True:
        if n is not None and i >= n: break
        if stop and os.path.exists(stop): break
        t0 = time.time()
        p = subprocess.run(["speech", "transcribe", wav, "--engine", "qwen3", "-m", "1.7B"], capture_output=True, text=True)
        m = re.search(r"Time: ([\d.]+)s, RTF: ([\d.]+)", p.stdout + p.stderr)
        fo.write(json.dumps({"i": i, "t": round(time.time(), 2), "model_s": float(m.group(1)) if m else None, "wall_s": round(time.time() - t0, 2)}) + "\n"); fo.flush(); i += 1

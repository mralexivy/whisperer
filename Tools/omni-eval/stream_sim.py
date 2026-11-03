#!/usr/bin/env python3
"""Simulate eager streaming: re-decode growing prefixes of a clip every STEP s.
Reports per-pass decode time (model-only, from CLI 'Time:'), first-useful-partial latency,
and flicker = share of words, excluding the last 2 of the previous pass, that change next pass.
usage: stream_sim.py <engine-key> <lang> [n_clips] [step_s]"""
import json, os, re, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
sys.argv_backup = sys.argv
key, lang = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 5
step = float(sys.argv[4]) if len(sys.argv) > 4 else 1.5
exec(open(os.path.join(here, "run_engine.py")).read().split("key = sys.argv[1]")[0])  # ENGINES dict
clips = [json.loads(l) for l in open(f"{here}/manifests/{lang}.jsonl", encoding="utf-8")]
clips = [c for c in clips if 8 <= c["seconds"] <= 14][:n]
tmp = tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/tmp"))
times, flick_changed, flick_total, first = [], 0, 0, []
for c in clips:
    prev, t, final_words = [], step, None
    while True:
        end = min(t, c["seconds"])
        wav = f"{tmp}/p.wav"
        subprocess.run(["ffmpeg","-y","-v","error","-i",c["audio"],"-t",str(end),wav], check=True)
        p = subprocess.run(["speech","transcribe",wav]+ENGINES[key], capture_output=True, text=True)
        m = re.search(r"Result: (.*?)\n\s*Time: ([\d.]+)s", p.stdout + p.stderr, re.S)
        words = m.group(1).split() if m else []
        if m: times.append(float(m.group(2)))
        stable = prev[:-2]
        flick_total += len(stable); flick_changed += sum(1 for i, w in enumerate(stable) if i >= len(words) or words[i] != w)
        if words and not first: pass
        if words and (len(first) < clips.index(c) + 1): first.append(end)
        prev = words
        if end >= c["seconds"]: break
        t += step
print(f"{key} {lang}: clips={len(clips)} passes={len(times)} mean decode={1000*sum(times)/len(times):.0f} ms "
      f"max={1000*max(times):.0f} ms  first-partial at ~{sum(first)/len(first):.1f}s of audio  "
      f"flicker={100*flick_changed/max(flick_total,1):.1f}% of stable words changed")

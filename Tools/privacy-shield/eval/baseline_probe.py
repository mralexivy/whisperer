#!/usr/bin/env python3
"""Quick probe: how much do simple causal maskers hurt Whisper at a given loudness?
usage: baseline_probe.py CORPUS --work DIR --whisper-cli P --model P [--snr 5] [--kinds noise,selfbabble]"""
import argparse, json, re, subprocess, sys
from pathlib import Path
import numpy as np, soundfile as sf
sys.path.insert(0, str(Path(__file__).resolve().parent)); sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from run_eval import transcribe, to_16k  # noqa

def wer(r, h):
    r = re.sub(r"[^\w' ]", "", r.lower()).split(); h = re.sub(r"[^\w' ]", "", h.lower()).split()
    d = list(range(len(h) + 1))
    for i, a in enumerate(r, 1):
        p = d[:]; d[0] = i
        for j, b in enumerate(h, 1): d[j] = min(p[j] + 1, d[j - 1] + 1, p[j - 1] + (a != b))
    return d[-1] / max(1, len(r))

def envelope_rms(x, win=400):
    k = np.ones(win) / win
    return np.sqrt(np.convolve(x * x, k)[: len(x)] + 1e-10)   # causal: past window only

def masker(x, kind, rng):
    if kind == "noise":
        m = rng.standard_normal(len(x))
    elif kind == "selfbabble":   # sum of the speaker's own past speech at 150-700 ms delays
        m = np.zeros_like(x)
        for d in (2400, 4300, 6100, 8700, 11200):
            m[d:] += x[:-d]
    elif kind == "selfbabble-rev":   # own past speech, time-reversed in 400 ms blocks (unintelligible)
        m = np.zeros_like(x); B = 6400
        for s in range(B, len(x), B):
            seg = x[s - B: s][::-1]; m[s: s + B] += seg[: len(m[s: s + B])]
    m = m / (envelope_rms(m) + 1e-6)          # unit local loudness
    return m * envelope_rms(x)                # follows the voice, like the shield's bound

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("corpus"); ap.add_argument("--work", required=True)
    ap.add_argument("--whisper-cli", required=True); ap.add_argument("--model", required=True)
    ap.add_argument("--snr", default="5"); ap.add_argument("--kinds", default="noise,selfbabble,selfbabble-rev")
    a = ap.parse_args(); work = Path(a.work); work.mkdir(parents=True, exist_ok=True); rng = np.random.default_rng(0)
    rows = [json.loads(l) for l in (Path(a.corpus) / "corpus.jsonl").read_text().splitlines() if l.strip()]
    clean = {}
    for r in rows:
        w = work / f"{r['id']}.clean16.wav"; to_16k(Path(a.corpus) / r["clean_audio"], w)
        clean[r["id"]] = transcribe(a.whisper_cli, a.model, w)
    for snr in [float(s) for s in a.snr.split(",")]:
        g = 10 ** (-snr / 20)
        for kind in a.kinds.split(","):
            ws = []
            for r in rows:
                x, sr = sf.read(work / f"{r['id']}.clean16.wav", dtype="float32")
                y = np.clip(x + g * masker(x, kind, rng), -1, 1)
                p = work / f"{r['id']}.{kind}.{snr:g}.wav"; sf.write(p, y, sr)
                ws.append(wer(clean[r["id"]], transcribe(a.whisper_cli, a.model, p)))
            print(json.dumps({"kind": kind, "snr_db": snr, "wer_vs_clean": round(float(np.mean(ws)), 3)}), flush=True)

if __name__ == "__main__":
    main()

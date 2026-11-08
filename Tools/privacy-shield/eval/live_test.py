#!/usr/bin/env python3
"""Live, in-app Privacy Shield test through the real virtual microphone.

Preconditions: Whisperer (direct build) is running with Privacy Shield ON, and the shield reports a
ready route. This script plays each corpus clip through the Mac's speakers and records, at the same
time, the physical microphone (what you said) and "Whisperer Virtual Mic" (what a call app receives).
Both recordings then go through the same conferencing proxy (Opus + RNNoise) and whisper.cpp, and the
report shows how far the virtual-mic transcript drifts from the physical-mic transcript.

usage: live_test.py CORPUS_DIR --work DIR --whisper-cli PATH --model PATH --rnnoise MODEL
       [--physical "MacBook Pro Microphone"] [--virtual "Whisperer Virtual Mic"] [--limit 12]
"""
import argparse, json, re, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import benchmark  # noqa: E402
from run_eval import call_sim, transcribe, to_16k  # noqa: E402

def hal_index(name):
    """Core Audio input by name. Recording goes through the HAL (PortAudio), the way call apps read a
    microphone: ffmpeg's AVFoundation capture receives only ~30% of the virtual mic's buffers."""
    import sounddevice as sd
    for i, d in enumerate(sd.query_devices()):
        if name.lower() in d["name"].lower() and d["max_input_channels"] > 0:
            return i, d["name"]
    raise SystemExit(f"audio device not found: {name}")

def record_both(phys, virt, seconds, play):
    """Record both inputs at 48 kHz mono while `play()` runs; returns (physical, virtual) float32 arrays."""
    import numpy as np, sounddevice as sd
    got = {phys: [], virt: []}
    streams = [sd.InputStream(device=d, channels=1, samplerate=48000, dtype="float32",
                              callback=lambda data, frames, t, status, d=d: got[d].append(data[:, 0].copy()))
               for d in (phys, virt)]
    for st in streams: st.start()
    time.sleep(0.6); play(); time.sleep(max(0.0, seconds - 0.6))
    for st in streams: st.stop(); st.close()
    return tuple(np.concatenate(got[d]) for d in (phys, virt))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("corpus"); ap.add_argument("--work", required=True)
    ap.add_argument("--whisper-cli", required=True); ap.add_argument("--model", required=True)
    ap.add_argument("--rnnoise", default=""); ap.add_argument("--opus-kbps", type=int, default=24)
    ap.add_argument("--physical", default="MacBook Pro Microphone"); ap.add_argument("--virtual", default="Whisperer Virtual Mic")
    ap.add_argument("--limit", type=int, default=12)
    a = ap.parse_args()
    work = Path(a.work); work.mkdir(parents=True, exist_ok=True)
    phys, phys_name = hal_index(a.physical); virt, virt_name = hal_index(a.virtual)
    print(f"physical: [{phys}] {phys_name}   virtual: [{virt}] {virt_name}", flush=True)
    rows = [json.loads(l) for l in (Path(a.corpus) / "corpus.jsonl").read_text().splitlines() if l.strip()][: a.limit]
    results = []
    for r in rows:
        clip = Path(a.corpus) / r["clean_audio"]
        dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(clip)],
                                   capture_output=True, text=True).stdout or 5) + 1.5
        pw, vw = work / f"{r['id']}.physical.wav", work / f"{r['id']}.virtual.wav"
        p, v = record_both(phys, virt, dur, lambda: subprocess.run(["afplay", str(clip)], check=True))
        import soundfile as sf
        sf.write(pw, p, 48000, subtype="PCM_16"); sf.write(vw, v, 48000, subtype="PCM_16")
        row = {"id": r["id"]}
        for side, wav in (("physical", pw), ("virtual", vw)):
            d16 = work / f"{r['id']}.{side}.direct16.wav"; to_16k(wav, d16)
            k16 = work / f"{r['id']}.{side}.call16.wav"; call_sim(wav, k16, a.opus_kbps, a.rnnoise)
            row[side] = {"direct": transcribe(a.whisper_cli, a.model, d16), "call": transcribe(a.whisper_cli, a.model, k16)}
        for cond in ("direct", "call"):
            ref = row["physical"][cond] or "empty"
            m = benchmark.transcript_metrics(ref, row["virtual"][cond], [])
            row[f"drift_{cond}"] = m["wer"]
            facts = benchmark.transcript_metrics(r["reference"], row["virtual"][cond], r["key_facts"])
            row[f"facts_{cond}"] = facts["literal_key_facts_recovered"] / max(1, facts["key_fact_count"])
        print(f"{r['id']}  drift call {row['drift_call']:.2f}  | heard: {row['physical']['call'][:60]}  | virtual: {row['virtual']['call'][:60]}", flush=True)
        results.append(row)
    mean = lambda k: sum(x[k] for x in results) / len(results)
    summary = {"clips": len(results), "drift_direct": round(mean("drift_direct"), 3), "drift_call": round(mean("drift_call"), 3),
               "virtual_key_facts_direct": round(mean("facts_direct"), 3), "virtual_key_facts_call": round(mean("facts_call"), 3)}
    (work / "live.json").write_text(json.dumps({"summary": summary, "clips": results}, indent=2))
    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""End-to-end Privacy Shield gate: does a processor make speech hard for AI transcription
after a conferencing pipeline, while staying intelligible?

For every corpus clip it builds four conditions:
  direct/clean, direct/shielded            the raw outgoing signal
  call/clean,   call/shielded              after a conferencing proxy: 48 kHz -> Opus
                                           (VoIP, 24 kbps by default) -> RNNoise suppression
and transcribes each with whisper.cpp, then reports WER, CER and key-fact recovery per
condition using benchmark.py's scorer. A processor that only works "direct" is not a
privacy feature: the call column is the one that matters.

The shielded signal comes from either the shipped C++ baseline (--processor baseline,
via libShieldBenchmark.dylib) or a Python processor module exposing
process(samples_float32_48k_mono) -> samples (--processor py:path/to/module.py).

usage: run_eval.py CORPUS_DIR --work WORK_DIR --whisper-cli PATH --model PATH
       [--processor baseline|py:FILE] [--strength 0.35] [--opus-kbps 24] [--rnnoise MODEL]
"""
import argparse, importlib.util, json, subprocess, sys, statistics
from pathlib import Path
import numpy as np, soundfile as sf

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import benchmark  # noqa: E402  (scorer + baseline processor wrapper)

def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def call_sim(src, dst, kbps, rnnoise):
    """Conferencing proxy: Opus VoIP at `kbps`, then RNNoise. Output 16 kHz mono for ASR."""
    opus = dst.with_suffix(".opus")
    run(["ffmpeg", "-y", "-i", str(src), "-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", f"{kbps}k",
         "-application", "voip", "-frame_duration", "20", str(opus)])
    af = f"arnndn=m={rnnoise}" if rnnoise else "anull"
    run(["ffmpeg", "-y", "-i", str(opus), "-af", af, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(dst)])
    opus.unlink(missing_ok=True)

def to_16k(src, dst):
    run(["ffmpeg", "-y", "-i", str(src), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(dst)])

def transcribe(cli, model, wav):
    base = wav.with_suffix("")
    run([cli, "-m", model, "-f", str(wav), "-l", "en", "-nt", "-oj", "-of", str(base)])
    data = json.loads(Path(f"{base}.json").read_text())
    return " ".join(seg["text"].strip() for seg in data.get("transcription", []))

def native_pnet(src, dst, library, weights, strength):
    """Run the shipped C++ network exactly as the audio worker does: 480-sample 48 kHz blocks."""
    import ctypes
    lib = ctypes.CDLL(str(library))
    lib.shield_pnet_create.restype = ctypes.c_void_p; lib.shield_pnet_create.argtypes = [ctypes.c_char_p]
    lib.shield_pnet_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_uint32, ctypes.c_float]
    lib.shield_pnet_destroy.argtypes = [ctypes.c_void_p]
    p = lib.shield_pnet_create(str(weights).encode())
    if not p: raise SystemExit(f"invalid weights: {weights}")
    x, sr = sf.read(src, dtype="float32"); assert sr == 48000
    n = len(x) // 480 * 480; y = np.copy(x)
    for i in range(0, n, 480):
        a = (ctypes.c_float * 480)(*x[i:i + 480]); b = (ctypes.c_float * 480)()
        lib.shield_pnet_process(p, a, b, 480, strength); y[i:i + 480] = np.frombuffer(b, np.float32)
    lib.shield_pnet_destroy(p)
    sf.write(dst, y, 48000, subtype="PCM_16")

def shield(src, dst, args, module):
    if args.processor.startswith("native:"):
        return native_pnet(src, dst, args.library, args.processor[7:], args.strength if args.strength != .35 else 1.0)
    if module is not None:
        x, sr = sf.read(src, dtype="float32")
        assert sr == 48000, "corpus must be 48 kHz"
        y = np.clip(np.asarray(module.process(x), dtype=np.float32), -0.98, 0.98)
        sf.write(dst, y, 48000, subtype="PCM_16")
    else:
        benchmark.process_audio(Path(src), Path(dst), Path(args.library), args.strength)

def snr_db(clean, other):
    n = min(len(clean), len(other)); c, o = clean[:n], other[:n]
    noise = o - c
    return 10 * np.log10((np.sum(c ** 2) + 1e-12) / (np.sum(noise ** 2) + 1e-12))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("corpus"); ap.add_argument("--work", required=True)
    ap.add_argument("--whisper-cli", required=True); ap.add_argument("--model", required=True)
    ap.add_argument("--processor", default="baseline"); ap.add_argument("--strength", type=float, default=.35)
    ap.add_argument("--library", default=str(HERE.parents[2] / "build/privacy-shield/libShieldBenchmark.dylib"))
    ap.add_argument("--opus-kbps", type=int, default=24); ap.add_argument("--rnnoise", default="")
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    corpus, work = Path(a.corpus), Path(a.work); work.mkdir(parents=True, exist_ok=True)
    module = None
    if a.processor.startswith("py:"):
        spec = importlib.util.spec_from_file_location("shield_processor", a.processor[3:])
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

    rows = [json.loads(l) for l in (corpus / "corpus.jsonl").read_text().splitlines() if l.strip()]
    results = {k: [] for k in ("direct/clean", "direct/shielded", "call/clean", "call/shielded")}
    snrs = []
    for r in rows:
        clean = corpus / r["clean_audio"]
        shielded = work / f"{r['id']}.shielded.wav"
        shield(clean, shielded, a, module)
        c, _ = sf.read(clean, dtype="float32"); s, _ = sf.read(shielded, dtype="float32"); snrs.append(float(snr_db(c, s)))
        for side, src in (("clean", clean), ("shielded", shielded)):
            d = work / f"{r['id']}.{side}.direct16.wav"; to_16k(src, d)
            k = work / f"{r['id']}.{side}.call16.wav"; call_sim(src, k, a.opus_kbps, a.rnnoise)
            for cond, wav in (("direct", d), ("call", k)):
                hyp = transcribe(a.whisper_cli, a.model, wav)
                m = benchmark.transcript_metrics(r["reference"], hyp, r["key_facts"])
                m["key_fact_recall"] = m["literal_key_facts_recovered"] / max(1, m["key_fact_count"])
                results[f"{cond}/{side}"].append({"id": r["id"], "sex": r["sex"], "hyp": hyp, **m})
        # The shield's own effect: how far the shielded transcript drifts from the clean one
        # in the same condition (independent of number formatting in the reference).
        for cond in ("direct", "call"):
            ref_hyp = results[f"{cond}/clean"][-1]["hyp"]
            mine = results[f"{cond}/shielded"][-1]
            drift = benchmark.transcript_metrics(ref_hyp or "empty", mine["hyp"], [])
            mine["wer_vs_clean"] = drift["wer"]
            clean_facts = results[f"{cond}/clean"][-1]["key_fact_recall"]
            mine["facts_vs_clean"] = mine["key_fact_recall"] - clean_facts
        print(r["id"], "|", results["call/shielded"][-1]["hyp"][:90], flush=True)

    def agg(items, key):
        vals = [i[key] for i in items if i.get(key) is not None]
        return statistics.mean(vals) if vals else float("nan")

    summary = {"label": a.label or a.processor, "opus_kbps": a.opus_kbps, "rnnoise": bool(a.rnnoise),
               "mean_snr_db": round(statistics.mean(snrs), 2), "conditions": {}}
    for cond, items in results.items():
        summary["conditions"][cond] = {"wer": round(agg(items, "wer"), 3), "cer": round(agg(items, "cer"), 3),
                                       "key_fact_recall": round(agg(items, "key_fact_recall"), 3)}
        if cond.endswith("shielded"):
            summary["conditions"][cond]["wer_vs_clean"] = round(agg(items, "wer_vs_clean"), 3)
    (work / "summary.json").write_text(json.dumps(summary, indent=2))
    (work / "transcripts.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    main()

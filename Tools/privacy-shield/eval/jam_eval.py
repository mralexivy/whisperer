#!/usr/bin/env python3
"""Transcription-jammer gate on REAL human speech (LibriSpeech dev-clean, held-out speakers), after the
call proxy (Opus 24 kbps VoIP + RNNoise). For each processor it reports, per recogniser, WER against the
human reference and content-word recall: the share of reference words longer than three letters (not
stop words) that appear in the transcript. Content-word recall is what a notetaker summary is built from.

Recognisers: whisper.cpp large-v3-turbo (always), Parakeet TDT 0.6B (--parakeet-python), Qwen3-ASR 1.7B
(--qwen, via mlx_audio in the running interpreter). None was used to design or tune the jammer.

usage: jam_eval.py --libri DEV_CLEAN --work DIR --processor py:chain_processor.py [--processor ...]
       [--utts 24] [--parakeet-python PY] [--qwen]
"""
import argparse, importlib.util, json, re, subprocess, sys, random
from pathlib import Path
import numpy as np, soundfile as sf
from scipy.signal import resample_poly
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent))
from run_eval import call_sim, transcribe  # noqa: E402
from baseline_probe import wer  # noqa: E402

STOP = set("that this with from have were been they them their there what when which would could should "
           "about into than then said very only also some such more most other over your just like will".split())


def words(t):
    return re.findall(r"[a-z']+", t.lower())


def content_recall(ref, hyp):
    c = [w for w in words(ref) if len(w) > 3 and w not in STOP]
    h = set(words(hyp))
    return sum(w in h for w in c) / max(1, len(c))


def utterances(libri, n, seed=1):
    rng = random.Random(seed); out = []
    for spk in sorted(Path(libri).iterdir()):
        files = [f for f in sorted(spk.rglob("*.flac")) if 6 <= sf.info(f).duration <= 15]
        if files:
            f = rng.choice(files)
            tr = next(f.parent.glob("*.trans.txt")).read_text().splitlines()
            out.append((f, next(l.split(" ", 1)[1] for l in tr if l.startswith(f.stem))))
    rng.shuffle(out); return out[:n]


def load(spec):
    s = importlib.util.spec_from_file_location(Path(spec).stem, spec); m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m); return m


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--libri", required=True); ap.add_argument("--work", required=True)
    ap.add_argument("--processor", action="append", default=[]); ap.add_argument("--utts", type=int, default=24)
    ap.add_argument("--whisper-cli", default="/Users/alexivy/ai/whisperer/whisper.cpp/build-static/bin/whisper-cli")
    ap.add_argument("--model", default=str(Path.home() / "Library/Application Support/Whisperer/ggml-large-v3-turbo-q5_0.bin"))
    ap.add_argument("--rnnoise", default=str(HERE.parents[2] / "build/privacy-shield/eval/models/rn.rnnn"))
    ap.add_argument("--parakeet-python", default=""); ap.add_argument("--qwen", action="store_true")
    a = ap.parse_args(); work = Path(a.work); work.mkdir(parents=True, exist_ok=True)
    utts = utterances(a.libri, a.utts)
    conds = {"clean": None, **{p.split(":", 1)[1]: load(p.split(":", 1)[1]) for p in a.processor}}
    files = {}
    for name, mod in conds.items():
        tag = Path(name).stem if mod else "clean"
        for i, (f, _) in enumerate(utts):
            x, sr = sf.read(f, dtype="float32"); x48 = resample_poly(x, 48000, sr).astype(np.float32)
            y = np.clip(mod.process(x48), -0.98, 0.98) if mod else x48
            src = work / f"{i:02d}.{tag}.48.wav"; sf.write(src, y, 48000, subtype="PCM_16")
            dst = work / f"{i:02d}.{tag}.call16.wav"; call_sim(src, dst, 24, a.rnnoise)
            files.setdefault(tag, []).append(dst)
    hyps = {"whisper": {t: [transcribe(a.whisper_cli, a.model, p) for p in ps] for t, ps in files.items()}}
    if a.parakeet_python:
        listing = work / "parakeet-in.json"; listing.write_text(json.dumps({t: [str(p) for p in ps] for t, ps in files.items()}))
        code = ("import json,sys;from parakeet_mlx import from_pretrained;m=from_pretrained('mlx-community/parakeet-tdt-0.6b-v2');"
                "d=json.load(open(sys.argv[1]));print(json.dumps({t:[m.transcribe(p).text for p in ps] for t,ps in d.items()}))")
        out = subprocess.run([a.parakeet_python, "-c", code, str(listing)], capture_output=True, text=True, check=True).stdout
        hyps["parakeet"] = json.loads(out.strip().splitlines()[-1])
    if a.qwen:
        from mlx_audio.stt.utils import load_model
        q = load_model("mlx-community/Qwen3-ASR-1.7B-8bit")
        hyps["qwen3"] = {t: [getattr(q.generate(str(p)), "text", "").strip() for p in ps] for t, ps in files.items()}
    report = {}
    for asr, by in hyps.items():
        report[asr] = {t: {"wer": round(float(np.mean([wer(r, h) for (_, r), h in zip(utts, hs)])), 3),
                           "content_recall": round(float(np.mean([content_recall(r, h) for (_, r), h in zip(utts, hs)])), 3)}
                       for t, hs in by.items()}
    (work / "jam_eval.json").write_text(json.dumps({"report": report, "hyps": hyps, "refs": [r for _, r in utts]}, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

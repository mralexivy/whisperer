#!/usr/bin/env python3
"""Voice-identity eval for Privacy Shield: does the shielded voice still verify as the same speaker,
and do the words survive?

Real held-out speakers (LibriSpeech dev-clean). Per speaker: one clean enrollment utterance, one test
utterance processed by each condition and then sent through the call proxy (Opus + RNNoise), which is
what a notetaker or voice cloner receives. Two speaker models: ECAPA (speechbrain) and WavLM-SV
(held out from training). The threshold for "same speaker" is the equal-error-rate point on clean
pairs, so `still_you` is the fraction of shielded test clips a verification system would still accept.

usage: speaker_eval.py --libri DEV_CLEAN --work DIR [--processor native:W.wspn ...] [--speakers 20]
       [--whisper-cli P --model P]   (adds word error vs the clean transcript)
"""
import argparse, json, random, subprocess, sys
from pathlib import Path
import numpy as np, soundfile as sf, torch
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent))
from run_eval import call_sim, native_pnet, transcribe, run  # noqa: E402
from baseline_probe import wer  # noqa: E402

def utterances(libri, n_spk, seed=0):
    rng = random.Random(seed); out = []
    for spk in sorted(Path(libri).iterdir()):
        files = [f for f in sorted(spk.rglob("*.flac")) if 4 <= sf.info(f).duration <= 12]
        if len(files) >= 2:
            a, b = rng.sample(files, 2); out.append((spk.name, a, b))
    rng.shuffle(out); return out[:n_spk]

def text_of(flac):
    tr = next(flac.parent.glob("*.trans.txt")).read_text().splitlines()
    return next(l.split(" ", 1)[1] for l in tr if l.startswith(flac.stem))

class Embedders:
    def __init__(self, models_dir):
        from speechbrain.inference.speaker import EncoderClassifier
        from transformers import AutoFeatureExtractor, WavLMForXVector
        self.ecapa = EncoderClassifier.from_hparams(source="speechbrain/spkrec-ecapa-voxceleb", savedir=str(models_dir / "ecapa"))
        self.fe = AutoFeatureExtractor.from_pretrained("microsoft/wavlm-base-plus-sv")
        self.wavlm = WavLMForXVector.from_pretrained("microsoft/wavlm-base-plus-sv").eval()
    @torch.no_grad()
    def __call__(self, wav16):
        x = torch.from_numpy(wav16).float()
        e = self.ecapa.encode_batch(x.unsqueeze(0)).squeeze()
        w = self.wavlm(**self.fe(wav16, sampling_rate=16000, return_tensors="pt")).embeddings.squeeze()
        return {"ecapa": torch.nn.functional.normalize(e, dim=0), "wavlm": torch.nn.functional.normalize(w, dim=0)}

def eer_threshold(same, diff):
    best = (1, 0)
    for t in np.linspace(-1, 1, 2001):
        far = np.mean(np.array(diff) >= t); frr = np.mean(np.array(same) < t)
        if abs(far - frr) < best[0]: best = (abs(far - frr), t)
    return best[1]

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--libri", required=True); ap.add_argument("--work", required=True)
    ap.add_argument("--processor", action="append", default=[], help="native:W.wspn | pitch:1.15 | reshape:1.15")
    ap.add_argument("--speakers", type=int, default=20); ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--library", default=str(HERE.parents[2] / "build/privacy-shield/libShieldBenchmark.dylib"))
    ap.add_argument("--rnnoise", default=str(HERE.parents[2] / "build/privacy-shield/eval/models/rn.rnnn"))
    ap.add_argument("--whisper-cli", default=""); ap.add_argument("--model", default="")
    a = ap.parse_args(); work = Path(a.work); work.mkdir(parents=True, exist_ok=True)
    emb = Embedders(HERE.parents[2] / "build/privacy-shield/eval/models")
    utts = utterances(a.libri, a.speakers)

    def to48(src, dst): run(["ffmpeg", "-y", "-i", str(src), "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", str(dst)])
    def via_call(src48, name):
        dst = work / f"{name}.call16.wav"; call_sim(src48, dst, 24, a.rnnoise); return dst
    def load(p): return sf.read(p, dtype="float32")[0]

    enroll, tests = {}, {}
    for spk, fa, fb in utts:
        ea = work / f"{spk}.enroll48.wav"; to48(fa, ea); enroll[spk] = emb(load(via_call(ea, f"{spk}.enroll")))
        tb = work / f"{spk}.test48.wav"; to48(fb, tb); tests[spk] = (tb, text_of(fb))
    conds = ["clean"] + a.processor
    report = {}
    clean_text = {}
    for cond in conds:
        sims = {"ecapa": {}, "wavlm": {}}; wers = []; embs = {}
        for spk, (tb, ref) in tests.items():
            tag = cond.replace(":", "_").replace("/", "_")[-40:]
            src = tb
            if cond.startswith("native:"):
                src = work / f"{spk}.{tag}.48.wav"; native_pnet(tb, src, a.library, cond[7:], a.strength)
            elif cond.startswith("pitch:"):
                f = float(cond[6:]); src = work / f"{spk}.{tag}.48.wav"
                run(["ffmpeg", "-y", "-i", str(tb), "-af", f"asetrate={48000*f:.0f},aresample=48000,atempo={1/f:.4f}", "-c:a", "pcm_s16le", str(src)])
            elif cond.startswith("reshape:"):
                from reshape import reshape
                x48, _ = sf.read(tb, dtype="float32"); src = work / f"{spk}.{tag}.48.wav"
                sf.write(src, np.clip(reshape(x48, float(cond[8:])), -0.98, 0.98), 48000, subtype="PCM_16")
            c16 = via_call(src, f"{spk}.{tag}"); e = emb(load(c16)); embs[spk] = e
            for k in sims: sims[k][spk] = float(enroll[spk][k] @ e[k])
            if a.whisper_cli:
                hyp = transcribe(a.whisper_cli, a.model, c16)
                if cond == "clean": clean_text[spk] = hyp
                wers.append(wer(clean_text[spk], hyp))
        if cond == "clean":
            thr = {}
            for k in sims:
                same = list(sims[k].values())
                diff = [float(enroll[s1][k] @ embs[s2][k]) for s1 in tests for s2 in tests if s1 != s2]
                thr[k] = eer_threshold(same, diff)
            report["threshold"] = {k: round(v, 3) for k, v in thr.items()}
        row = {}
        for k in sims:
            v = np.array(list(sims[k].values()))
            row[k] = {"mean_sim": round(float(v.mean()), 3), "still_you": round(float(np.mean(v >= thr[k])), 3)}
        if wers: row["wer_vs_clean"] = round(float(np.mean(wers)), 3)
        report[cond] = row
        print(json.dumps({cond: row}), flush=True)
    (work / "speaker_eval.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()

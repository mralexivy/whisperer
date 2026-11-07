#!/usr/bin/env python3
"""Train the causal predictive perturbation network (pnet.PerturbNet).

Loss per utterance, on a white-box Whisper ensemble seeing the audio AFTER a real conferencing path
(Opus 16-32 kbps VoIP, half the time RNNoise; straight-through gradient):
  attack   = mute (first token -> end of transcript) - away_weight * clamp(true-transcript CE)
  quiet    = mean over mel bands and frames of relu(dB(delta) - dB(speech) + margin)   (masking proxy)
Data: LibriSpeech (real read speech, <= 12 s, with transcripts) + the synthetic training set.

usage: train_pnet.py --libri DIR --synth DIR --out CKPT_DIR [--steps 3000] [--models base,small]
"""
import argparse, glob, json, random, time
from pathlib import Path
import numpy as np, soundfile as sf, torch, torch.nn.functional as F
import torchaudio.functional as AF
import whisper
from whisper.tokenizer import get_tokenizer
import sys; sys.path.insert(0, str(Path(__file__).resolve().parent))
from pnet import PerturbNet, HOP  # noqa: E402
from train_uap import log_mel, sim_call  # noqa: E402

def load_libri(root, max_s=12.0, limit=None):
    items = []
    for trans in sorted(glob.glob(f"{root}/**/*.trans.txt", recursive=True)):
        d = Path(trans).parent
        for line in open(trans):
            uid, text = line.strip().split(" ", 1)
            items.append((str(d / f"{uid}.flac"), text.lower().capitalize() + "."))
    random.Random(0).shuffle(items)
    out = []
    for path, text in items:
        info = sf.info(path)
        if info.duration <= max_s:
            out.append((path, text))
        if limit and len(out) >= limit:
            break
    return out

def load_audio16(path):
    x, sr = sf.read(path, dtype="float32")
    if x.ndim > 1: x = x.mean(1)
    x = torch.from_numpy(x)
    if sr != 16000: x = AF.resample(x, sr, 16000)
    return x

def band_db(x, fb):
    spec = torch.stft(x, 512, 160, window=torch.hann_window(512, device=x.device), return_complex=True)
    p = spec.real ** 2 + spec.imag ** 2
    return 10 * torch.log10(fb @ p + 1e-10)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--libri", required=True); ap.add_argument("--synth", default="")
    ap.add_argument("--out", required=True); ap.add_argument("--steps", type=int, default=3000)
    ap.add_argument("--batch", type=int, default=6); ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--models", default="base,small"); ap.add_argument("--rnnoise", default="")
    ap.add_argument("--margin", type=float, default=12.0); ap.add_argument("--quiet-weight", type=float, default=0.05)
    ap.add_argument("--away-weight", type=float, default=0.3); ap.add_argument("--max-amp", type=float, default=0.05)
    ap.add_argument("--resume", default=""); ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    random.seed(a.seed); torch.manual_seed(a.seed); np.random.seed(a.seed)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)

    data = load_libri(a.libri)
    if a.synth:
        for l in (Path(a.synth) / "train.jsonl").read_text().splitlines():
            r = json.loads(l); data.append((str(Path(a.synth) / r["audio"]), r["reference"]))
    print("utterances", len(data), flush=True)

    net = PerturbNet(max_amp=a.max_amp).to(dev)
    opt = torch.optim.AdamW(net.parameters(), lr=a.lr, weight_decay=1e-4)
    start = 1
    if a.resume:
        ck = torch.load(a.resume, map_location=dev); net.load_state_dict(ck["model"]); opt.load_state_dict(ck["opt"]); start = ck["step"] + 1
    models = [whisper.load_model(m, device=dev) for m in a.models.split(",")]
    for m in models:
        m.eval(); [p.requires_grad_(False) for p in m.parameters()]
    tok = get_tokenizer(multilingual=True, language="en", task="transcribe")
    sot = list(tok.sot_sequence_including_notimestamps)
    fb = AF.melscale_fbanks(257, 0.0, 8000.0, 40, 16000).T.contiguous().to(dev)   # [40 bands, 257 bins]

    t0 = time.time(); hist = []
    for step in range(start, a.steps + 1):
        net.train(); opt.zero_grad()
        stats = {"mute": 0.0, "true_ce": 0.0, "quiet": 0.0, "snr": 0.0}
        for path, text in random.sample(data, a.batch):
            x = load_audio16(path).to(dev)
            x = x * (random.uniform(0.15, 0.6) / (x.abs().max() + 1e-6))
            x = x[: len(x) // HOP * HOP]
            delta = net(x.view(1, -1))[0]
            xa = torch.clamp(x + delta, -1, 1) + 1e-5 * torch.randn_like(x)
            # quiet: perturbation must stay `margin` dB under the speech in every band and frame
            dd, dx = band_db(delta + 1e-7 * torch.randn_like(delta), fb), band_db(x, fb).detach()
            speech = (dx > dx.max() - 50).float()                      # ignore near-silent cells
            quiet = (F.relu(dd - dx + a.margin) * speech).sum() / (speech.sum() + 1)
            # conferencing path at 48 kHz, straight-through
            x48 = AF.resample(xa, 16000, 48000)
            kbps = random.choice([16, 20, 24, 32]); use_rn = bool(a.rnnoise) and random.random() < 0.5
            y = np.nan_to_num(sim_call(x48.detach().cpu().numpy(), kbps, a.rnnoise if use_rn else ""))
            y = torch.from_numpy((y + np.random.normal(0, 1e-5, len(y))).astype(np.float32)).to(dev)
            n = min(len(xa), len(y)); z = xa[:n] + (y[:n] - xa[:n]).detach()
            audio = whisper.pad_or_trim(z)
            tt = tok.encode(" " + text)[:200]
            attack = 0.0
            for m in models:
                logits = m.decoder(torch.tensor([sot + tt], device=dev), m.encoder(log_mel(audio, m.dims.n_mels).unsqueeze(0)))[0]
                mute = F.cross_entropy(logits[len(sot) - 1: len(sot)], torch.tensor([tok.eot], device=dev))
                tgt = torch.tensor(tt + [tok.eot], device=dev)
                ce = F.cross_entropy(logits[len(sot) - 1: len(sot) - 1 + len(tgt)], tgt)
                attack = attack + (mute - a.away_weight * torch.clamp(ce, max=8.0)) / len(models)
                stats["mute"] += mute.item() / (len(models) * a.batch); stats["true_ce"] += ce.item() / (len(models) * a.batch)
            loss = (attack + a.quiet_weight * quiet) / a.batch
            loss.backward()
            stats["quiet"] += quiet.item() / a.batch
            stats["snr"] += (10 * torch.log10(x.pow(2).sum() / (delta.pow(2).sum() + 1e-12))).item() / a.batch
        grads_ok = all(p.grad is None or torch.isfinite(p.grad).all() for p in net.parameters())
        if not grads_ok:
            print(f"step {step}: non-finite gradient, skipped", flush=True); continue
        torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
        opt.step()
        if step % 10 == 0 or step == start:
            el = time.time() - t0
            print(f"step {step:5d}  true_ce {stats['true_ce']:.3f}  mute {stats['mute']:.3f}  quiet {stats['quiet']:.2f}  snr {stats['snr']:.1f} dB  {el / (step - start + 1):.1f}s/step", flush=True)
            hist.append({"step": step, **stats})
        if step % 200 == 0 or step == a.steps:
            torch.save({"model": net.state_dict(), "opt": opt.state_dict(), "step": step, "args": vars(a)}, out / "last.pt")
            torch.save({"model": net.state_dict(), "step": step, "args": vars(a)}, out / f"step{step:05d}.pt")
            (out / "log.json").write_text(json.dumps(hist))

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Train a universal, time-varying SPECTRAL perturbation for Privacy Shield (clean-room, from public
research: adversarial examples for ASR + the competitor's observed Y=(1+g)Xe^{iphi} form). Unlike
train_uap.py (a time-domain added signal), this learns gain and phase FIELDS in a 400/160/201 STFT at
16 kHz and applies them per frame, looped over the utterance with a random start frame.

Why time-varying: a fixed g(f)/phi(f) is just an EQ + all-pass filter, which ASR is robust to. Changing
the field frame-to-frame makes the recogniser's own STFT (a different grid) see magnitude errors while
the ear, insensitive to phase, still hears natural speech.

Objective on white-box Whisper small/medium, through REAL Opus (random 16-32 kbps VoIP) + optional
RNNoise with a straight-through gradient:
  away:  raise cross-entropy of the true transcript (bounded), and
  bound: an L2 penalty keeping gain (dB) and phase (rad) small for naturalness.

usage: train_spectral.py TRAIN_DIR --out field.npz [--frames 24] [--gain-db 4] [--phase 2.0]
"""
import argparse, json, random, time
from pathlib import Path
import numpy as np, soundfile as sf, torch, torch.nn.functional as F
import torchaudio.functional as AF
import whisper
from whisper.tokenizer import get_tokenizer
from train_uap import log_mel, sim_call

SR = 16000; NFFT = 400; HOP = 160; BINS = 201


def stft(x):
    w = torch.hann_window(NFFT, periodic=True, device=x.device, dtype=x.dtype)
    return torch.stft(x, NFFT, HOP, NFFT, w, center=True, return_complex=True)  # (BINS, T)


def istft(X, length):
    w = torch.hann_window(NFFT, periodic=True, device=X.device, dtype=X.real.dtype)
    return torch.istft(X, NFFT, HOP, NFFT, w, center=True, length=length)


def apply_field(x, gain, phase, off):
    """x: (n,) 16 kHz. gain,phase: (F_frames, BINS). Looped over time from frame `off`."""
    X = stft(x); T = X.shape[1]
    idx = (torch.arange(T, device=x.device) + off) % gain.shape[0]
    g = gain[idx].transpose(0, 1); p = phase[idx].transpose(0, 1)        # (BINS, T)
    Y = (1 + g) * X * torch.exp(1j * p)
    return istft(Y, x.shape[0])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("train"); ap.add_argument("--out", required=True)
    ap.add_argument("--models", default="small,medium"); ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--gain-db", type=float, default=4.0, help="soft bound on |gain|, dB")
    ap.add_argument("--phase", type=float, default=2.0, help="soft bound on |phase|, rad")
    ap.add_argument("--hpf", type=float, default=300.0, help="leave bins below this Hz unperturbed")
    ap.add_argument("--bound-weight", type=float, default=0.05)
    ap.add_argument("--steps", type=int, default=400); ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--lr", type=float, default=0.02); ap.add_argument("--rnnoise", default="")
    ap.add_argument("--holdout", type=int, default=20); ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    torch.manual_seed(a.seed); random.seed(a.seed); np.random.seed(a.seed)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

    rows = [json.loads(l) for l in (Path(a.train) / "train.jsonl").read_text().splitlines() if l.strip()]
    rows = rows[: len(rows) - a.holdout]
    clips = []
    for r in rows:
        x, sr = sf.read(Path(a.train) / r["audio"], dtype="float32"); assert sr == SR * 3
        x16 = AF.resample(torch.from_numpy(x[: SR * 3 * 8]), SR * 3, SR).numpy()
        clips.append((x16, r["reference"]))

    models = [whisper.load_model(m, device=dev) for m in a.models.split(",")]
    for m in models:
        m.eval(); [p.requires_grad_(False) for p in m.parameters()]
    tok = get_tokenizer(multilingual=True, language="en", task="transcribe")
    sot = list(tok.sot_sequence_including_notimestamps)
    lo_bin = int(a.hpf / SR * NFFT)

    gain = torch.zeros(a.frames, BINS, device=dev, requires_grad=True)
    phase = torch.zeros(a.frames, BINS, device=dev, requires_grad=True)
    with torch.no_grad():
        gain.normal_(0, 0.1); phase.normal_(0, 0.1)
    opt = torch.optim.Adam([gain, phase], lr=a.lr)
    gmax = 10 ** (a.gain_db / 20) - 1
    log, t0 = [], time.time()
    for step in range(1, a.steps + 1):
        opt.zero_grad(); stats = {"true_ce": 0.0, "gdb": 0.0, "prad": 0.0}
        g = torch.tanh(gain) * gmax; p = torch.tanh(phase) * a.phase
        mask = torch.ones(BINS, device=dev); mask[:lo_bin] = 0.0
        g = g * mask; p = p * mask
        for x_np, text in random.sample(clips, a.batch):
            x = torch.from_numpy(x_np).to(dev) * random.uniform(0.7, 1.3)
            off = random.randrange(a.frames)
            xa = apply_field(x, g, p, off).clamp(-1, 1)
            xa = xa + 1e-5 * torch.randn_like(xa)
            rn = a.rnnoise if a.rnnoise and random.random() < 0.5 else ""
            y = np.nan_to_num(sim_call(AF.resample(xa, SR, SR * 3).detach().cpu().numpy(),
                                       random.choice([16, 20, 24, 32]), rn))
            y16 = torch.from_numpy((y + np.random.normal(0, 1e-5, len(y))).astype(np.float32)).to(dev)
            n = min(len(xa), len(y16))
            z = whisper.pad_or_trim(xa[:n] + (y16[:n] - xa[:n]).detach())      # straight-through codec
            toks = tok.encode(" " + text.strip())
            seq = torch.tensor([sot + toks], device=dev)
            tgt = torch.tensor(toks + [tok.eot], device=dev)
            away = 0.0
            for m in models:
                feats = m.encoder(log_mel(z, m.dims.n_mels).unsqueeze(0))
                logits = m.decoder(seq, feats)[0]
                ce = F.cross_entropy(logits[len(sot) - 1: len(sot) - 1 + len(tgt)], tgt)
                away = away - torch.clamp(ce, max=8.0) / (len(models) * a.batch)
                stats["true_ce"] += ce.item() / (len(models) * a.batch)
            bound = ((g / max(gmax, 1e-6)) ** 2).mean() + ((p / max(a.phase, 1e-6)) ** 2).mean()
            (away + a.bound_weight * bound / a.batch).backward(retain_graph=True)
        with torch.no_grad():
            stats["gdb"] = float(20 * torch.log10(1 + g.abs().max()))
            stats["prad"] = float(p.abs().max())
        if gain.grad is None or not torch.isfinite(gain.grad).all():
            print(f"step {step}: non-finite grad, skipped", flush=True); opt.zero_grad(); continue
        opt.step()
        if step % 10 == 0 or step == 1:
            print(f"step {step:4d}  true_ce {stats['true_ce']:.3f}  max|g| {stats['gdb']:.1f}dB  "
                  f"max|phi| {stats['prad']:.2f}rad  {(time.time()-t0)/step:.1f}s/step", flush=True)
            log.append({"step": step, **stats})
            np.savez(a.out, gain=(torch.tanh(gain) * gmax).detach().cpu().numpy(),
                     phase=(torch.tanh(phase) * a.phase).detach().cpu().numpy(), hpf=a.hpf)
    np.savez(a.out, gain=(torch.tanh(gain) * gmax).detach().cpu().numpy(),
             phase=(torch.tanh(phase) * a.phase).detach().cpu().numpy(), hpf=a.hpf)
    Path(a.out).with_suffix(".log.json").write_text(json.dumps({"args": vars(a), "log": log}, indent=2))
    print("saved", a.out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Train a universal, looped adversarial perturbation for Privacy Shield (clean-room, from
public research: universal perturbations + "Muting Whisper", Raina et al. 2024; codec-aware
training per arXiv 2605.20519).

delta is a fixed-length 48 kHz buffer that the real-time pipeline simply loops and adds to the
microphone signal (y = x + eps * tanh(delta)), so it fits the existing stateless 10 ms contract.
It is trained to be phase-invariant (random loop offset every step) and to survive a
conferencing path: every step sends the perturbed audio through REAL Opus (random 16-32 kbps,
VoIP mode) and, half the time, RNNoise, using a straight-through gradient around them.

Objective on an ensemble of white-box Whisper models:
  mute:  make the first decoded token end-of-transcript (Whisper outputs nothing), and
  away:  increase cross-entropy of the true transcript (bounded, so it can't run away).

usage: train_uap.py TRAIN_DIR --out delta.npy [--eps 0.02] [--steps 300] [--models base,small]
"""
import argparse, json, random, subprocess, time
from pathlib import Path
import numpy as np, soundfile as sf, torch, torch.nn.functional as F
import torchaudio.functional as AF
import whisper
from whisper.tokenizer import get_tokenizer

SR = 48000

_WINDOWS = {}

def log_mel(audio, n_mels):
    """Same as whisper.log_mel_spectrogram, but |X|^2 is computed as re^2 + im^2. Whisper's
    abs() of a complex tensor has a 0/0 gradient on silence (all the zero padding), which
    turns delta into NaN within a few steps."""
    from whisper.audio import mel_filters, N_FFT, HOP_LENGTH
    key = (audio.device, n_mels)
    if key not in _WINDOWS:
        _WINDOWS[key] = (torch.hann_window(N_FFT, device=audio.device), mel_filters(audio.device, n_mels))
    window, filters = _WINDOWS[key]
    stft = torch.stft(audio, N_FFT, HOP_LENGTH, window=window, return_complex=True)
    power = (stft.real ** 2 + stft.imag ** 2)[..., :-1]
    mel = filters @ power
    log_spec = torch.clamp(mel, min=1e-10).log10()
    log_spec = torch.maximum(log_spec, log_spec.max() - 8.0)
    return (log_spec + 4.0) / 4.0

def envelope(x, ms=20):
    """Causal RMS envelope (no look-ahead), detached: the real-time pipeline computes the same
    thing with a one-pole follower over past samples only."""
    w = int(SR * ms / 1000)
    p = F.pad((x.detach() ** 2).view(1, 1, -1), (w - 1, 0))
    return torch.sqrt(torch.clamp(F.avg_pool1d(p, w, stride=1).view(-1), min=0) + 1e-8) * 1.414


def sim_call(x48, kbps, rnnoise):
    """Real conferencing proxy on numpy float32 48 kHz -> float32 16 kHz (same duration)."""
    enc = subprocess.run(["ffmpeg", "-v", "error", "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", "-",
                          "-c:a", "libopus", "-b:a", f"{kbps}k", "-application", "voip", "-f", "ogg", "-"],
                         input=x48.astype(np.float32).tobytes(), capture_output=True, check=True).stdout
    af = ["-af", f"arnndn=m={rnnoise}"] if rnnoise else []
    dec = subprocess.run(["ffmpeg", "-v", "error", "-i", "-", *af, "-f", "f32le", "-ar", "16000", "-ac", "1", "-"],
                         input=enc, capture_output=True, check=True).stdout
    y = np.frombuffer(dec, dtype=np.float32)
    n = len(x48) // 3
    return np.pad(y, (0, max(0, n - len(y))))[:n]

def saved(delta, a):
    """Relative mode stores the unit pattern tanh(delta); the processor multiplies by relative*env."""
    t = torch.tanh(delta).detach().cpu().numpy()
    return t if a.relative > 0 else a.eps * t


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("train"); ap.add_argument("--out", required=True)
    ap.add_argument("--eps", type=float, default=0.02); ap.add_argument("--steps", type=int, default=300)
    ap.add_argument("--batch", type=int, default=6); ap.add_argument("--length", type=int, default=SR)
    ap.add_argument("--models", default="base,small"); ap.add_argument("--lr", type=float, default=0.01)
    ap.add_argument("--rnnoise", default=""); ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--away-weight", type=float, default=0.3)
    ap.add_argument("--relative", type=float, default=0.0,
                    help="if >0, scale delta by a causal 20 ms speech envelope: d = relative * env(x) * tanh(delta) "
                         "(speech-shaped: strong under the voice, silent in pauses); --eps is then ignored")
    ap.add_argument("--prerev", type=float, default=0.0,
                    help="hybrid jammer: train on top of mild local time reversal (frame ms, +-20%%, 3 ms fades)")
    a = ap.parse_args()
    torch.manual_seed(a.seed); random.seed(a.seed); np.random.seed(a.seed)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

    rows = [json.loads(l) for l in (Path(a.train) / "train.jsonl").read_text().splitlines() if l.strip()]
    clips = []
    for r in rows:
        x, sr = sf.read(Path(a.train) / r["audio"], dtype="float32"); assert sr == SR
        if a.prerev > 0:
            from transform_processor import revfade
            x = revfade(x.astype(np.float64), a.prerev, 3.0, jitter=0.2).astype(np.float32)
        clips.append((x[: SR * 8], r["reference"]))

    models = [whisper.load_model(m, device=dev) for m in a.models.split(",")]
    for m in models:
        m.eval(); [p.requires_grad_(False) for p in m.parameters()]
    tok = get_tokenizer(multilingual=True, language="en", task="transcribe")
    sot = list(tok.sot_sequence_including_notimestamps)

    delta = torch.zeros(a.length, device=dev, requires_grad=True)
    with torch.no_grad():
        delta.normal_(0, 0.5)
    opt = torch.optim.Adam([delta], lr=a.lr)
    log = []
    t0 = time.time()
    for step in range(1, a.steps + 1):
        batch = random.sample(clips, a.batch)
        loss_total, mute_total, away_total = 0.0, 0.0, 0.0
        opt.zero_grad()
        for x_np, text in batch:
            x = torch.from_numpy(x_np).to(dev)
            off = random.randrange(a.length)
            reps = (len(x) + off) // a.length + 1
            gain = random.uniform(0.6, 1.4)
            xg = gain * x
            if a.relative > 0:
                d = torch.tanh(delta).repeat(reps)[off: off + len(x)] * a.relative * envelope(xg)
            else:
                d = (a.eps * torch.tanh(delta)).repeat(reps)[off: off + len(x)]
            xa = torch.clamp(xg + d, -1, 1)
            xa = xa + 1e-5 * torch.randn_like(xa)   # -100 dB dither: exact-zero stretches give 0/0 gradients on MPS
            x16 = AF.resample(xa, SR, 16000)
            kbps = random.choice([16, 20, 24, 32])
            use_rn = bool(a.rnnoise) and random.random() < 0.5
            y_np = np.nan_to_num(sim_call(xa.detach().cpu().numpy(), kbps, a.rnnoise if use_rn else ""))
            y_np = y_np + np.random.normal(0, 1e-5, len(y_np)).astype(np.float32)  # -100 dB dither: no exact-zero gated stretches
            y16 = torch.from_numpy(y_np.astype(np.float32)).to(dev)
            n = min(len(x16), len(y16))
            z = x16[:n] + (y16[:n] - x16[:n]).detach()           # straight-through codec + denoiser
            audio = whisper.pad_or_trim(z)
            text_tokens = tok.encode(" " + text.strip())
            clip_loss = 0.0
            for m in models:
                mel = log_mel(audio, m.dims.n_mels).unsqueeze(0)
                feats = m.encoder(mel)
                seq = torch.tensor([sot + text_tokens], device=dev)
                logits = m.decoder(seq, feats)[0]                  # [T, vocab]
                first = logits[len(sot) - 1]                       # prediction of the first text token
                mute = F.cross_entropy(first.unsqueeze(0), torch.tensor([tok.eot], device=dev))
                tgt = torch.tensor(text_tokens + [tok.eot], device=dev)
                ce = F.cross_entropy(logits[len(sot) - 1: len(sot) - 1 + len(tgt)], tgt)
                away = -torch.clamp(ce, max=8.0)
                loss = (mute + a.away_weight * away) / (len(models) * len(batch))
                clip_loss = clip_loss + loss
                loss_total += loss.item(); mute_total += mute.item() / (len(models) * len(batch))
                away_total += ce.item() / (len(models) * len(batch))
            clip_loss.backward()
        if delta.grad is None or not torch.isfinite(delta.grad).all():
            print(f"step {step}: non-finite gradient, skipped", flush=True); opt.zero_grad(); continue
        opt.step()
        if step % 10 == 0 or step == 1:
            el = time.time() - t0
            print(f"step {step:4d}  loss {loss_total:+.3f}  mute_ce {mute_total:.3f}  true_ce {away_total:.3f}  {el/step:.1f}s/step", flush=True)
            log.append({"step": step, "loss": loss_total, "mute_ce": mute_total, "true_ce": away_total})
            np.save(a.out, saved(delta, a))
    np.save(a.out, saved(delta, a))
    Path(a.out).with_suffix(".log.json").write_text(json.dumps({"args": vars(a), "log": log}, indent=2))
    print("saved", a.out)

if __name__ == "__main__":
    main()

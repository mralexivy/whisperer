#!/usr/bin/env python3
"""Train a universal "mute burst" for Privacy Shield (clean-room, from public research: "Muting Whisper",
Raina et al. 2024). Unlike train_uap.py, the burst does not sit on top of the voice: it is played in the
pause right before speech starts, so the listener hears a short sound and then clean speech, while a
Whisper-family recogniser decoding that window is pushed to emit end-of-transcript first.

Every step sends burst + gap + speech through REAL Opus (random 16-32 kbps, VoIP) and, half the time,
RNNoise, with a straight-through gradient. The burst's level is relative to the voice RMS (--rel), and
the decoder is attacked in both timestamp and no-timestamp modes.

usage: train_burst.py TRAIN_DIR --out burst.npy [--models small,medium] [--seconds 0.64] [--rel 1.0]
"""
import argparse, json, random, time
from pathlib import Path
import numpy as np, soundfile as sf, torch, torch.nn.functional as F
import torchaudio.functional as AF
import whisper
from whisper.tokenizer import get_tokenizer
from train_uap import log_mel, sim_call

SR = 48000


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("train"); ap.add_argument("--out", required=True)
    ap.add_argument("--models", default="small"); ap.add_argument("--seconds", type=float, default=0.64)
    ap.add_argument("--rel", type=float, default=1.0, help="burst RMS relative to the voice RMS")
    ap.add_argument("--steps", type=int, default=300); ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--lr", type=float, default=0.01); ap.add_argument("--rnnoise", default="")
    ap.add_argument("--max-gap", type=float, default=0.3, help="random silence between burst and speech, s")
    ap.add_argument("--lead", type=float, default=0.0, help="max seconds of other speech before the burst")
    ap.add_argument("--holdout", type=int, default=20, help="last N train clips are never trained on")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--no-codec", action="store_true", help="diagnostic: attack the raw signal, skip Opus+RNNoise")
    a = ap.parse_args()
    torch.manual_seed(a.seed); random.seed(a.seed); np.random.seed(a.seed)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

    rows = [json.loads(l) for l in (Path(a.train) / "train.jsonl").read_text().splitlines() if l.strip()]
    rows = rows[: len(rows) - a.holdout]
    clips = []
    for r in rows:
        x, sr = sf.read(Path(a.train) / r["audio"], dtype="float32"); assert sr == SR
        clips.append((x[: SR * 8], r["reference"]))

    models = [whisper.load_model(m, device=dev) for m in a.models.split(",")]
    for m in models:
        m.eval(); [p.requires_grad_(False) for p in m.parameters()]
    tok = get_tokenizer(multilingual=True, language="en", task="transcribe")
    prompts = [list(tok.sot_sequence_including_notimestamps), list(tok.sot_sequence)]

    L = int(SR * a.seconds)
    b = torch.zeros(L, device=dev, requires_grad=True)
    with torch.no_grad():
        b.normal_(0, 0.5)
    opt = torch.optim.Adam([b], lr=a.lr)
    log, t0 = [], time.time()
    for step in range(1, a.steps + 1):
        opt.zero_grad(); stats = {"mute": 0.0, "p_eot": 0.0}
        for x_np, _text in random.sample(clips, a.batch):
            x = torch.from_numpy(x_np).to(dev) * random.uniform(0.6, 1.4)
            rms = torch.sqrt(torch.mean(x ** 2)) + 1e-6
            burst = torch.tanh(b) * (a.rel * rms * 1.414 / torch.sqrt(torch.mean(torch.tanh(b) ** 2) + 1e-8))
            gap = torch.zeros(int(SR * random.uniform(0.02, a.max_gap)), device=dev)
            parts = [burst, gap, x]
            if a.lead > 0:
                lx = torch.from_numpy(random.choice(clips)[0]).to(dev)
                k = min(len(lx), int(SR * random.uniform(0.0, a.lead)))
                parts = ([lx[-k:]] if k > 0 else []) + parts
            xa = torch.clamp(torch.cat(parts), -1, 1) + 1e-5 * torch.randn(sum(len(p) for p in parts), device=dev)
            x16 = AF.resample(xa, SR, 16000)
            if a.no_codec:
                z = whisper.pad_or_trim(x16)
            else:
                rn = a.rnnoise if a.rnnoise and random.random() < 0.5 else ""
                y = np.nan_to_num(sim_call(xa.detach().cpu().numpy(), random.choice([16, 20, 24, 32]), rn))
                y16 = torch.from_numpy((y + np.random.normal(0, 1e-5, len(y))).astype(np.float32)).to(dev)
                n = min(len(x16), len(y16))
                z = whisper.pad_or_trim(x16[:n] + (y16[:n] - x16[:n]).detach())   # straight-through codec
            clip_loss = 0.0
            for m in models:
                feats = m.encoder(log_mel(z, m.dims.n_mels).unsqueeze(0))
                for sot in prompts:
                    first = m.decoder(torch.tensor([sot], device=dev), feats)[0, -1]
                    mute = F.cross_entropy(first.unsqueeze(0), torch.tensor([tok.eot], device=dev))
                    w = 1.0 / (len(models) * len(prompts) * a.batch)
                    clip_loss = clip_loss + mute * w
                    stats["mute"] += mute.item() * w
                    stats["p_eot"] += torch.softmax(first, -1)[tok.eot].item() * w
            clip_loss.backward()
        if b.grad is None or not torch.isfinite(b.grad).all():
            print(f"step {step}: non-finite gradient, skipped", flush=True); continue
        opt.step()
        if step % 10 == 0 or step == 1:
            print(f"step {step:4d}  mute_ce {stats['mute']:.3f}  p_eot {stats['p_eot']:.3f}  "
                  f"{(time.time() - t0) / step:.1f}s/step", flush=True)
            log.append({"step": step, **stats})
            np.save(a.out, torch.tanh(b).detach().cpu().numpy())
    np.save(a.out, torch.tanh(b).detach().cpu().numpy())
    Path(a.out).with_suffix(".log.json").write_text(json.dumps({"args": vars(a), "log": log}, indent=2))
    print("saved", a.out)


if __name__ == "__main__":
    main()

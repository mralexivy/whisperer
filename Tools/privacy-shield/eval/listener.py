"""Machine listener: torchaudio SQUIM. Reference-free estimates of STOI / PESQ and a MOS (subjective model,
with an unrelated clean reference). Scores 4 s chunks at 16 kHz, averaged.

Calibrated against the author's own verdicts (2026-11-08): recordings judged natural scored STOI 0.97-0.99,
every one judged robotic 0.56-0.62. Use STOI >= 0.9 as the "sounds natural" gate. The MOS head is NOT
usable for this: it rated a robotic file 4.32. usage: listener.py FILE [FILE ...]"""
import sys, glob
import numpy as np, soundfile as sf, torch
from scipy.signal import resample_poly
from torchaudio.pipelines import SQUIM_OBJECTIVE, SQUIM_SUBJECTIVE
obj, subj = SQUIM_OBJECTIVE.get_model().eval(), SQUIM_SUBJECTIVE.get_model().eval()
ref_path = sorted(glob.glob(str(__import__("pathlib").Path(__file__).resolve().parents[3] / "build/privacy-shield/data/LibriSpeech/dev-clean/*/*/*.flac")))[0]
ref, _ = sf.read(ref_path, dtype="float32"); ref = torch.from_numpy(ref[:16000 * 4]).unsqueeze(0)
def load16(p):
    import subprocess
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-ac", "1", "-ar", "16000", "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32)
@torch.no_grad()
def score(p):
    x = load16(p); out = []
    for i in range(0, len(x) - 16000 * 2, 16000 * 4):
        c = torch.from_numpy(x[i: i + 16000 * 4].copy()).unsqueeze(0)
        c = c / (c.abs().max() + 1e-6) * 0.5
        stoi, pesq, sdr = obj(c); mos = subj(c, ref)
        out.append([float(stoi), float(pesq), float(mos)])
    return np.mean(out, 0)
for p in sys.argv[1:]:
    s = score(p); print(f"STOI {s[0]:.2f}  PESQ {s[1]:.2f}  MOS {s[2]:.2f}  {p.split('/')[-1]}", flush=True)

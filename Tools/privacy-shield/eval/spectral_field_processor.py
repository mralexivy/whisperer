"""run_eval.py / jam_eval.py processor: apply a TRAINED spectral field (train_spectral.py .npz) as the
competitor does, Y=(1+g)Xe^{iphi}, 400/160/201 STFT at 16 kHz, looped over the utterance. Perceptually
near-transparent (phase-led); set SHIELD_SPECTRAL=path/to/field.npz, SPEC_STRENGTH scales g and phi (1=as trained)."""
import os
import numpy as np
from scipy.signal import resample_poly

SR = 16000; NFFT = 400; HOP = 160
_d = np.load(os.environ["SHIELD_SPECTRAL"])
_G = _d["gain"].astype(np.float64); _P = _d["phase"].astype(np.float64)
_S = float(os.environ.get("SPEC_STRENGTH", "1"))
_WIN = np.hanning(NFFT + 1)[:-1].astype(np.float64)
_rng = np.random.default_rng(int(os.environ.get("SPEC_SEED", "7")))


def process(x48):
    x = resample_poly(np.asarray(x48, np.float64), SR, 48000)
    pad = NFFT // 2; xp = np.pad(x, pad)
    n = 1 + (len(xp) - NFFT) // HOP
    if n < 1:
        return x48
    off = int(_rng.integers(_G.shape[0]))
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
    X = np.fft.rfft(xp[idx] * _WIN, axis=1)
    fi = (np.arange(n) + off) % _G.shape[0]
    g = _G[fi] * _S; p = _P[fi] * _S
    Y = (1 + g) * X * np.exp(1j * p)
    frames = np.fft.irfft(Y, NFFT, axis=1) * _WIN
    out = np.zeros(len(xp)); norm = np.zeros(len(xp))
    for m in range(n):
        s = m * HOP; out[s:s + NFFT] += frames[m]; norm[s:s + NFFT] += _WIN ** 2
    out = np.divide(out, norm, out=np.zeros_like(out), where=norm > 1e-6)[pad:pad + len(x)]
    return resample_poly(np.clip(out, -1, 1), 48000, SR).astype(np.float32)

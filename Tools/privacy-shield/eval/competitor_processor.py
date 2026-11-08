"""run_eval.py / jam_eval.py processor: faithful recreation of Test App 1.13's RECOVERED shipped config
(user's static analysis, 2026-11-08), to measure the competitor's own method on our bench. No training.

  gain[m,k]  = 0.3 * strength * W(k) * z1[m,k]
  phase[m,k] = 0.1 * strength * W(k) * z2[m,k]        (radians)
  Y[m,k]     = (1 + gain) * X[m,k] * exp(i*phase)

z1,z2: seeded Gaussian fields (frames x 201), SplitMix64 + Box-Muller as recovered. W: stepwise frequency
envelope "0:0.45,1000:1.2,2000:1.6" with bin k = 40k Hz. 400/160/201 STFT at 16 kHz, overlap-add.
COMP_STRENGTH scales both fields (1 = recovered factors). COMP_SMOOTH>0 low-passes the fields in time
(frames) to match a slow drift; 0 = independent per cell. COMP_SEED sets the session seed."""
import os
import numpy as np
from scipy.signal import resample_poly

SR = 16000; NFFT = 400; HOP = 160; BINS = 201
_STR = float(os.environ.get("COMP_STRENGTH", "1"))
_SMOOTH = float(os.environ.get("COMP_SMOOTH", "0"))
_SEED = int(os.environ.get("COMP_SEED", "0x9e3779b9"), 0) if os.environ.get("COMP_SEED", "").startswith("0x") else int(os.environ.get("COMP_SEED", "2654435769"))
_WIN = np.hanning(NFFT + 1)[:-1].astype(np.float64)

_MIX = 0x9E3779B97F4A7C15


def _splitmix_normal(n, seed):
    """n standard-normal values via SplitMix64 + Box-Muller, as recovered from the binary."""
    s = np.uint64(seed); out = np.empty(n, np.float64); i = 0
    def nxt():
        nonlocal s
        s = np.uint64(s + np.uint64(_MIX))
        z = s
        z = np.uint64((z ^ (z >> np.uint64(30))) * np.uint64(0xBF58476D1CE4E5B9))
        z = np.uint64((z ^ (z >> np.uint64(27))) * np.uint64(0x94D049BB133111EB))
        z = z ^ (z >> np.uint64(31))
        return (float(z >> np.uint64(11)) + 0.5) / float(1 << 53)
    with np.errstate(over="ignore"):
        while i < n:
            u1 = max(nxt(), 1e-12); u2 = nxt()
            r = np.sqrt(-2 * np.log(u1))
            out[i] = r * np.cos(2 * np.pi * u2); i += 1
            if i < n:
                out[i] = r * np.sin(2 * np.pi * u2); i += 1
    return out


def _weight():
    pts = [(0, 0.45), (1000, 1.2), (2000, 1.6)]; w = np.empty(BINS)
    for k in range(BINS):
        hz = 40 * k; v = pts[0][1]
        for fhz, fv in pts:
            if hz >= fhz:
                v = fv
        w[k] = v
    return w


def _fields(frames, seed):
    z = _splitmix_normal(frames * BINS * 2, seed).reshape(2, frames, BINS)
    if _SMOOTH > 0:
        from scipy.ndimage import uniform_filter1d
        z = uniform_filter1d(z, size=max(1, int(_SMOOTH)), axis=1, mode="nearest")
    return z[0], z[1]


def process(x48):
    x = resample_poly(np.asarray(x48, np.float64), SR, 48000)
    pad = NFFT // 2; xp = np.pad(x, pad)
    n = 1 + (len(xp) - NFFT) // HOP
    if n < 1:
        return x48
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
    X = np.fft.rfft(xp[idx] * _WIN, axis=1)
    z1, z2 = _fields(n, _SEED); W = _weight()[None, :]
    gain = 0.3 * _STR * W * z1
    phase = 0.1 * _STR * W * z2
    Y = (1 + gain) * X * np.exp(1j * phase)
    frames = np.fft.irfft(Y, NFFT, axis=1) * _WIN
    out = np.zeros(len(xp)); norm = np.zeros(len(xp))
    for m in range(n):
        s = m * HOP; out[s:s + NFFT] += frames[m]; norm[s:s + NFFT] += _WIN ** 2
    out = np.divide(out, norm, out=np.zeros_like(out), where=norm > 1e-6)[pad:pad + len(x)]
    return resample_poly(np.clip(out, -1, 1), 48000, SR).astype(np.float32)

"""run_eval.py / jam_eval.py processor: frequency-domain perturbation like the competitor's
Y[m,k] = (1+g[m,k]) * X[m,k] * exp(i*phi[m,k]), at 16 kHz, 400-sample periodic Hann, 160 hop, 201 bins,
overlap-add normalised by the window-square sum. Reconstructs at 16 kHz, resampled back to 48 kHz.

The ear is largely insensitive to absolute phase, but a recogniser recomputes its magnitude spectrum on
its own frame grid, so phase rotations here become magnitude errors there. This probe uses a random but
frequency-smooth field (no training) to see where the naturalness/ASR trade-off sits.

SPEC_PHASE  max |phi| in radians (default 0.0)
SPEC_GAIN   max |gain| in dB (default 0.0)
SPEC_BANDS  independent random values across frequency, cosine-interpolated (default 24)
SPEC_RATEHZ how fast the field drifts in time, Hz (default 6)
SPEC_HPF    Hz below which phase is left alone, protects low-frequency naturalness (default 300)
SPEC_SEED   (default 7)
"""
import os
import numpy as np
from scipy.signal import resample_poly

SR = 16000; NFFT = 400; HOP = 160; BINS = 201
_PHASE = float(os.environ.get("SPEC_PHASE", "0"))
_GAIN_DB = float(os.environ.get("SPEC_GAIN", "0"))
_BANDS = int(os.environ.get("SPEC_BANDS", "24"))
_RATE = float(os.environ.get("SPEC_RATEHZ", "6"))
_HPF = float(os.environ.get("SPEC_HPF", "300"))
_rng = np.random.default_rng(int(os.environ.get("SPEC_SEED", "7")))
_WIN = np.hanning(NFFT + 1)[:-1].astype(np.float64)


def _field(frames):
    """Smooth random field, (frames, BINS) in [-1,1]: band-limited in frequency and slow in time."""
    tctrl = max(2, int(frames * HOP / SR * _RATE) + 2)
    grid = _rng.standard_normal((tctrl, _BANDS))
    ti = np.linspace(0, tctrl - 1, frames); fi = np.linspace(0, _BANDS - 1, BINS)
    def interp2(g):
        a = np.array([np.interp(ti, np.arange(tctrl), g[:, b]) for b in range(_BANDS)]).T
        return np.array([np.interp(fi, np.arange(_BANDS), a[m]) for m in range(frames)])
    f = interp2(grid); f /= np.abs(f).max() + 1e-9
    f[:, :int(_HPF / SR * NFFT)] = 0.0                       # leave low frequencies clean
    return f


def process(x48):
    x = resample_poly(np.asarray(x48, np.float64), SR, 48000)
    n = (len(x) - NFFT) // HOP + 1
    if n < 1:
        return x48
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
    X = np.fft.rfft(x[idx] * _WIN, axis=1)                   # (n, 201)
    g = (10 ** (_GAIN_DB / 20) - 1) * _field(n)
    phi = _PHASE * _field(n)
    Y = (1 + g) * X * np.exp(1j * phi)
    frames = np.fft.irfft(Y, NFFT, axis=1) * _WIN
    out = np.zeros(len(x)); norm = np.zeros(len(x))
    for m in range(n):
        s = m * HOP; out[s:s + NFFT] += frames[m]; norm[s:s + NFFT] += _WIN ** 2
    out = np.divide(out, norm, out=np.zeros_like(out), where=norm > 1e-6)
    return resample_poly(np.clip(out, -1, 1), 48000, SR).astype(np.float32)

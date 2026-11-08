"""run_eval.py processor: black-box signal transforms that listeners tolerate (from the speech-perception
literature) screened for how much they hurt ASR. No training.

TRANSFORM (env), one of:
  vocode:N         noise-vocoded speech, N log-spaced bands 100-7000 Hz (Shannon et al. 1995)
  revwin:MS        local time reversal in MS-millisecond windows (Saberi & Perrott 1999)
  chop:MS:DUTY     periodic interruption: every MS ms, the last (1-DUTY) is replaced by speech-shaped
                   noise at voice level (phonemic restoration, Warren 1970)
  fshift:HZ        single-sideband frequency shift of the whole spectrum by HZ
"""
import os
import numpy as np
from scipy.signal import butter, sosfiltfilt, hilbert

SR = 48000
_T = os.environ.get("TRANSFORM", "vocode:8").split(":")
_rng = np.random.default_rng(int(os.environ.get("TRANSFORM_SEED", "7")))


def _env(x, cutoff=50):
    sos = butter(2, cutoff, "low", fs=SR, output="sos")
    return np.maximum(sosfiltfilt(sos, np.abs(hilbert(x))), 0)


def vocode(x, n):
    edges = np.geomspace(100, 7000, n + 1); out = np.zeros_like(x)
    noise = _rng.standard_normal(len(x)).astype(np.float32)
    for lo, hi in zip(edges[:-1], edges[1:]):
        sos = butter(4, [lo, hi], "band", fs=SR, output="sos")
        band = sosfiltfilt(sos, x)
        carrier = sosfiltfilt(sos, noise)
        carrier /= np.sqrt(np.mean(carrier ** 2)) + 1e-9
        out += _env(band, 160) * carrier
    return out


def revwin(x, ms):
    w = int(SR * ms / 1000); y = x.copy()
    for i in range(0, len(x), w):
        y[i: i + w] = x[i: i + w][::-1]
    return y


def revola(x, ms, jitter=0.0):
    """Smooth local time reversal: Hann-windowed frames at 50% overlap, each reversed, overlap-added.
    No hard edges (no clicks). jitter randomises each frame length by +-jitter (fraction), so the
    transform cannot be undone by reversing again on a fixed grid."""
    y = np.zeros(len(x) + SR); norm = np.zeros_like(y); i = 0
    while i < len(x):
        w = int(SR * ms / 1000 * (1 + jitter * _rng.uniform(-1, 1))); w += w % 2
        win = np.hanning(w)
        seg = x[i: i + w]
        if len(seg) < w:
            seg = np.pad(seg, (0, w - len(seg)))
        y[i: i + w] += seg[::-1] * win; norm[i: i + w] += win
        i += w // 2
    return (y / np.maximum(norm, 1e-3))[: len(x)]


def revfade(x, ms, fade_ms, reverse=True, jitter=0.0):
    """Local time reversal with only a short crossfade (fade_ms) between frames: keeps each frame's
    reversal sharp but removes the hard step at the boundary. reverse=False gives the same frame grid
    and fades with no reversal (splices only), which isolates the boundary effect. jitter randomises
    each frame length by +-jitter (fraction)."""
    f = max(1, int(SR * fade_ms / 1000))
    y = np.zeros(len(x) + 2 * SR); i = 0
    ramp_in = np.sin(np.linspace(0, np.pi / 2, f)) ** 2
    while i < len(x):
        w = int(SR * ms / 1000 * (1 + jitter * _rng.uniform(-1, 1)))
        seg = x[i: i + w + f]
        if len(seg) < w + f:
            seg = np.pad(seg, (0, w + f - len(seg)))
        seg = seg[::-1].copy() if reverse else seg.copy()
        seg[:f] *= ramp_in; seg[-f:] *= ramp_in[::-1]
        y[i: i + w + f] += seg; i += w
    return y[: len(x)]


def splice(x, ms, jump_ms):
    """Hard splices with no reversal: every ms, jump the read position by +-jump_ms (net drift 0)."""
    w = int(SR * ms / 1000); j = int(SR * jump_ms / 1000); y = np.zeros_like(x); sign = 1
    for i in range(0, len(x), w):
        k = min(max(i + sign * j, 0), len(x) - w); sign = -sign
        n = min(w, len(x) - i); y[i: i + n] = x[k: k + n]
    return y


def chop(x, ms, duty):
    w = int(SR * ms / 1000); keep = int(w * duty); y = x.copy()
    noise = _rng.standard_normal(len(x)).astype(np.float32)
    sos = butter(2, [200, 4000], "band", fs=SR, output="sos"); noise = sosfiltfilt(sos, noise)
    level = _env(x, 10); noise *= level / (np.sqrt(np.mean(noise ** 2)) + 1e-9) * 0.7
    ramp = int(SR * 0.004)
    for i in range(0, len(x), w):
        a, b = i + keep, min(i + w, len(x))
        if a >= b:
            continue
        m = np.ones(b - a, np.float32)
        r = min(ramp, (b - a) // 2)
        if r:
            m[:r] = np.linspace(0, 1, r); m[-r:] = np.linspace(1, 0, r)
        y[a:b] = x[a:b] * (1 - m) + noise[a:b] * m
    return y


def fshift(x, hz):
    a = hilbert(x); t = np.arange(len(x)) / SR
    return np.real(a * np.exp(2j * np.pi * hz * t))


def process(x):
    x = np.asarray(x, dtype=np.float64)
    k = _T[0]
    if k == "vocode": y = vocode(x, int(_T[1]))
    elif k == "revwin": y = revwin(x, float(_T[1]))
    elif k == "revola": y = revola(x, float(_T[1]), float(_T[2]) if len(_T) > 2 else 0.0)
    elif k == "revfade": y = revfade(x, float(_T[1]), float(_T[2]), jitter=float(_T[3]) if len(_T) > 3 else 0.0)
    elif k == "revband":
        # revband:MS:FADE:CUT:hi|lo  reverse only the band above (hi) or below (lo) CUT Hz
        cut = float(_T[3]); hi = butter(6, cut, "high", fs=SR, output="sos"); lo = butter(6, cut, "low", fs=SR, output="sos")
        xh, xl = sosfiltfilt(hi, x), sosfiltfilt(lo, x)
        y = revfade(xh, float(_T[1]), float(_T[2])) + xl if _T[4] == "hi" else revfade(xl, float(_T[1]), float(_T[2])) + xh
    elif k == "gridfade": y = revfade(x, float(_T[1]), float(_T[2]), reverse=False)
    elif k == "splice": y = splice(x, float(_T[1]), float(_T[2]))
    elif k == "chop": y = chop(x, float(_T[1]), float(_T[2]))
    elif k == "fshift": y = fshift(x, float(_T[1]))
    else: raise SystemExit(f"unknown TRANSFORM {k}")
    y *= np.sqrt(np.mean(x ** 2)) / (np.sqrt(np.mean(y ** 2)) + 1e-9)
    return np.clip(y, -0.98, 0.98).astype(np.float32)

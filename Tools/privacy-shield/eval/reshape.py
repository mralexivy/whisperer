"""Real-time voice reshaper (reference): a two-tap delay-line pitch shifter.

Two read heads sweep a short delay line at rate (1 - ratio) and are crossfaded with a raised-cosine
so one is always away from its wrap point. Shifting pitch this way also moves the formants, which is
what speaker-recognition systems key on, while the words stay intelligible. Causal, no lookahead;
latency is at most one grain (`grain_ms`). The C++ processor implements the same arithmetic.
"""
import numpy as np

def reshape(x, ratio=1.15, sr=48000, grain_ms=40.0):
    g = int(sr * grain_ms / 1000)               # grain length in samples
    n = len(x); y = np.zeros(n, dtype=np.float32)
    buf = np.zeros(2 * g + 4, dtype=np.float32); L = len(buf)
    phase = 0.0                                  # 0..1, position of head A inside the grain
    step = (1.0 - ratio) / g                     # how fast the delay changes per sample
    w = 0
    for i in range(n):
        buf[w] = x[i]
        out = 0.0
        for k in (0.0, 0.5):
            p = (phase + k) % 1.0
            d = p * g + 1.0                      # delay in samples, 1..g+1
            r = w - d
            r0 = int(np.floor(r)); f = r - r0
            a = buf[r0 % L]; b = buf[(r0 + 1) % L]
            out += (a + f * (b - a)) * (0.5 - 0.5 * np.cos(2 * np.pi * p))
        y[i] = out
        phase = (phase + step) % 1.0
        w = (w + 1) % L
    return y


def reshape_fast(x, ratio=1.15, sr=48000, grain_ms=40.0):
    """Vectorized, sample-identical form of `reshape` (the head positions depend only on time)."""
    g = int(sr * grain_ms / 1000); n = len(x)
    xp = np.concatenate([np.zeros(g + 2, dtype=np.float32), np.asarray(x, dtype=np.float32)])
    i = np.arange(n, dtype=np.float64)
    base = np.mod(i * ((1.0 - ratio) / g), 1.0)
    y = np.zeros(n, dtype=np.float64)
    for k in (0.0, 0.5):
        p = np.mod(base + k, 1.0)
        r = i - (p * g + 1.0) + (g + 2)
        r0 = np.floor(r).astype(np.int64); f = r - r0
        y += (xp[r0] + f * (xp[r0 + 1] - xp[r0])) * (0.5 - 0.5 * np.cos(2 * np.pi * p))
    return y.astype(np.float32)

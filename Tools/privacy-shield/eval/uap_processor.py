"""run_eval.py processor: loop a trained universal perturbation over the signal, exactly as the
real-time pipeline would (fixed buffer, arbitrary start phase). Set SHIELD_UAP=path/to/delta.npy."""
import os
import numpy as np

_DELTA = np.load(os.environ["SHIELD_UAP"]).astype(np.float32)
_SCALE = float(os.environ.get("SHIELD_UAP_SCALE", "1.0"))
_REL = float(os.environ.get("SHIELD_UAP_RELATIVE", "0"))
_rng = np.random.default_rng(int(os.environ.get("SHIELD_UAP_SEED", "7")))


def _envelope(x, ms=20):
    w = int(48000 * ms / 1000)
    c = np.concatenate([np.zeros(w - 1, np.float32), x.astype(np.float32) ** 2])
    s = np.cumsum(c, dtype=np.float64)
    m = (s[w - 1:] - np.concatenate([[0.0], s[:-w]])) / w
    return np.sqrt(m + 1e-8).astype(np.float32) * 1.414


def process(x):
    x = np.asarray(x, dtype=np.float32)
    off = int(_rng.integers(len(_DELTA)))
    reps = (len(x) + off) // len(_DELTA) + 1
    d = np.tile(_DELTA, reps)[off: off + len(x)] * _SCALE
    if _REL > 0:
        d = d * _REL * _envelope(x)
    return np.clip(x + d, -1.0, 1.0)

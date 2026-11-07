"""run_eval.py processor: loop a trained universal perturbation over the signal, exactly as the
real-time pipeline would (fixed buffer, arbitrary start phase). Set SHIELD_UAP=path/to/delta.npy."""
import os
import numpy as np

_DELTA = np.load(os.environ["SHIELD_UAP"]).astype(np.float32)
_SCALE = float(os.environ.get("SHIELD_UAP_SCALE", "1.0"))
_rng = np.random.default_rng(int(os.environ.get("SHIELD_UAP_SEED", "7")))


def process(x):
    x = np.asarray(x, dtype=np.float32)
    off = int(_rng.integers(len(_DELTA)))
    reps = (len(x) + off) // len(_DELTA) + 1
    d = np.tile(_DELTA, reps)[off: off + len(x)] * _SCALE
    return np.clip(x + d, -1.0, 1.0)

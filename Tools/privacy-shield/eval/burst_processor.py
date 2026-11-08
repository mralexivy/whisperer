"""run_eval.py processor: play a trained mute burst (train_burst.py) in the pause before the utterance,
then a short gap, then the untouched voice. Set SHIELD_BURST=path/to/burst.npy.

SHIELD_BURST_REL  burst RMS relative to the voice RMS (default 1.0, match training)
SHIELD_BURST_GAP  silence between burst and speech, seconds (default 0.15)
SHIELD_BURST_EVERY  if >0, also overlay the burst every N seconds inside the utterance (default 0)
"""
import os
import numpy as np

_B = np.load(os.environ["SHIELD_BURST"]).astype(np.float32)
_REL = float(os.environ.get("SHIELD_BURST_REL", "1.0"))
_GAP = float(os.environ.get("SHIELD_BURST_GAP", "0.15"))
_EVERY = float(os.environ.get("SHIELD_BURST_EVERY", "0"))


def process(x):
    x = np.asarray(x, dtype=np.float32)
    rms = float(np.sqrt(np.mean(x ** 2)) + 1e-6)
    b = _B / (np.sqrt(np.mean(_B ** 2)) + 1e-8) * _REL * rms * 1.414
    y = x.copy()
    if _EVERY > 0:
        step = int(48000 * _EVERY)
        for i in range(step, len(y) - len(b), step):
            y[i: i + len(b)] += b
    return np.clip(np.concatenate([b, np.zeros(int(48000 * _GAP), np.float32), y]), -0.98, 0.98)

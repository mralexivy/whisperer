"""run_eval.py / jam_eval.py processor: mild local time reversal only (MILD_MS, default 45 ms, +-20%,
3 ms crossfades): the base the hybrid jammer's learned signal is trained on."""
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import numpy as np
from transform_processor import revfade

MS = float(os.environ.get("MILD_MS", "45"))


def process(x):
    return revfade(np.asarray(x, np.float64), MS, 3.0, jitter=0.2).astype(np.float32)

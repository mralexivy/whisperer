"""run_eval.py processor: overlap-decoy jamming. Mixes a quieter competing speech stream under the
voice. Listeners follow the louder talker; ASR has no reliable way to pick one stream and tends to
merge or switch between them. Black-box, no training.

Env:
  DECOY_KIND   other | babble | reverse | self   (default other)
  DECOY_DB     decoy level relative to the voice, dB (default -6)
  DECOY_TALKERS  talkers mixed for babble (default 3)
  DECOY_SHIFT  pitch ratio applied to the decoy (default 1.0; self uses 0.8 when unset)
  DECOY_LIBRI  LibriSpeech dir supplying decoy speech
  DECOY_SEED   (default 7)
"""
import os
from pathlib import Path
import numpy as np, soundfile as sf
from scipy.signal import resample_poly

_KIND = os.environ.get("DECOY_KIND", "other")
_DB = float(os.environ.get("DECOY_DB", "-6"))
_TALKERS = int(os.environ.get("DECOY_TALKERS", "3"))
_SHIFT = float(os.environ.get("DECOY_SHIFT", "0.8" if _KIND == "self" else "1.0"))
_LIBRI = Path(os.environ.get("DECOY_LIBRI", str(Path(__file__).resolve().parents[3] / "build/privacy-shield/data/LibriSpeech/dev-clean")))
_rng = np.random.default_rng(int(os.environ.get("DECOY_SEED", "7")))
_POOL = None


def _pool():
    global _POOL
    if _POOL is None:
        _POOL = sorted(_LIBRI.rglob("*.flac"))
    return _POOL


def _speech(n):
    """n samples of 48 kHz decoy speech from one random speaker, with leading/trailing silence trimmed."""
    out = np.zeros(0, np.float32)
    while len(out) < n:
        x, sr = sf.read(_pool()[_rng.integers(len(_pool()))], dtype="float32")
        x = resample_poly(x, 48000, sr).astype(np.float32)
        e = np.abs(x) > 0.02 * np.abs(x).max()
        if e.any():
            idx = np.flatnonzero(e); x = x[idx[0]: idx[-1] + 1]
        out = np.concatenate([out, x])
    off = int(_rng.integers(max(1, len(out) - n + 1)))
    return out[off: off + n]


def _pitch(x, ratio):
    """Pitch shift by resampling, then restore duration by repeating/dropping 30 ms grains (overlap-add)."""
    if abs(ratio - 1.0) < 1e-3:
        return x
    y = resample_poly(x, 1000, int(round(1000 * ratio))).astype(np.float32)
    g = 1440; hop = g // 2; win = np.hanning(g).astype(np.float32)
    out = np.zeros(len(x) + g, np.float32); norm = np.zeros_like(out)
    for o in range(0, len(x), hop):
        i = int(o * len(y) / len(x))
        seg = y[i: i + g]
        if len(seg) < g:
            seg = np.pad(seg, (0, g - len(seg)))
        out[o: o + g] += seg * win; norm[o: o + g] += win
    return (out / np.maximum(norm, 1e-3))[: len(x)]


def _rms(x):
    return float(np.sqrt(np.mean(x ** 2)) + 1e-9)


def decoy(x):
    n = len(x)
    if _KIND == "other":
        d = _speech(n)
    elif _KIND == "babble":
        d = sum(s / _rms(s) for s in (_speech(n) for _ in range(_TALKERS)))
    elif _KIND == "reverse":
        d = _speech(n)[::-1].copy()
    elif _KIND == "self":
        lag = int(48000 * 0.35)
        d = np.concatenate([np.zeros(lag, np.float32), x[: n - lag]])
    else:
        raise SystemExit(f"unknown DECOY_KIND {_KIND}")
    return _pitch(d.astype(np.float32), _SHIFT)


def process(x):
    x = np.asarray(x, dtype=np.float32)
    d = decoy(x)
    d *= _rms(x) / _rms(d) * 10 ** (_DB / 20)
    return np.clip(x + d, -1.0, 1.0)

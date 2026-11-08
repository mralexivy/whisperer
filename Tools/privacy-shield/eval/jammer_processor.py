"""run_eval.py processor: the shipped native jammer (libShieldBenchmark.dylib), exactly as the audio worker
runs it (480-sample blocks), with its fixed latency trimmed so output aligns with the input.
JAM_FRAME_MS (70), JAM_FADE_MS (3), JAM_JITTER (0.2), JAM_STRENGTH (1)."""
import os, sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ctypes
from test_jammer_native import LIB, native

_lib = ctypes.CDLL(str(LIB)); F = ctypes.POINTER(ctypes.c_float)
_lib.shield_jammer_create.restype = ctypes.c_void_p
_lib.shield_jammer_create.argtypes = [ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_uint32]
_lib.shield_jammer_process.argtypes = [ctypes.c_void_p, F, F, ctypes.c_uint32, ctypes.c_float]
_lib.shield_jammer_latency.argtypes = [ctypes.c_void_p]; _lib.shield_jammer_latency.restype = ctypes.c_uint32
_lib.shield_jammer_destroy.argtypes = [ctypes.c_void_p]
_ARGS = (float(os.environ.get("JAM_FRAME_MS", "70")), float(os.environ.get("JAM_FADE_MS", "3")),
         float(os.environ.get("JAM_JITTER", "0.2")), float(os.environ.get("JAM_STRENGTH", "1")))


def process(x):
    x = np.concatenate([np.asarray(x, np.float32), np.zeros(48000 // 5, np.float32)])
    y, lat = native(_lib, x, *_ARGS[:3], strength=_ARGS[3])
    return y[lat: lat + len(x) - 48000 // 5]

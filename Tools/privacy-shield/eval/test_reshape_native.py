#!/usr/bin/env python3
"""Native reshaper == reshape.py. Exports a network with its head zeroed (no perturbation) and a reshape
ratio, runs the shipped C++ processor, and compares with the Python reference at 48 kHz.
usage: test_reshape_native.py CHECKPOINT.pt LIBRARY.dylib"""
import ctypes, sys, tempfile
from pathlib import Path
import numpy as np, torch
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pnet import PerturbNet, export_weights  # noqa: E402
from reshape import reshape_fast  # noqa: E402

ck = torch.load(sys.argv[1], map_location="cpu")
net = PerturbNet(relative=ck["args"].get("relative", 0.3)); net.load_state_dict(ck["model"])
with torch.no_grad():
    net.head.weight.zero_(); net.head.bias.zero_()
lib = ctypes.CDLL(sys.argv[2])
lib.shield_pnet_create.restype = ctypes.c_void_p; lib.shield_pnet_create.argtypes = [ctypes.c_char_p]
lib.shield_pnet_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_uint32, ctypes.c_float]
lib.shield_pnet_destroy.argtypes = [ctypes.c_void_p]
rng = np.random.default_rng(1)
t = np.arange(48000 * 2) / 48000
x = (0.3 * np.sin(2 * np.pi * 180 * t) * (1 + 0.5 * np.sin(2 * np.pi * 3 * t)) + 0.05 * rng.standard_normal(len(t))).astype(np.float32)
worst = 0.0
for ratio in (1.15, 0.87):
    with tempfile.TemporaryDirectory() as d:
        w = Path(d) / "r.wspn"; export_weights(net, w, reshape=ratio)
        p = lib.shield_pnet_create(str(w).encode()); assert p, "weights rejected"
        y = np.zeros_like(x)
        for i in range(0, len(x), 480):
            a = (ctypes.c_float * 480)(*x[i:i + 480]); b = (ctypes.c_float * 480)()
            lib.shield_pnet_process(p, a, b, 480, 1.0); y[i:i + 480] = np.frombuffer(b, np.float32)
        lib.shield_pnet_destroy(p)
    ref = np.clip(reshape_fast(x, ratio, 48000), -0.98, 0.98)
    err = float(np.abs(y - ref).max()); worst = max(worst, err)
    print(f"ratio {ratio}: max |native - reference| = {err:.2e}")
assert worst < 1e-4, "native reshaper diverges from reshape.py"
print("OK")

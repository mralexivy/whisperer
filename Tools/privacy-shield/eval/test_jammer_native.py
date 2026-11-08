"""The native streaming jammer (libShieldBenchmark.dylib) must equal transform_processor.revfade, delayed by
its reported latency, for any block size; strength 0 must be the equally delayed dry signal, and
jittered output must stay finite and bounded. Run: test_jammer_native.py"""
import ctypes, sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent))
from transform_processor import revfade

LIB = Path(__file__).resolve().parents[3] / "build/privacy-shield/libShieldBenchmark.dylib"
F = ctypes.POINTER(ctypes.c_float)


def native(lib, x, frame_ms, fade_ms, jitter, strength=1.0, block=480):
    p = lib.shield_jammer_create(frame_ms, fade_ms, jitter, 7)
    assert p, "create failed"
    lat = lib.shield_jammer_latency(p); y = np.zeros_like(x)
    for i in range(0, len(x), block):
        a = np.ascontiguousarray(x[i: i + block]); b = np.zeros_like(a)
        lib.shield_jammer_process(p, a.ctypes.data_as(F), b.ctypes.data_as(F), len(a), strength)
        y[i: i + block] = b
    lib.shield_jammer_destroy(p)
    return y, lat


def main():
    lib = ctypes.CDLL(str(LIB))
    lib.shield_jammer_create.restype = ctypes.c_void_p
    lib.shield_jammer_create.argtypes = [ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_uint32]
    lib.shield_jammer_process.argtypes = [ctypes.c_void_p, F, F, ctypes.c_uint32, ctypes.c_float]
    lib.shield_jammer_latency.argtypes = [ctypes.c_void_p]; lib.shield_jammer_latency.restype = ctypes.c_uint32
    lib.shield_jammer_destroy.argtypes = [ctypes.c_void_p]
    rng = np.random.default_rng(0)
    x = (rng.standard_normal(48000 * 3) * 0.2).astype(np.float32)
    for block in (480, 128, 1000):
        y, lat = native(lib, x, 70.0, 3.0, 0.0, block=block)
        ref = revfade(x.astype(np.float64), 70.0, 3.0)
        n = len(x) - lat - 48000 // 10            # the tail is still inside the native look-ahead
        err = np.max(np.abs(y[lat: lat + n] - ref[:n]))
        assert err < 1e-5, f"block {block}: native differs from reference by {err}"
    assert lat == int(48000 * 0.070) + int(48000 * 0.003), lat
    dry, lat = native(lib, x, 70.0, 3.0, 0.2, strength=0.0)
    assert np.max(np.abs(dry[lat:] - x[: len(x) - lat])) < 1e-7, "strength 0 must be the delayed dry voice"
    j, _ = native(lib, x, 70.0, 3.0, 0.2)
    assert np.all(np.isfinite(j)) and np.max(np.abs(j)) < 2.0
    assert not lib.shield_jammer_create(5.0, 3.0, 0.0, 1), "out-of-range frame must be rejected"
    print("ok")


if __name__ == "__main__":
    main()

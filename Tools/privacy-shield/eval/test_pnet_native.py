"""The native C++ PNet (libShieldBenchmark.dylib) must equal the PyTorch reference, including the
native 48<->16 kHz FIR resampling. Run: test_pnet_native.py [weights.wspn or checkpoint.pt]"""
import ctypes, sys, tempfile
from pathlib import Path
import numpy as np, torch
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pnet import PerturbNet, export_weights, HOP

LIB = Path(__file__).resolve().parents[3] / "build/privacy-shield/libShieldBenchmark.dylib"
TAPS = 48

def lowpass():
    k = np.arange(TAPS); t = k - (TAPS - 1) / 2; fc = 7200 / 48000
    s = np.where(t == 0, 2 * fc, np.sin(2 * np.pi * fc * t) / (np.pi * np.where(t == 0, 1, t)))
    w = 0.42 - 0.5 * np.cos(2 * np.pi * k / (TAPS - 1)) + 0.08 * np.cos(4 * np.pi * k / (TAPS - 1))
    h = (s * w).astype(np.float32); return h / h.sum()

def reference(net, x48):
    """What the native code computes, in numpy/PyTorch."""
    h = lowpass()
    def fir(sig):  # causal, newest sample last; native ring computes sum lp[k]*line[oldest..newest]
        pad = np.concatenate([np.zeros(TAPS - 1, np.float32), sig])
        return np.array([np.dot(h, pad[i:i + TAPS]) for i in range(len(sig))], np.float32)
    x16 = fir(x48)[2::3]                                  # decimate: keep every third filtered sample
    d16 = net.stream(torch.from_numpy(x16)).numpy()
    stuffed = np.zeros(len(x48), np.float32); stuffed[0::3] = d16[: len(x48) // 3] * 3
    return np.clip(x48 + fir(stuffed), -.98, .98)

def main():
    torch.manual_seed(1)
    env = __import__("os").environ
    net = PerturbNet(max_amp=0.05, relative=float(env.get("PNET_RELATIVE", "0")), ahead=int(env.get("PNET_AHEAD", "0")))
    if len(sys.argv) > 1 and sys.argv[1].endswith(".pt"):
        ck = torch.load(sys.argv[1], map_location="cpu")
        net = PerturbNet(max_amp=ck["args"].get("max_amp", 0.05), relative=ck["args"].get("relative", 0.0), ahead=ck["args"].get("ahead", 0)); net.load_state_dict(ck["model"])
    net.eval()
    wspn = Path(tempfile.mkdtemp()) / "w.wspn"; export_weights(net, wspn)
    lib = ctypes.CDLL(str(LIB))
    lib.shield_pnet_create.restype = ctypes.c_void_p; lib.shield_pnet_create.argtypes = [ctypes.c_char_p]
    lib.shield_pnet_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_uint32, ctypes.c_float]
    p = lib.shield_pnet_create(str(wspn).encode()); assert p, "native load failed"
    rng = np.random.default_rng(0)
    t = np.arange(48000 * 2) / 48000
    x = (0.3 * np.sin(2 * np.pi * 220 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 3 * t)) + 0.02 * rng.standard_normal(len(t))).astype(np.float32)
    out = np.zeros_like(x)
    for i in range(0, len(x), 480):
        a = (ctypes.c_float * 480)(*x[i:i + 480]); b = (ctypes.c_float * 480)()
        lib.shield_pnet_process(p, a, b, 480, 1.0); out[i:i + 480] = np.frombuffer(b, np.float32)
    ref = reference(net, x)
    err = np.abs(out - ref).max(); pert = np.abs(ref - np.clip(x, -.98, .98)).max()
    print(f"max |native - reference| = {err:.2e}   (perturbation peak {pert:.3e})")
    assert err < 1e-4, "native PNet diverges from the reference"
    print("ok")

if __name__ == "__main__":
    main()

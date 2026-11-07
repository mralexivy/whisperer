"""run_eval.py processor for the predictive network: 48 kHz in -> 16 kHz analysis -> causal delta ->
48 kHz, added to the original. Batch inference is identical to streaming (test_pnet.py).
Set SHIELD_PNET=path/to/checkpoint.pt."""
import os, sys
from pathlib import Path
import numpy as np, torch, torchaudio.functional as AF
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pnet import PerturbNet, HOP

_ck = torch.load(os.environ["SHIELD_PNET"], map_location="cpu")
_net = PerturbNet(max_amp=_ck["args"].get("max_amp", 0.05), relative=_ck["args"].get("relative", 0.0)); _net.load_state_dict(_ck["model"]); _net.eval()

def process(x):
    x = torch.from_numpy(np.asarray(x, dtype=np.float32))
    x16 = AF.resample(x, 48000, 16000); n = len(x16) // HOP * HOP
    with torch.no_grad():
        d16 = _net(x16[:n].view(1, -1))[0]
    d48 = AF.resample(d16, 16000, 48000)
    y = x.clone(); m = min(len(y), len(d48)); y[:m] += d48[:m]
    return np.clip(y.numpy(), -1, 1)

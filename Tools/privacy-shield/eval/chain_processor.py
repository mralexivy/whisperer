"""run_eval.py processor: the app's full shipped chain, native: bundled identity network (strength 1), then the
jammer, both in 480-sample blocks exactly as PrivacyAudioProcessor runs them, latency trimmed."""
import ctypes, sys, tempfile
from pathlib import Path
import numpy as np, soundfile as sf
sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_eval import native_pnet
from test_jammer_native import LIB
import jammer_processor

WEIGHTS = Path(__file__).resolve().parents[3] / "Whisperer/Resources/Models/ShieldPerturbation.wspn"


def process(x):
    with tempfile.TemporaryDirectory() as d:
        src, dst = Path(d) / "in.wav", Path(d) / "out.wav"
        sf.write(src, np.asarray(x, np.float32), 48000, subtype="FLOAT")
        native_pnet(src, dst, LIB, WEIGHTS, 1.0)
        y, _ = sf.read(dst, dtype="float32")
    return jammer_processor.process(y)

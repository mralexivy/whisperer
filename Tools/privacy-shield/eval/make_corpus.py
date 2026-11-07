#!/usr/bin/env python3
"""Synthetic, consent-free evaluation corpus for Privacy Shield.

Generates spoken meeting lines with Kokoro (Apache-2.0 TTS, local) in several voices,
writes 48 kHz mono PCM16 WAVs and a JSONL manifest with reference text and key facts.
Synthetic speech is a first gate only; real recorded speech must follow.

usage: make_corpus.py OUT_DIR --kokoro-dir DIR_WITH(kokoro-v1.0.onnx, voices-v1.0.bin)
Run with a Python that has kokoro_onnx, soundfile, numpy, scipy.
"""
import argparse, json
from pathlib import Path
import numpy as np, soundfile as sf
from scipy.signal import resample_poly

LINES = [
    ("f1-a", "af_heart", "en-us", "female", "The budget for the Berlin launch is forty two thousand dollars, approved by Sarah on Tuesday.", ["berlin", "forty two thousand", "sarah"]),
    ("f1-b", "af_heart", "en-us", "female", "Please send the signed contract to Marcus before Friday at three.", ["contract", "marcus", "friday"]),
    ("f2-a", "af_bella", "en-us", "female", "Our churn dropped to four percent after we fixed the onboarding email.", ["churn", "four percent", "onboarding"]),
    ("f2-b", "af_bella", "en-us", "female", "The Northwind renewal is worth one point two million over three years.", ["northwind", "renewal", "three years"]),
    ("f3-a", "bf_emma", "en-gb", "female", "I'll move the board meeting to the ninth of December in London.", ["board meeting", "december", "london"]),
    ("f3-b", "bf_emma", "en-gb", "female", "The password for the staging server is changing on Monday morning.", ["password", "staging server", "monday"]),
    ("m1-a", "am_michael", "en-us", "male", "We are hiring two engineers in Austin and one designer in Lisbon.", ["two engineers", "austin", "lisbon"]),
    ("m1-b", "am_michael", "en-us", "male", "The acquisition closes on March fifteenth if legal signs off.", ["acquisition", "march", "legal"]),
    ("m2-a", "am_adam", "en-us", "male", "Ship version two point four to beta testers this afternoon.", ["version two point four", "beta testers", "afternoon"]),
    ("m2-b", "am_adam", "en-us", "male", "Daniel owns the pricing page and the launch checklist.", ["daniel", "pricing page", "checklist"]),
    ("m3-a", "bm_george", "en-gb", "male", "Our runway is eighteen months at the current burn rate.", ["runway", "eighteen months", "burn rate"]),
    ("m3-b", "bm_george", "en-gb", "male", "Call Priya about the security audit before the investor update.", ["priya", "security audit", "investor"]),
]

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("out"); ap.add_argument("--kokoro-dir", required=True)
    a = ap.parse_args()
    from kokoro_onnx import Kokoro
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    k = Kokoro(str(Path(a.kokoro_dir) / "kokoro-v1.0.onnx"), str(Path(a.kokoro_dir) / "voices-v1.0.bin"))
    rows = []
    for uid, voice, lang, sex, text, facts in LINES:
        audio, sr = k.create(text, voice=voice, speed=1.0, lang=lang)
        audio = resample_poly(np.asarray(audio, dtype=np.float64), 48000, sr)  # 24 kHz -> 48 kHz
        audio = 0.5 * audio / max(1e-9, np.max(np.abs(audio)))
        name = f"{uid}.wav"
        sf.write(out / name, audio.astype(np.float32), 48000, subtype="PCM_16")
        rows.append({"id": uid, "speaker": voice, "sex": sex, "language": "en", "reference": text, "key_facts": facts, "clean_audio": name})
        print(uid, voice, round(len(audio) / 48000, 2), "s", flush=True)
    with open(out / "corpus.jsonl", "w") as f:
        for r in rows: f.write(json.dumps(r) + "\n")

if __name__ == "__main__":
    main()

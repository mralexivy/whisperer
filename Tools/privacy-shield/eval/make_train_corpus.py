#!/usr/bin/env python3
"""Training corpus for adversarial Privacy Shield experiments: varied meeting sentences in
voices DISJOINT from make_corpus.py's evaluation voices. 48 kHz mono PCM16 + JSONL.
usage: make_train_corpus.py OUT_DIR --kokoro-dir DIR [--count 200] [--seed 1]"""
import argparse, json, random
from pathlib import Path
import numpy as np, soundfile as sf
from scipy.signal import resample_poly

VOICES = [("af_nicole", "en-us"), ("af_sarah", "en-us"), ("af_sky", "en-us"), ("bf_isabella", "en-gb"),
          ("am_eric", "en-us"), ("am_liam", "en-us"), ("am_onyx", "en-us"), ("bm_lewis", "en-gb")]
NAMES = ["Alex", "Jordan", "Nina", "Omar", "Lena", "Victor", "Hana", "Rafael", "Grace", "Tomas", "Ivy", "Kenji"]
PLACES = ["Toronto", "Madrid", "Seoul", "Chicago", "Dublin", "Nairobi", "Oslo", "Denver", "Milan", "Sydney"]
THINGS = ["the roadmap", "the invoice", "the hiring plan", "the dashboard", "the vendor contract", "the API",
          "the release notes", "the budget review", "the customer survey", "the security review"]
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "next week", "tomorrow morning", "end of the month"]
NUMS = ["three", "twelve", "twenty five", "forty", "ninety", "two hundred", "fifteen percent", "one point five million"]
TEMPLATES = [
    "{n} will send {t} to the team by {d}.", "We need {num} more people in {p} before {d}.",
    "Can you ask {n} to review {t} before {d}?", "The numbers for {p} came in at {num} this quarter.",
    "Let's push {t} to {d} and tell {n} today.", "I spoke with {n} and the deal in {p} is still open.",
    "{t} is blocked until {n} signs off.", "Our target for {p} is {num} by {d}.",
    "Please don't share {t} outside this call.", "{n} thinks we can cut costs by {num} if we move to {p}.",
    "The meeting with {n} in {p} moved to {d}.", "We agreed to freeze {t} until {d}.",
]

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("out"); ap.add_argument("--kokoro-dir", required=True)
    ap.add_argument("--count", type=int, default=200); ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    from kokoro_onnx import Kokoro
    rng = random.Random(a.seed)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    k = Kokoro(str(Path(a.kokoro_dir) / "kokoro-v1.0.onnx"), str(Path(a.kokoro_dir) / "voices-v1.0.bin"))
    with open(out / "train.jsonl", "w") as f:
        for i in range(a.count):
            text = rng.choice(TEMPLATES).format(n=rng.choice(NAMES), p=rng.choice(PLACES), t=rng.choice(THINGS),
                                                d=rng.choice(DAYS), num=rng.choice(NUMS))
            voice, lang = VOICES[i % len(VOICES)]
            audio, sr = k.create(text, voice=voice, speed=rng.uniform(0.9, 1.15), lang=lang)
            audio = resample_poly(np.asarray(audio, dtype=np.float64), 48000, sr)
            audio = rng.uniform(0.3, 0.6) * audio / max(1e-9, np.max(np.abs(audio)))
            name = f"t{i:04d}.wav"; sf.write(out / name, audio.astype(np.float32), 48000, subtype="PCM_16")
            f.write(json.dumps({"id": name[:-4], "speaker": voice, "reference": text, "audio": name}) + "\n")
    print("wrote", a.count)

if __name__ == "__main__":
    main()

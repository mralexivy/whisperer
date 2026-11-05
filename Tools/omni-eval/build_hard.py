#!/usr/bin/env python3
"""Hard test sets built from the FLEURS clips + references already in manifests/.
  noisy    30 clips/lang x 3 degradations (babble 10 dB, room reverb + pink 10 dB, laptop mic 5 dB)
  meeting  ~6 min streams: per-lang x2 plus one mixed he/ru/en; level changes, gaps, 12% overlap,
           reverb + room noise; cut into <=25 s chunks at quiet points (identical for every engine).
Outputs: corpus/hard/**.wav, manifests_hard/noisy.jsonl, manifests_hard/meeting_chunks.jsonl,
         manifests_hard/meetings.json.  Deterministic (seeded per id)."""
import json, os, subprocess, wave, zlib
import numpy as np
here = os.path.dirname(os.path.abspath(__file__))
SR = 16000
OUT = os.path.join(here, "corpus", "hard"); MAN = os.path.join(here, "manifests_hard")
for d in (os.path.join(OUT, "noisy"), os.path.join(OUT, "meeting"), MAN): os.makedirs(d, exist_ok=True)

def load(p):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)
def save(p, x):
    x = x / max(1.0, np.max(np.abs(x)) / 0.95)
    w = wave.open(p, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((x * 32767).astype("<i2").tobytes()); w.close()
def rms(x): return float(np.sqrt(np.mean(x ** 2) + 1e-12))
def rng_for(s): return np.random.default_rng(zlib.crc32(s.encode()))
def add_at_snr(sig, noise, snr_db):
    return sig + noise * (rms(sig) / (rms(noise) * 10 ** (snr_db / 20)))
def pink(n, rng):
    F = np.fft.rfft(rng.standard_normal(n)); f = np.arange(len(F), dtype=float); f[0] = 1
    return np.fft.irfft(F / np.sqrt(f), n)
def reverb(x, rt60, rng):
    n = int(SR * rt60 * 1.2); t = np.arange(n) / SR
    ir = 0.25 * rng.standard_normal(n) * np.exp(-6.9 * t / rt60); ir[0] += 1.0
    N = 1 << int(np.ceil(np.log2(len(x) + n)))
    y = np.fft.irfft(np.fft.rfft(x, N) * np.fft.rfft(ir, N), N)[:len(x)]
    return y * (rms(x) / rms(y))
def bandpass(x, lo, hi):
    F = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1 / SR); F[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(F, len(x))
def fit(x, n):
    return np.tile(x, int(np.ceil(n / len(x))))[:n] if len(x) < n else x[:n]

def read_manifest(lang):
    return [json.loads(l) for l in open(os.path.join(here, "manifests", f"{lang}.jsonl"), encoding="utf-8")]
M = {l: read_manifest(l) for l in ("he", "ru", "en")}

# ---------------- noisy ----------------
noisy = []
for lang, clips in M.items():
    pool = clips[30:]
    for c in clips[:30]:
        x = load(c["audio"])
        for cond in ("babble10", "room_pink10", "laptop5"):
            rid = f'{c["id"]}-{cond}'; rng = rng_for(rid)
            if cond == "babble10":
                others = [pool[i] for i in rng.choice(len(pool), 3, replace=False)]
                bab = sum(fit(load(o["audio"]), len(x)) for o in others)
                y = add_at_snr(x, bab, 10)
            elif cond == "room_pink10":
                y = add_at_snr(reverb(x, 0.6, rng), pink(len(x), rng), 10)
            else:
                n = pink(len(x), rng)
                for _ in range(max(1, int(len(x) / SR * 0.6))):  # keyboard clicks
                    s = rng.integers(0, max(1, len(x) - 400)); n[s:s + 240] += 4 * rng.standard_normal(len(n[s:s + 240])) * np.exp(-np.arange(len(n[s:s + 240])) / 50)
                y = add_at_snr(bandpass(x, 150, 5500), n, 5)
            p = os.path.join(OUT, "noisy", rid + ".wav"); save(p, y)
            noisy.append({"id": rid, "base": c["id"], "lang": lang, "cond": cond, "audio": p, "ref": c["ref"], "seconds": round(len(y) / SR, 2)})
with open(os.path.join(MAN, "noisy.jsonl"), "w", encoding="utf-8") as f:
    for r in noisy: f.write(json.dumps(r, ensure_ascii=False) + "\n")
print("noisy clips:", len(noisy))

# ---------------- meetings ----------------
def build_meeting(name, lang, clips):
    rng = rng_for(name); out = np.zeros(SR * 5); pos = 0
    def put(a, start):
        nonlocal out
        end = start + len(a)
        if end > len(out): out = np.concatenate([out, np.zeros(end - len(out) + SR * 5)])
        out[start:end] += a
    for i, c in enumerate(clips):
        a = load(c["audio"]) * 10 ** (rng.uniform(-4, 4) / 20)
        if i and rng.random() < 0.12: start = max(0, pos - int(0.7 * SR)); a = a * 0.8
        else: start = pos + int(rng.uniform(0.4, 2.5) * SR) if i else int(0.5 * SR)
        put(a, start); pos = start + len(a)
    out = out[:pos + SR]
    out = add_at_snr(reverb(out, 0.4, rng), pink(len(out), rng), 20)
    return out

def chunk(x, name, lang):
    """<=25 s windows, cut at the quietest 50 ms frame in the last 5 s; chunks >= 8 s."""
    fr = int(0.05 * SR); e = np.array([rms(x[i:i + fr]) for i in range(0, len(x) - fr, fr)])
    cuts, start = [], 0
    while len(x) - start > 25 * SR:
        lo, hi = (start + 20 * SR) // fr, (start + 25 * SR) // fr
        k = lo + int(np.argmin(e[lo:hi])); cuts.append((start, k * fr)); start = k * fr
    cuts.append((start, len(x)))
    rows = []
    for i, (s, t) in enumerate(cuts):
        rid = f"{name}-c{i:03d}"; p = os.path.join(OUT, "meeting", rid + ".wav"); save(p, x[s:t])
        rows.append({"id": rid, "meeting": name, "order": i, "lang": lang, "audio": p, "seconds": round((t - s) / SR, 2)})
    return rows

meetings, chunks = {}, []
specs = []
for lang in ("he", "ru", "en"):
    specs += [(f"mtg-{lang}-1", lang, M[lang][30:66]), (f"mtg-{lang}-2", lang, M[lang][66:100])]
rng = rng_for("mixed"); order = ["he", "ru", "en", "en", "he", "ru", "ru", "en", "he"]
idx = {l: 40 for l in M}; mixed = []
for l in order:
    mixed += M[l][idx[l]:idx[l] + 4]; idx[l] += 4
specs.append(("mtg-mixed-1", "mixed", mixed))
for name, lang, clips in specs:
    x = build_meeting(name, lang, clips)
    meetings[name] = {"lang": lang, "ref": " ".join(c["ref"] for c in clips), "seconds": round(len(x) / SR, 1),
                      "utterances": len(clips), "langs": [c["id"].split("-")[0] for c in clips]}
    chunks += chunk(x, name, lang)
    print(name, meetings[name]["seconds"], "s", meetings[name]["utterances"], "utterances")
json.dump(meetings, open(os.path.join(MAN, "meetings.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
with open(os.path.join(MAN, "meeting_chunks.jsonl"), "w", encoding="utf-8") as f:
    for r in chunks: f.write(json.dumps(r, ensure_ascii=False) + "\n")
print("meeting chunks:", len(chunks))

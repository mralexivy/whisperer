#!/usr/bin/env python3
"""Peak-memory / latency per engine x audio duration, one process per run under /usr/bin/time -l.
Peak footprint covers model load + inference of that process (load and decode peaks are not separable this way).
Resumable: results/resource.jsonl. usage: resource_bench.py [engine ...]"""
import json, os, re, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
CRISP = os.environ["CRISPASR"]; MODELS = os.path.expanduser("~/ai/omni-bench-models")
DURS = [5, 15, 30, 60]
def build_audio():
    clips = [json.loads(l)["audio"] for l in open(f"{here}/manifests/en.jsonl")]
    for d in DURS:
        out = f"{here}/corpus/dur/en-{d}s.wav"
        if os.path.exists(out): continue
        args = ["ffmpeg", "-y", "-v", "error"]
        for c in clips[:14]: args += ["-i", c]
        subprocess.run(args + ["-filter_complex", f"concat=n=14:v=0:a=1,atrim=0:{d}", "-ar", "16000", "-ac", "1", out], check=True)
SPEECH = {"qwen3-1.7b-8bit": ["--engine", "qwen3", "-m", "1.7B"],
          "omni-ctc-7b-4": ["--engine", "omnilingual", "--backend", "mlx", "--variant", "7B", "--bits", "4"],
          "omni-ctc-3b-8": ["--engine", "omnilingual", "--backend", "mlx", "--variant", "3B", "--bits", "8"],
          "omni-ctc-3b-4": ["--engine", "omnilingual", "--backend", "mlx", "--variant", "3B", "--bits", "4"]}
CRISPM = {"llm300m-q4k": "omniasr-llm-300m-v2-q4_k.gguf", "llm-unl300m-q4k": "omniasr-llm-unlimited-300m-v2-q4_k.gguf",
          "llm1b-q4k": "omniasr-llm-1b-q4_k.gguf"}
def cmd(e, wav):
    if e in SPEECH: return ["speech", "transcribe", wav] + SPEECH[e]
    return [CRISP, "--backend", "omniasr-llm", "-m", f"{MODELS}/{CRISPM[e]}", "-f", wav, "-nt", "-l", "lang_416"]
build_audio()
engines = sys.argv[1:] or list(SPEECH) + list(CRISPM)
path = f"{here}/results/resource.jsonl"
done = {(r["engine"], r["dur"], r["run"]) for r in map(json.loads, open(path))} if os.path.exists(path) else set()
with open(path, "a") as fo:
    for e in engines:
        for d in DURS:
            for run in ("cold", "warm"):
                if (e, d, run) in done: continue
                wav = f"{here}/corpus/dur/en-{d}s.wav"
                t0 = time.time()
                p = subprocess.run(["/usr/bin/time", "-l"] + cmd(e, wav), capture_output=True, text=True)
                wall = time.time() - t0; txt = p.stdout + p.stderr
                fp = re.search(r"(\d+)\s+peak memory footprint", txt); rss = re.search(r"(\d+)\s+maximum resident set size", txt)
                m = re.search(r"Time: ([\d.]+)s, RTF: ([\d.]+)", txt) or None
                c = re.search(r"transcribed ([\d.]+)s audio in ([\d.]+)s", txt)
                dec = float(m.group(1)) if m else (float(c.group(2)) if c else None)
                rec = {"engine": e, "dur": d, "run": run, "ok": dec is not None and p.returncode == 0, "decode_s": dec,
                       "rtf": dec / d if dec else None, "wall_s": round(wall, 2),
                       "peak_footprint_mb": round(int(fp.group(1)) / 2**20) if fp else None,
                       "max_rss_mb": round(int(rss.group(1)) / 2**20) if rss else None}
                if not rec["ok"]: rec["err"] = txt[-250:]
                fo.write(json.dumps(rec) + "\n"); fo.flush(); print(rec, flush=True)

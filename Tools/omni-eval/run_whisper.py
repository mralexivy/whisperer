#!/usr/bin/env python3
"""Run whisper.cpp CLI variants over manifests -> hyp/<key>.jsonl (score.py format, resumable).
usage: run_whisper.py <key> [lang ...]     env WCPP_COREML=<whisper-cli with Core ML>  WMODELS=<dir>
Greedy (-bs 1 -bo 1), no prompt, like the live preview. Pinned = -l <clip language>; *-auto = -l auto (records detected lang)."""
import json, os, re, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
CML = os.environ["WCPP_COREML"]; WM = os.environ.get("WMODELS", os.path.expanduser("~/ai/omni-bench-models/whisper"))
STATIC = os.path.join(here, "../../whisper.cpp/build-static/bin/whisper-cli")  # the app's own build: Metal, no Core ML
V = {  # key: (cli, model, extra flags, pinned?)
  "wbase-cml-cpu":   (CML, "ggml-base.bin", ["-ng"], True),   # Core ML encoder (needs ggml-base-encoder.mlmodelc), decoder CPU
  "wbase-cml-gpu":   (CML, "ggml-base.bin", [], True),        # Core ML encoder, decoder Metal
  "wbase-cml-auto":  (CML, "ggml-base.bin", ["-ng"], False),
  "wbase-q5-metal":  (STATIC, "ggml-base-q5_1.bin", [], True),  # what the app bundles (Metal, no Core ML)
  "wtiny-cpu":       (CML, "ggml-tiny.bin", ["-ng"], True),   # historical preview/detector model
}
key = sys.argv[1]; langs = sys.argv[2:] or ["he", "ru", "en"]
cli, model, extra, pinned = V[key]
out = os.path.join(here, "hyp", f"{key}.jsonl")
done = {json.loads(l)["id"] for l in open(out, encoding="utf-8")} if os.path.exists(out) else set()
with open(out, "a", encoding="utf-8") as fo:
    for lang in langs:
        for line in open(os.path.join(here, "manifests", f"{lang}.jsonl"), encoding="utf-8"):
            c = json.loads(line)
            if c["id"] in done: continue
            l = ("he" if lang == "cs" else lang) if pinned else "auto"  # mixed clips: pinned = Hebrew, like ivrit-forced-he
            t0 = time.time()
            p = subprocess.run(["/usr/bin/time", "-l", cli, "-m", os.path.join(WM, model), "-f", c["audio"], "-l", l,
                                "-nt", "-bs", "1", "-bo", "1"] + extra, capture_output=True, text=True, encoding="utf-8", errors="replace")
            wall = time.time() - t0
            det = re.search(r"auto-detected language: (\w+) \(p = ([\d.]+)\)", p.stderr)
            tot = re.search(r"total time =\s+([\d.]+) ms", p.stderr)
            enc = re.search(r"encode time =\s+[\d.]+ ms /\s+\d+ runs \(\s+([\d.]+) ms per run", p.stderr)
            fp = re.search(r"(\d+)\s+peak memory footprint", p.stderr)
            dec = float(tot.group(1)) / 1000 if tot else None
            rec = {"id": c["id"], "lang": lang, "engine": key, "ok": p.returncode == 0 and tot is not None,
                   "text": " ".join(p.stdout.split()), "rtf": dec / c["seconds"] if dec else None, "decode_s": dec,
                   "encode_ms": float(enc.group(1)) if enc else None, "wall": round(wall, 2), "seconds": c["seconds"],
                   "detected": det.group(1) if det else None, "peak_footprint_mb": round(int(fp.group(1)) / 2**20) if fp else None}
            fo.write(json.dumps(rec, ensure_ascii=False) + "\n"); fo.flush()
print("done", key)

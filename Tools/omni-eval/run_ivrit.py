#!/usr/bin/env python3
"""Run ivrit-v3-turbo via the vendored whisper-cli (app's own whisper.cpp build) over manifests.
Used because the XCTest target does not compile at HEAD (StopPathDataLossTests actor error)."""
import json, os, subprocess, time
here = os.path.dirname(os.path.abspath(__file__))
cli = os.path.join(here, "../../whisper.cpp/build-static/bin/whisper-cli")
model = os.path.expanduser("~/Library/Application Support/Whisperer/ggml-ivrit-v3-turbo.bin")
jobs = [("ivrit-v3-turbo", "he", "he"), ("ivrit-forced-he", "cs", "he"), ("ivrit-auto", "cs", "auto")]
for key, manifest, lang in jobs:
    out = open(os.path.join(here, "hyp", f"{key}.jsonl"), "w", encoding="utf-8")
    for line in open(os.path.join(here, "manifests", f"{manifest}.jsonl"), encoding="utf-8"):
        c = json.loads(line); t0 = time.time()
        p = subprocess.run([cli, "-m", model, "-f", c["audio"], "-l", lang, "-nt", "-np"],
                           capture_output=True, text=True)
        wall = time.time() - t0
        out.write(json.dumps({"id": c["id"], "lang": manifest, "engine": key, "ok": p.returncode == 0,
                              "text": " ".join(p.stdout.split()), "rtf": wall / c["seconds"],
                              "wall": round(wall, 2), "seconds": c["seconds"]}, ensure_ascii=False) + "\n")
        out.flush()
    print("done", key)

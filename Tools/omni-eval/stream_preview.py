#!/usr/bin/env python3
"""Progressive-feed preview simulation for lightweight engines. Resumable: results/stream-<key>.jsonl.
usage: stream_preview.py <key> [--n 8] [--step 2.0] [--langs he ru en]

Audio is fed in `step`-second increments; after each increment the engine re-decodes the audio heard so far
(growing prefix). This is REPEATED OFFLINE DECODING of overlapping windows, for every engine here: neither whisper.cpp
nor the Omni CTC Core ML model keeps incremental state. Per pass we record the model-only compute time (process start
and model load excluded), so the latency of a partial shown at audio time t is t + compute.
Committed text uses LocalAgreement-2 (a word is committed once two consecutive passes agree on the prefix), the same
rule as Whisperer's EagerStreamEngine.

Metrics per clip: first partial (audio s), first correct word (audio s, first partial whose first word matches the
reference's first word), first committed word (audio s), flicker (share of words, excluding the last two of the previous
pass, that differ in the next pass), committed-vs-reference WER at the end, pass compute times.
Under load (--tag loaded) the same run is repeated while a Qwen3 job runs in the background."""
import argparse, json, os, re, subprocess, sys, tempfile, time
here = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(here, "score.py")).read().split("refs = {}")[0])  # norm, lev
CML = os.environ.get("WCPP_COREML", "")
WM = os.path.expanduser("~/ai/omni-bench-models/whisper")
OMNI = lambda w: ["speech", "transcribe", "{wav}", "--engine", "omnilingual", "--backend", "coreml", "--window", str(w)]
def whisper(model, extra, pinned_lang=True):
    return lambda lang: [CML, "-m", f"{WM}/{model}", "-f", "{wav}", "-l", lang if pinned_lang else "auto", "-nt", "-bs", "1", "-bo", "1"] + extra
ENGINES = {
    "wbase-cml-cpu": whisper("ggml-base.bin", ["-ng"]),
    "wbase-cml-gpu": whisper("ggml-base.bin", []),
    "wtiny-cpu": whisper("ggml-tiny.bin", ["-ng"]),
    "omni300-cml-10": lambda lang: OMNI(10),
    "omni300-cml-5": lambda lang: OMNI(5),
}
def decode(key, lang, wav):
    cmd = [c.replace("{wav}", wav) for c in ENGINES[key](lang)]
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    wall = time.time() - t0
    if key.startswith("omni"):
        m = re.search(r"Result: (.*?)\n\s*Time: ([\d.]+)s", p.stdout + p.stderr, re.S)
        return (m.group(1).strip() if m else ""), (float(m.group(2)) if m else None), wall
    load = re.search(r"load time =\s+([\d.]+) ms", p.stderr); tot = re.search(r"total time =\s+([\d.]+) ms", p.stderr)
    comp = (float(tot.group(1)) - float(load.group(1))) / 1000 if tot and load else None
    return " ".join(p.stdout.split()), comp, wall
def agree(prev, cur):  # LocalAgreement-2: longest common word prefix of two consecutive passes
    n = 0
    while n < min(len(prev), len(cur)) and prev[n] == cur[n]: n += 1
    return n

ap = argparse.ArgumentParser(); ap.add_argument("key"); ap.add_argument("--n", type=int, default=8)
ap.add_argument("--step", type=float, default=2.0); ap.add_argument("--langs", nargs="*", default=["he", "ru", "en"])
ap.add_argument("--tag", default="idle"); a = ap.parse_args()
out = os.path.join(here, "results", f"stream-{a.key}-{a.tag}.jsonl")
done = {json.loads(l)["id"] for l in open(out)} if os.path.exists(out) else set()
tmp = tempfile.mkdtemp()
with open(out, "a") as fo:
    for lang in a.langs:
        clips = [json.loads(l) for l in open(f"{here}/manifests/{lang}.jsonl", encoding="utf-8")]
        clips = [c for c in clips if 8 <= c["seconds"] <= 14][:a.n]
        for c in clips:
            if c["id"] in done: continue
            ref = norm(c["ref"]).split(); passes, t = [], a.step
            while True:
                end = min(t, c["seconds"]); wav = f"{tmp}/p.wav"
                subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", c["audio"], "-t", f"{end}", "-ar", "16000", "-ac", "1", wav], check=True)
                text, comp, wall = decode(a.key, lang, wav)
                passes.append({"t": end, "words": norm(text).split(), "comp": comp, "wall": wall})
                if end >= c["seconds"]: break
                t += a.step
            first_partial = next((p["t"] for p in passes if p["words"]), None)
            first_correct = next((p["t"] for p in passes if p["words"] and ref and p["words"][0] == ref[0]), None)
            committed, first_commit = [], None
            for prev, cur in zip(passes, passes[1:]):
                n = agree(prev["words"], cur["words"])
                if n > len(committed):
                    committed = cur["words"][:n]
                    if first_commit is None: first_commit = cur["t"]
            ch = tot = 0
            for prev, cur in zip(passes, passes[1:]):
                stable = prev["words"][:-2]
                tot += len(stable); ch += sum(1 for i, w in enumerate(stable) if i >= len(cur["words"]) or cur["words"][i] != w)
            final = passes[-1]["words"]
            rec = {"id": c["id"], "lang": lang, "engine": a.key, "tag": a.tag, "seconds": c["seconds"], "step": a.step,
                   "passes": len(passes), "comp": [p["comp"] for p in passes], "first_partial_s": first_partial,
                   "first_correct_s": first_correct, "first_commit_s": first_commit, "flicker": (ch / tot) if tot else None,
                   "final_wer": lev(ref, final) / max(len(ref), 1), "committed_wer": lev(ref, committed) / max(len(ref), 1),
                   "final_text": " ".join(final)}
            fo.write(json.dumps(rec, ensure_ascii=False) + "\n"); fo.flush()
print("done", a.key, a.tag)

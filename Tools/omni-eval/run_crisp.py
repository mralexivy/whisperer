#!/usr/bin/env python3
"""Run an Omnilingual LLM GGUF through CrispASR over manifests, writing hyp/<engine>.jsonl. Resumable.
usage: run_crisp.py <engine-key> [--limit N] [--lang he ru en cs]

The cstr GGUFs ship placeholder lang_codes ("lang_0".."lang_1692"), so CrispASR's name lookup never matches and every
decode silently runs conditioned on eng_Latn. `-l lang_<i>` matches by placeholder and selects lang_id i+1, where i is
the row index in Meta's languges_lookup_table.parquet (eng 416, heb 541, rus 1287). Code-switch clips are conditioned
on Hebrew, the same choice as the ivrit-forced-he baseline."""
import argparse, json, os, re, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
CRISP = os.environ.get("CRISPASR", "crispasr")
MODELS = os.environ.get("OMNI_MODELS", os.path.expanduser("~/ai/omni-bench-models"))
LANG_IDX = {"en": 416, "he": 541, "ru": 1287, "cs": 541}
ENGINES = {
    "llm300m-q4k": "omniasr-llm-300m-v2-q4_k.gguf",
    "llm-unl300m-q4k": "omniasr-llm-unlimited-300m-v2-q4_k.gguf",
    "llm1b-q4k": "omniasr-llm-1b-q4_k.gguf",
    "llm300m-q8": "omniasr-llm-300m-v2-q8_0.gguf",
}
ap = argparse.ArgumentParser()
ap.add_argument("engine"); ap.add_argument("--limit", type=int, default=0)
ap.add_argument("--lang", nargs="*", default=["he", "ru", "en", "cs"])
ap.add_argument("--no-lang", action="store_true", help="leave the runtime default (eng_Latn) for every clip")
a = ap.parse_args()
out = os.path.join(here, "hyp", f"{a.engine}.jsonl")
done = set()
if os.path.exists(out):
    done = {json.loads(l)["id"] for l in open(out, encoding="utf-8")}
with open(out, "a", encoding="utf-8") as fo:
    for lang in a.lang:
        clips = [json.loads(l) for l in open(os.path.join(here, "manifests", f"{lang}.jsonl"), encoding="utf-8")]
        for c in (clips[:a.limit] if a.limit else clips):
            if c["id"] in done: continue
            cmd = ["/usr/bin/time", "-l", CRISP, "--backend", "omniasr-llm", "-m", os.path.join(MODELS, ENGINES[a.engine]),
                   "-f", c["audio"], "-nt"]
            if not a.no_lang: cmd += ["-l", f"lang_{LANG_IDX[lang]}"]
            t0 = time.time()
            p = subprocess.run(cmd, capture_output=True, text=True)
            wall = time.time() - t0
            m = re.search(r"transcribed ([\d.]+)s audio in ([\d.]+)s", p.stderr)
            fp = re.search(r"(\d+)\s+peak memory footprint", p.stderr)
            rss = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
            rec = {"id": c["id"], "lang": lang, "engine": a.engine, "ok": bool(m) and p.returncode == 0,
                   "text": " ".join(p.stdout.split()), "rtf": float(m.group(2)) / float(m.group(1)) if m else None,
                   "decode_s": float(m.group(2)) if m else None, "wall": round(wall, 2), "seconds": c["seconds"],
                   "peak_footprint_mb": round(int(fp.group(1)) / 2**20) if fp else None,
                   "max_rss_mb": round(int(rss.group(1)) / 2**20) if rss else None}
            if not m: rec["err"] = p.stderr[-300:]
            fo.write(json.dumps(rec, ensure_ascii=False) + "\n"); fo.flush()
print("done", a.engine)

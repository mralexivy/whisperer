#!/usr/bin/env python3
"""Synthetic code-switch: concat 3 short clips alternating languages (A,B,A). Refs concatenated."""
import json, os, random, subprocess
here = os.path.dirname(os.path.abspath(__file__))
def load(l): return [json.loads(x) for x in open(f"{here}/manifests/{l}.jsonl", encoding="utf-8")]
he, ru, en = load("he"), load("ru"), load("en")
rng = random.Random(7); out = []
for tag, other in (("he-en", en), ("he-ru", ru)):
    hs = [c for c in he if c["seconds"] < 12.5]; os_ = [c for c in other if c["seconds"] < 12.5]
    rng.shuffle(hs); rng.shuffle(os_)
    for i in range(20):
        parts = [hs[i], os_[i], hs[i+20]] if i % 2 == 0 else [os_[i], hs[i], os_[i+20]]
        wav = f"{here}/corpus/cs/{tag}-{i}.wav"
        args = ["ffmpeg","-y","-v","error"]
        for p in parts: args += ["-i", p["audio"]]
        args += ["-filter_complex", f"concat=n=3:v=0:a=1", "-ar", "16000", "-ac", "1", wav]
        subprocess.run(args, check=True)
        out.append({"id": f"cs-{tag}-{i}", "lang": "cs", "audio": wav, "ref": " ".join(p["ref"] for p in parts),
                    "seconds": sum(p["seconds"] for p in parts), "mix": tag})
with open(f"{here}/manifests/cs.jsonl", "w", encoding="utf-8") as f:
    for x in out: f.write(json.dumps(x, ensure_ascii=False) + "\n")
print(len(out), "clips", round(max(x["seconds"] for x in out)), "s max")

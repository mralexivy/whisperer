#!/usr/bin/env python3
"""Convert results/rt-<engine>-<tag>.jsonl (streambench) to hyp/<key>.jsonl so score.py scores it like every other engine.
usage: rt_to_hyp.py <rt-file> <hyp-key>"""
import json, sys
src, key = sys.argv[1], sys.argv[2]
seen = set()
with open(f"hyp/{key}.jsonl", "w", encoding="utf-8") as fo:
    for l in open(src, encoding="utf-8"):
        r = json.loads(l)
        if r["id"] in seen: continue
        seen.add(r["id"])
        fo.write(json.dumps({"id": r["id"], "lang": r["lang"], "engine": key, "ok": True, "text": r["final_text"],
                             "rtf": None, "seconds": r["seconds"]}, ensure_ascii=False) + "\n")
print(key, len(seen), "clips")

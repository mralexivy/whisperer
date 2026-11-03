#!/usr/bin/env python3
"""Build manifests/<lang>.jsonl from FLEURS test: one clip per distinct sentence id, seeded sample."""
import csv, json, os, random, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus", "fleurs")
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifests")
n = int(sys.argv[1]) if len(sys.argv) > 1 else 100
os.makedirs(out, exist_ok=True)
for lang, short in [("he_il", "he"), ("ru_ru", "ru"), ("en_us", "en")]:
    seen, rows = set(), []
    with open(os.path.join(root, lang, "test.tsv"), encoding="utf-8") as f:
        for r in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(r) < 6 or r[0] in seen: continue
            wav = os.path.join(root, lang, "test", r[1])
            if not os.path.exists(wav): continue
            seen.add(r[0])
            # r[2]=raw transcription, r[3]=normalized (lowercase, no punctuation)
            rows.append({"id": f"{short}-{r[0]}", "lang": short, "audio": wav,
                         "ref": r[3].strip(), "ref_raw": r[2].strip().strip('"'),
                         "seconds": int(r[5]) / 16000})
    random.Random(42).shuffle(rows)
    rows = [x for x in rows if x["seconds"] <= 38][:n]
    with open(os.path.join(out, f"{short}.jsonl"), "w", encoding="utf-8") as f:
        for x in rows: f.write(json.dumps(x, ensure_ascii=False) + "\n")
    print(short, len(rows), "clips,", round(sum(x["seconds"] for x in rows)), "s")

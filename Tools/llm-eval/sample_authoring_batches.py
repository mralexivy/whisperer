#!/usr/bin/env python3
"""Sample raw-ASR transcripts from the recordings history into authoring batches.

The gold corpus that rule 4 needs cannot come from `golden-set.json`: that file is a
whole-file decode by the *same* model, so its median headroom `1 - sim(in, gold)` is 0.038
and 55 of 92 cases sit below 0.05. There is nothing to recover toward. This script selects
the *inputs* for an authored reference instead; the gold itself is written by the authoring
pass and checked by `check_authored_gold.py`.

Selection is deterministic (stride over id-sorted buckets), so a re-run reproduces the same
corpus and a diff to it is a real change rather than resampling noise.

Language is assigned by **script**, not by the stored `language` field: the history declares
Hebrew on recordings that hold none, which is the same trap `PolishBenchmarkTests` documents.
"""

import argparse
import glob
import json
import os

HISTORY = "Tools/mmbert/artifacts/raw/history-golden.json"
OUT_DIR = "Tools/llm-eval/authoring"

# Per-language target. Hebrew and Russian are capped by what the history actually holds
# (87 and 85 recordings of >= 12 words), so these are a large share of the available pool
# rather than an arbitrary sample size.
TARGETS = {"en": 90, "he": 30, "ru": 30}

# Below this a transcript is a fragment: no interior sentence boundary to author, so it
# cannot exercise the thing being measured.
MIN_WORDS = 12

# Duration buckets, matching the spirit of `HistoryTestLoader.durationBucket`: a corpus of
# only short utterances would not test paragraph breaks at all.
BUCKETS = [(0, 10), (10, 30), (30, 90), (90, 10_000)]


def script_of(text):
    hebrew = sum(1 for c in text if "֐" <= c <= "׿")
    cyrillic = sum(1 for c in text if "Ѐ" <= c <= "ӿ")
    latin = sum(1 for c in text if c.isascii() and c.isalpha())
    top = max(hebrew, cyrillic, latin)
    if top == 0:
        return "other"
    if top == hebrew:
        return "he"
    return "ru" if top == cyrillic else "en"


def bucket_of(seconds):
    for index, (low, high) in enumerate(BUCKETS):
        if low <= seconds < high:
            return index
    return len(BUCKETS) - 1


def stride_pick(items, count):
    """Evenly spaced selection over a sorted list — deterministic, and not biased to one end."""
    if count >= len(items):
        return list(items)
    step = len(items) / count
    return [items[int(i * step)] for i in range(count)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch-size", type=int, default=15)
    parser.add_argument("--out-dir", default=OUT_DIR)
    # Round 2. The first sample authored 149 usable pairs and only 21 cleared every gate, leaving
    # two of three languages below the n=20 reporting floor — so the rest of the pool gets drawn.
    # `--exclude` keeps the two rounds disjoint (a re-authored case is not a second data point),
    # and `--prefix` keeps round 2's files from overwriting round 1's, which still hold the gold.
    parser.add_argument("--exclude", default=None,
                        help="glob of existing batch-*.json whose ids must not be re-sampled")
    parser.add_argument("--prefix", default="batch")
    parser.add_argument("--targets", default=None,
                        help='per-language counts, e.g. "en=150,he=57,ru=55"')
    args = parser.parse_args()

    targets = dict(TARGETS)
    if args.targets:
        targets = {}
        for pair in args.targets.split(","):
            language, _, count = pair.partition("=")
            targets[language.strip()] = int(count)

    excluded = set()
    if args.exclude:
        for path in glob.glob(args.exclude):
            for row in json.load(open(path, encoding="utf-8")):
                excluded.add(row["id"])

    entries = json.load(open(HISTORY, encoding="utf-8"))["entries"]

    pools = {language: {index: [] for index in range(len(BUCKETS))} for language in targets}
    for entry in entries:
        text = (entry.get("storedTranscript") or "").strip()
        if len(text.split()) < MIN_WORDS or entry["id"] in excluded:
            continue
        language = script_of(text)
        if language not in pools:
            continue
        pools[language][bucket_of(entry.get("durationSec") or 0)].append(
            {"id": entry["id"], "language": language, "durationSec": entry.get("durationSec"), "input": text}
        )

    selected = {}
    for language, target in targets.items():
        buckets = pools[language]
        non_empty = [index for index in buckets if buckets[index]]
        per_bucket = max(1, target // max(1, len(non_empty)))
        picked = []
        for index in non_empty:
            picked += stride_pick(sorted(buckets[index], key=lambda row: row["id"]), per_bucket)
        # Top up from the largest bucket if integer division left us short.
        if len(picked) < target and non_empty:
            largest = max(non_empty, key=lambda index: len(buckets[index]))
            already = {row["id"] for row in picked}
            spare = [row for row in sorted(buckets[largest], key=lambda row: row["id"]) if row["id"] not in already]
            picked += stride_pick(spare, target - len(picked))
        selected[language] = picked[:target]

    os.makedirs(args.out_dir, exist_ok=True)
    manifest = []
    for language, rows in selected.items():
        for start in range(0, len(rows), args.batch_size):
            chunk = rows[start : start + args.batch_size]
            name = f"{args.prefix}-{language}-{start // args.batch_size:02d}.json"
            path = os.path.join(args.out_dir, name)
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(chunk, handle, ensure_ascii=False, indent=1)
            manifest.append({"path": path, "language": language, "count": len(chunk)})
            print(f"{path}  {language}  {len(chunk)} cases")

    with open(os.path.join(args.out_dir, f"manifest-{args.prefix}.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=1)
    print("total:", sum(row["count"] for row in manifest))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build the golden transcript set used as the reference for streaming regression tests.

Why this exists
---------------
Every accuracy test in `WhispererTests` used to score against `ZTRANSCRIPTION` — the text the
app itself produced and stored in history. That text is streaming output: VAD-chunked, seam-
stitched, and subject to exactly the defects the streaming tests are trying to detect. Scoring a
streaming path against a streaming reference means a genuine fix can register as a regression,
and a shared defect cancels out and registers as nothing at all.

The golden set replaces that reference with a **full-file decode by the same model**. It is not
human ground truth and does not claim to be. It is the answer to a narrower and more useful
question: what does this model produce when handed all of the audio at once, with no windowing,
no chunk boundaries, and no seams? The delta between a streaming run and the golden set is
therefore the damage streaming does — which is the thing under test.

Determinism
-----------
Decoding params are matched to `WhisperBridge.makeFullParams` field for field (greedy, best_of 1,
temperature 0, no temperature fallback, 128-token context, non-speech suppression, and the three
explicit thresholds). With `temperature = 0` and `temperature_inc = 0` the decode is greedy and
reproducible, so re-running this script on unchanged audio reproduces the file byte for byte.
The one deliberate difference from the app is the absence of windowing — that is the point.

The CLI is built from the **vendored** `whisper.cpp/`, not from a fresh upstream clone. The
vendored tree (v1.8.3) is the exact source the app links against; a clone could differ in version
and make the golden set disagree with the app for reasons that have nothing to do with streaming.

Usage
-----
    python3 scripts/build-golden-set.py              # incremental: only missing ids
    python3 scripts/build-golden-set.py --force      # re-decode everything
    python3 scripts/build-golden-set.py --limit 20   # quick partial run
"""

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from urllib.parse import unquote

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Which history database, and it matters more than it looks. There are two — the sandboxed
# container and the plain Application Support directory — with *disjoint* contents. The tests run
# in the sandboxed test host, so `HistoryTestLoader.findDatabase` prefers the container; the first
# full run of this script read the other one and produced 535 golden transcripts whose ids
# overlapped the test corpus in exactly zero rows, so the whole gate skipped. The candidate order
# below mirrors `HistoryTestLoader.findDatabase` and must stay in step with it.
SUPPORT_CANDIDATES = [
    os.path.expanduser("~/Library/Containers/com.ivy.whisperer/Data/Library/Application Support/Whisperer"),
    os.path.expanduser("~/Library/Application Support/Whisperer"),
]
SUPPORT = next(
    (p for p in SUPPORT_CANDIDATES if os.path.exists(os.path.join(p, "history.sqlite"))),
    SUPPORT_CANDIDATES[-1],
)
DB = os.path.join(SUPPORT, "history.sqlite")
# The model lives with whichever container the app last ran from; fall back to the other.
MODEL = next(
    (os.path.join(p, "ggml-large-v3-turbo-q5_0.bin") for p in SUPPORT_CANDIDATES
     if os.path.exists(os.path.join(p, "ggml-large-v3-turbo-q5_0.bin"))),
    os.path.join(SUPPORT, "ggml-large-v3-turbo-q5_0.bin"),
)
OUT = os.path.join(REPO, "WhispererTests", "TestData", "golden-set.json")
STAGING = "/tmp/whisperer-golden"

# Candidate CLI locations inside the vendored tree, most preferred first.
CLI_CANDIDATES = [
    os.path.join(REPO, "whisper.cpp", "build-coreml", "bin", "whisper-cli"),
    os.path.join(REPO, "whisper.cpp", "build-arm64", "bin", "whisper-cli"),
]

# Mirrors WhisperBridge.makeFullParams. Keep the two in sync — a drift here silently changes what
# "correct" means for every accuracy test in the suite.
#   -bs 1   beam size 1 -> whisper.cpp selects WHISPER_SAMPLING_GREEDY
#   -bo 1   greedy.best_of = 1 (all candidates identical at temperature 0)
#   -tp 0   temperature = 0.0
#   -tpi 0  temperature_inc = 0.0, with -nf to disable the fallback ladder outright
#   -mc 128 n_max_text_ctx = 128
#   -sns    suppress_nst = true
DECODE_ARGS = [
    "-bs", "1", "-bo", "1",
    "-tp", "0", "-tpi", "0", "-nf",
    "-mc", "128",
    "-sns",
    "-nth", "0.6", "-lpt", "-1.0", "-et", "2.4",
    "-l", "auto",
    "-nt", "-np", "-otxt",
]

BATCH = 40  # files per CLI invocation: amortises the ~8s model load without risking one huge run


def find_cli():
    for path in CLI_CANDIDATES:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    sys.exit(
        "No whisper-cli found in the vendored tree. Build it with:\n"
        "  cmake -B whisper.cpp/build-coreml -S whisper.cpp -DWHISPER_COREML=1\n"
        "  cmake --build whisper.cpp/build-coreml -j --target whisper-cli"
    )


def load_rows(row_limit, any_model=False):
    """Rows from history that have both audio on disk and a stored transcript.

    Filters and ordering mirror `HistoryTestLoader.query` so the ids decoded here are the ids the
    tests ask for. The `ABS(ZDURATION - 20)` ordering is that loader's, not an arbitrary choice:
    it takes recordings nearest 20s first, so a capped run covers the fixtures the tests select
    rather than a random slice of a 2800-row history.

    Restricted to Whisperer V3. The golden set is decoded by `ggml-large-v3-turbo-q5_0` and the
    streaming tests run that same model, so a Parakeet or Nemotron recording contributes a stored
    transcript from one engine and a golden transcript from another — the delta then measures the
    gap between two models, which is not what any of these tests are asking.
    """
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    cur = con.cursor()
    cur.execute(
        # hex(ZID) to match `HistoryTestLoader`: CoreData stores the UUID as a 16-byte blob, so
        # reading it as text yields mojibake. The ids in this file must be byte-identical to the
        # ones the Swift loader produces or nothing joins.
        "SELECT hex(ZID), ZDURATION, ZAUDIOFILEURL, ZTRANSCRIPTION, ZLANGUAGE, ZMODELUSED "
        "FROM ZTRANSCRIPTIONENTITY "
        "WHERE ZISINPROGRESS = 0 "
        "  AND ZTRANSCRIPTION IS NOT NULL "
        "  AND length(ZTRANSCRIPTION) > 20 "
        "  AND ZAUDIOFILEURL IS NOT NULL "
        "  AND (ZTARGETAPPNAME IS NULL OR ZTARGETAPPNAME != 'File Import') "
        # The model filter exists so the *streaming-regression* corpus compares one model against
        # itself. A corpus built for editor **training** wants the opposite: every recording the
        # user has, whatever engine first transcribed it, because the reference is this fresh
        # whole-file decode and the stored transcript is not used as truth. `--any-model` lifts it.
        + ("" if any_model else
           "  AND ZMODELUSED IN ('Whisperer V3', 'Large V3 Turbo Q5', 'ggml-large-v3-turbo-q5_0.bin') ")
        + "ORDER BY ABS(CAST(ZDURATION AS REAL) - 20.0) ASC "
        "LIMIT ?",
        (row_limit,),
    )
    rows = []
    for zid, dur, url, transcript, lang, model in cur.fetchall():
        if not zid or not url or not transcript or not transcript.strip():
            continue
        path = unquote(url.replace("file://", ""))
        if not os.path.exists(path):
            # History stores an absolute URL that moves when the container moves; the file name
            # is stable, so fall back to the current Recordings directory before giving up.
            alt = os.path.join(SUPPORT, "Recordings", os.path.basename(path))
            if not os.path.exists(alt):
                continue
            path = alt
        rows.append({
            "id": zid,
            "durationSec": dur or 0.0,
            "audioPath": path,
            "storedTranscript": transcript.strip(),
            "language": lang or "auto",
            "modelUsed": model or "",
        })
    con.close()
    rows.sort(key=lambda r: r["id"])
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="re-decode ids already in the set")
    ap.add_argument("--limit", type=int, default=0, help="cap the number of recordings")
    # 400 covers `HistoryTestLoader.loadFixtures(maxCount: 300)` with room for rows the Swift side
    # drops (missing audio file), without decoding a 2000-recording history for a gate that reads
    # eight of them.
    ap.add_argument("--rows", type=int, default=400, help="history rows to consider")
    ap.add_argument("--out", default=OUT,
                    help="where to write. Defaults to the committed test corpus; point it "
                         "elsewhere to build a larger training corpus without moving the "
                         "benchmark's reference under it")
    ap.add_argument("--staging", default=STAGING, help="scratch directory for symlinks and .txt")
    ap.add_argument("--cli", default=None, help="explicit whisper-cli path")
    ap.add_argument("--any-model", action="store_true",
                    help="include recordings first transcribed by any engine, not only V3")
    args = ap.parse_args()

    out_path, staging = args.out, args.staging
    cli = args.cli or find_cli()
    if not os.path.exists(MODEL):
        sys.exit(f"Model not found: {MODEL}\nDownload Whisperer V3 in the app's Models tab first.")

    existing = {}
    if os.path.exists(out_path) and not args.force:
        with open(out_path) as fh:
            existing = {e["id"]: e for e in json.load(fh)["entries"]}

    rows = load_rows(args.rows, any_model=args.any_model)
    todo = [r for r in rows if r["id"] not in existing]
    if args.limit:
        todo = todo[: args.limit]

    print(f"whisper-cli : {cli}")
    print(f"model       : {os.path.basename(MODEL)}")
    print(f"corpus      : {len(rows)} recordings with audio; {len(existing)} already golden")
    print(f"to decode   : {len(todo)} ({sum(r['durationSec'] for r in todo) / 60:.1f} min audio)")
    if not todo:
        print("Nothing to do.")
        return

    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)

    # Symlink rather than copy, and stage outside the app's support directory. whisper-cli writes
    # `<input>.txt` next to each input, so pointing it straight at Recordings/ would scatter
    # generated files through the user's own data.
    # Meeting recordings are stored as `.opus`; dictation is `.wav`. whisper-cli reads WAV only,
    # and silently produces no output for anything else — the first full run lost exactly the 103
    # `.opus` rows that way, reported as "silence or decode failure". Transcode those to the
    # 16 kHz mono s16 WAV the model wants; symlink the rest.
    staged = {}
    transcoded = 0
    for row in todo:
        link = os.path.join(staging, f"{row['id']}.wav")
        if row["audioPath"].lower().endswith(".wav"):
            os.symlink(row["audioPath"], link)
        else:
            proc = subprocess.run(
                ["ffmpeg", "-nostdin", "-loglevel", "error", "-y",
                 "-i", row["audioPath"], "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", link],
                capture_output=True, text=True,
            )
            if proc.returncode != 0 or not os.path.exists(link):
                print(f"  transcode failed for {row['id']}: {proc.stderr[-200:]}", file=sys.stderr)
                continue
            transcoded += 1
        staged[row["id"]] = link
    if transcoded:
        print(f"transcoded  : {transcoded} non-WAV recordings to 16 kHz mono WAV")
    todo = [r for r in todo if r["id"] in staged]

    started = time.time()
    decoded = 0
    for i in range(0, len(todo), BATCH):
        batch = todo[i : i + BATCH]
        cmd = [cli, "-m", MODEL] + DECODE_ARGS + [staged[r["id"]] for r in batch]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"  batch {i // BATCH + 1} failed: {proc.stderr[-400:]}", file=sys.stderr)
        decoded += len(batch)
        elapsed = time.time() - started
        print(f"  {decoded}/{len(todo)} decoded  ({elapsed:.0f}s elapsed)", flush=True)

    entries = list(existing.values())
    missing = []
    for row in todo:
        txt = staged[row["id"]] + ".txt"
        if not os.path.exists(txt):
            missing.append(row["id"])
            continue
        with open(txt) as fh:
            golden = " ".join(fh.read().split()).strip()
        if not golden:
            missing.append(row["id"])
            continue
        entries.append({**row, "goldenTranscript": golden})

    entries.sort(key=lambda e: e["id"])
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as fh:
        json.dump(
            {
                "note": (
                    "Full-file decodes by ggml-large-v3-turbo-q5_0 with WhisperBridge's decoding "
                    "params. Reference for streaming regression tests: the delta against these is "
                    "the damage windowing does, not model error. Regenerate with "
                    "scripts/build-golden-set.py. Not human ground truth."
                ),
                "model": os.path.basename(MODEL),
                "decodeArgs": DECODE_ARGS,
                "entries": entries,
            },
            fh,
            ensure_ascii=False,
            indent=1,
        )

    print(f"\nWrote {len(entries)} golden transcripts to {os.path.relpath(out_path, REPO)}")
    if missing:
        print(f"{len(missing)} produced no text (silence or decode failure): {missing[:8]}")
    shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    main()

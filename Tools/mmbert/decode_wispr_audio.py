#!/usr/bin/env python
"""
decode_wispr_audio.py -- Phase 2: decode Wispr WAVs with our own model,
measure WER vs Wispr's asrText, build our_asr pairs.

Usage:
    ./.venv/bin/python decode_wispr_audio.py
    ./.venv/bin/python decode_wispr_audio.py --dry-run   # count only
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

# ── paths ──────────────────────────────────────────────────────────────────────

REPO = Path(__file__).resolve().parents[3]  # worktree root

# Mirror build-golden-set.py CLI_CANDIDATES, rooted at repo
CLI_CANDIDATES = [
    REPO / "whisper.cpp" / "build-coreml" / "bin" / "whisper-cli",
    REPO / "whisper.cpp" / "build-arm64" / "bin" / "whisper-cli",
]

SUPPORT_CANDIDATES = [
    Path.home() / "Library/Containers/com.ivy.whisperer/Data/Library/Application Support/Whisperer",
    Path.home() / "Library/Application Support/Whisperer",
]
SUPPORT = next(
    (p for p in SUPPORT_CANDIDATES if (p / "history.sqlite").exists()),
    SUPPORT_CANDIDATES[-1],
)
MODEL = next(
    (p / "ggml-large-v3-turbo-q5_0.bin" for p in SUPPORT_CANDIDATES
     if (p / "ggml-large-v3-turbo-q5_0.bin").exists()),
    SUPPORT / "ggml-large-v3-turbo-q5_0.bin",
)

CORPUS_JSONL = Path.home() / "wispr_corpus" / "corpus.jsonl"
AUDIO_DIR = Path.home() / "wispr_corpus" / "audio"
STAGING = Path("/tmp/wispr-decode-staging")
ARTIFACTS = Path(__file__).resolve().parent / "artifacts"

# Mirror build-golden-set.py DECODE_ARGS exactly
DECODE_ARGS = [
    "-bs", "1", "-bo", "1",
    "-tp", "0", "-tpi", "0", "-nf",
    "-mc", "128",
    "-sns",
    "-nth", "0.6", "-lpt", "-1.0", "-et", "2.4",
    "-l", "auto",
    "-nt", "-np", "-otxt",
]

BATCH = 40  # files per CLI invocation; amortises ~8s model load


# ── helpers ────────────────────────────────────────────────────────────────────

def find_cli() -> str:
    for p in CLI_CANDIDATES:
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    sys.exit(
        "No whisper-cli found in the vendored tree. Build it with:\n"
        "  cmake -B whisper.cpp/build-coreml -S whisper.cpp -DWHISPER_COREML=1\n"
        "  cmake --build whisper.cpp/build-coreml -j --target whisper-cli\n"
        "or:\n"
        "  cmake -B whisper.cpp/build-arm64 -S whisper.cpp\n"
        "  cmake --build whisper.cpp/build-arm64 -j --target whisper-cli"
    )


def check_wav_16k_mono(wav_path: str) -> bool:
    """Return True if soxi reports 16000 Hz and 1 channel; skip check if soxi absent."""
    soxi = shutil.which("soxi")
    if not soxi:
        return True  # can't verify, proceed
    try:
        rate = subprocess.run([soxi, "-r", wav_path], capture_output=True, text=True).stdout.strip()
        chans = subprocess.run([soxi, "-c", wav_path], capture_output=True, text=True).stdout.strip()
        return rate == "16000" and chans == "1"
    except Exception:
        return True  # non-fatal


def _edit_distance(a: list[str], b: list[str]) -> int:
    """Word-level edit distance (Levenshtein)."""
    m, n = len(a), len(b)
    # Use a flat array for O(m) space
    prev = list(range(n + 1))
    for i in range(1, m + 1):
        curr = [i] + [0] * n
        for j in range(1, n + 1):
            if a[i - 1] == b[j - 1]:
                curr[j] = prev[j - 1]
            else:
                curr[j] = 1 + min(prev[j], curr[j - 1], prev[j - 1])
        prev = curr
    return prev[n]


def wer(ref: str, hyp: str) -> float:
    """Simple word-level WER: edit_distance(ref_words, hyp_words) / len(ref_words)."""
    ref_w = ref.lower().split()
    hyp_w = hyp.lower().split()
    if not ref_w:
        return 0.0 if not hyp_w else 1.0
    return _edit_distance(ref_w, hyp_w) / len(ref_w)


def punct_density(text: str) -> float:
    """Trailing punctuation marks per word."""
    words = text.split()
    if not words:
        return 0.0
    punct_count = sum(1 for w in words if w and w[-1] in ".,!?;:\"')")
    return punct_count / len(words)


def casing_rate(text: str) -> float:
    """Fraction of words whose first letter is uppercase."""
    words = text.split()
    if not words:
        return 0.0
    capped = sum(1 for w in words if w and w[0].isupper())
    return capped / len(words)


def decode_batch(cli: str, wav_paths: list[str]) -> dict[str, str]:
    """Run whisper-cli on a batch of staged WAVs; return {path: transcript}."""
    if not wav_paths:
        return {}
    cmd = [cli, "--model", str(MODEL)] + DECODE_ARGS + wav_paths
    subprocess.run(cmd, capture_output=True)
    result = {}
    for p in wav_paths:
        txt = p + ".txt"
        if os.path.exists(txt):
            result[p] = open(txt).read().strip()
    return result


def percentile(sorted_vals: list[float], p: float) -> float:
    if not sorted_vals:
        return 0.0
    idx = int(len(sorted_vals) * p / 100)
    idx = min(idx, len(sorted_vals) - 1)
    return sorted_vals[idx]


# ── main ───────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="count matching rows, don't decode")
    ap.add_argument("--cli", default=None, help="explicit whisper-cli path")
    args = ap.parse_args()

    if not CORPUS_JSONL.exists():
        sys.exit(f"Corpus not found: {CORPUS_JSONL}")

    # Load corpus and filter to rows with existing WAVs
    all_rows = [json.loads(l) for l in CORPUS_JSONL.read_text().splitlines() if l.strip()]
    candidates = []
    for r in all_rows:
        ap_ = r.get("audio_path")
        if not ap_:
            continue
        wav = Path(ap_) if Path(ap_).is_absolute() else AUDIO_DIR / ap_
        if wav.exists() and wav.suffix.lower() == ".wav":
            r = dict(r)
            r["_wav"] = str(wav)
            candidates.append(r)

    print(f"corpus rows   : {len(all_rows)}")
    print(f"rows with WAV : {len(candidates)}")

    if args.dry_run:
        print("--dry-run: stopping here.")
        return

    cli = args.cli or find_cli()
    if not MODEL.exists():
        sys.exit(f"Model not found: {MODEL}\nDownload Whisperer V3 in the app's Models tab first.")

    print(f"whisper-cli   : {cli}")
    print(f"model         : {MODEL.name}")

    # Set up staging dir
    shutil.rmtree(STAGING, ignore_errors=True)
    STAGING.mkdir(parents=True)
    ARTIFACTS.mkdir(parents=True, exist_ok=True)

    # Stage WAVs as symlinks inside staging dir (avoids scattering .txt files)
    staged_map: dict[str, dict] = {}  # staged_wav_path -> row
    for row in candidates:
        wav = row["_wav"]
        staged = str(STAGING / (Path(wav).stem + "_" + row.get("transcriptEntityId", "x")[:8] + ".wav"))
        if check_wav_16k_mono(wav):
            try:
                os.symlink(wav, staged)
                staged_map[staged] = row
            except FileExistsError:
                staged_map[staged] = row
        else:
            print(f"  skip (not 16kHz mono): {wav}", file=sys.stderr)

    staged_paths = list(staged_map.keys())
    print(f"staged WAVs   : {len(staged_paths)}")

    # Decode in batches
    transcripts: dict[str, str] = {}
    for i in range(0, len(staged_paths), BATCH):
        batch = staged_paths[i: i + BATCH]
        print(f"  decoding batch {i // BATCH + 1}/{(len(staged_paths) + BATCH - 1) // BATCH} ({len(batch)} files)…")
        transcripts.update(decode_batch(cli, batch))

    # Build pairs and compute WER
    pairs = []
    failed = 0
    wers: list[float] = []

    for staged_path, row in staged_map.items():
        our_asr = transcripts.get(staged_path)
        if our_asr is None:
            failed += 1
            print(f"  decode failed: {staged_path}", file=sys.stderr)
            continue

        wispr_asr = row.get("asrText") or ""
        w = wer(wispr_asr, our_asr)
        wers.append(w)

        pairs.append({
            "wispr_asr": wispr_asr,
            "our_asr": our_asr,
            "formatted": row.get("formattedText") or "",
            "edited": row.get("editedText") or "",
            "script": row.get("detectedLanguage") or "",
            "app": row.get("app") or "",
            "wer": round(w, 4),
        })

    # Stats
    decoded = len(pairs)
    wers_sorted = sorted(wers)
    mean_wer = sum(wers) / len(wers) if wers else 0.0
    p50 = percentile(wers_sorted, 50)
    p95 = percentile(wers_sorted, 95)

    # Punctuation & casing stats
    wispr_punct = [punct_density(p["wispr_asr"]) for p in pairs if p["wispr_asr"]]
    our_punct = [punct_density(p["our_asr"]) for p in pairs if p["our_asr"]]
    wispr_case = [casing_rate(p["wispr_asr"]) for p in pairs if p["wispr_asr"]]
    our_case = [casing_rate(p["our_asr"]) for p in pairs if p["our_asr"]]

    avg = lambda lst: sum(lst) / len(lst) if lst else 0.0

    report = {
        "decoded": decoded,
        "failed": failed,
        "mean_wer": round(mean_wer, 4),
        "p50_wer": round(p50, 4),
        "p95_wer": round(p95, 4),
        "wispr_punct_density": round(avg(wispr_punct), 4),
        "our_punct_density": round(avg(our_punct), 4),
        "wispr_casing_rate": round(avg(wispr_case), 4),
        "our_casing_rate": round(avg(our_case), 4),
    }

    print("\n── Decode report ─────────────────────────────────")
    print(f"  decoded         : {decoded}")
    print(f"  failed          : {failed}")
    print(f"  mean WER        : {mean_wer:.3f}")
    print(f"  p50  WER        : {p50:.3f}")
    print(f"  p95  WER        : {p95:.3f}")
    print(f"  punct density   : wispr={avg(wispr_punct):.3f}  ours={avg(our_punct):.3f}")
    print(f"  casing rate     : wispr={avg(wispr_case):.3f}  ours={avg(our_case):.3f}")
    print("──────────────────────────────────────────────────\n")

    # Write outputs
    out_pairs = ARTIFACTS / "our_asr_pairs.jsonl"
    out_report = ARTIFACTS / "decode_report.json"

    out_pairs.write_text("\n".join(json.dumps(p, ensure_ascii=False) for p in pairs) + "\n")
    out_report.write_text(json.dumps(report, indent=2) + "\n")

    print(f"wrote {len(pairs)} pairs → {out_pairs}")
    print(f"wrote report       → {out_report}")


if __name__ == "__main__":
    main()

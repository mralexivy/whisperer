#!/usr/bin/env python3
"""Local, reproducible paired ASR evaluation. No bundled efficacy claims.

score consumes consented precomputed pairs; run invokes explicitly configured ASR
executables on clean/processed WAV pairs. It never invokes a shell or uploads audio
itself. Model adapters are caller-provided; remote adapters require --allow-remote.
"""
import argparse
import collections
import ctypes
import hashlib
import json
import math
from pathlib import Path
import random
import statistics
import subprocess
import unicodedata
import wave
from array import array

NORMALIZATION = "NFKC-casefold-punctuation-to-space-v1"


def normalize(text):
    return " ".join("".join(" " if unicodedata.category(c).startswith("P") else c
                            for c in unicodedata.normalize("NFKC", text).casefold()).split())


def edits(reference, hypothesis):
    """Levenshtein with deterministic tie breaking; returns S, D, I, N."""
    row = [(j, 0, 0, j) for j in range(len(hypothesis) + 1)]
    for i, ref in enumerate(reference, 1):
        next_row = [(i, 0, i, 0)]
        for j, hyp in enumerate(hypothesis, 1):
            if ref == hyp:
                next_row.append(row[j - 1])
                continue
            cost, s, d, ins = row[j - 1]
            substitute = (cost + 1, s + 1, d, ins)
            cost, s, d, ins = row[j]
            delete = (cost + 1, s, d + 1, ins)
            cost, s, d, ins = next_row[j - 1]
            insert = (cost + 1, s, d, ins + 1)
            next_row.append(min((substitute, delete, insert), key=lambda item: item[0]))
        row = next_row
    _, s, d, ins = row[-1]
    return {"substitutions": s, "deletions": d, "insertions": ins, "reference_units": len(reference)}


def error_rate(counts):
    n = counts["reference_units"]
    return sum(counts[k] for k in ("substitutions", "deletions", "insertions")) / n if n else None


def transcript_metrics(reference, hypothesis, facts):
    r, h = normalize(reference), normalize(hypothesis)
    if not r:
        raise ValueError("Reference must have at least one normalized word")
    words = edits(r.split(), h.split())
    chars = edits(list(r.replace(" ", "")), list(h.replace(" ", "")))
    recovered = sum(bool(normalize(f)) and f" {normalize(f)} " in f" {h} " for f in facts)
    return {"word_counts": words, "wer": error_rate(words), "cer": error_rate(chars),
            "literal_key_facts_recovered": recovered, "key_fact_count": len(facts)}


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def pooled(rows, side):
    counts = {key: sum(row[side]["word_counts"][key] for row in rows)
              for key in ("substitutions", "deletions", "insertions", "reference_units")}
    facts = sum(row[side]["key_fact_count"] for row in rows)
    return {"wer": error_rate(counts), "word_counts": counts,
            "mean_utterance_cer": statistics.mean(row[side]["cer"] for row in rows),
            "literal_key_fact_recovery": sum(row[side]["literal_key_facts_recovered"] for row in rows) / facts if facts else None}


def summarize(pairs):
    if not pairs:
        raise ValueError("Evaluation must contain at least one paired item")
    groups = collections.defaultdict(list)
    seen = set()
    for row in pairs:
        for key in ("id", "speaker", "language", "engine", "condition", "reference", "clean", "processed", "split"):
            if key not in row:
                raise ValueError(f"Missing {key}")
        if row["split"] != "evaluation":
            raise ValueError("Final score accepts evaluation split only; keep tuning in a separate corpus")
        identity = (row["id"], row["engine"], row["condition"])
        if identity in seen:
            raise ValueError(f"Duplicate pair: {identity}")
        seen.add(identity)
        facts = row.get("key_facts", [])
        result = {key: row[key] for key in ("id", "speaker", "language", "engine", "condition")}
        for side in ("clean", "processed"):
            result[side] = transcript_metrics(row["reference"], row[side], facts)
        groups[(row["engine"], row["language"], row["condition"])].append(result)
    output = []
    for (engine, language, condition), rows in sorted(groups.items()):
        speakers = sorted({row["speaker"] for row in rows})
        by_speaker = {speaker: [r for r in rows if r["speaker"] == speaker] for speaker in speakers}
        rng, bootstrap = random.Random(4281), []
        if len(speakers) >= 2:
            for _ in range(1000):
                sample = [r for speaker in rng.choices(speakers, k=len(speakers)) for r in by_speaker[speaker]]
                bootstrap.append(pooled(sample, "processed")["wer"] - pooled(sample, "clean")["wer"])
            bootstrap.sort()
        clean, processed = pooled(rows, "clean"), pooled(rows, "processed")
        output.append({"engine": engine, "language": language, "condition": condition,
                       "utterances": len(rows), "speakers": len(speakers), "clean": clean, "processed": processed,
                       "wer_delta": processed["wer"] - clean["wer"],
                       "speaker_bootstrap_95pct_wer_delta": [bootstrap[24], bootstrap[974]] if bootstrap else None})
    return {"schema_version": 1, "normalization": NORMALIZATION, "groups": output,
            "claims": "No protection score or release verdict. Literal fact matching is only a proxy; human semantic and listening evaluation are still required.",
            "raw_transcripts_included": False}


def run_engines(manifest, config, output_dir, allow_remote):
    root, destination = Path(manifest).resolve().parent, Path(output_dir).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError("Adapter work directory must be empty to prevent stale transcript reuse")
    engines = json.loads(Path(config).read_text())["engines"]
    if not engines:
        raise ValueError("Configure at least one ASR engine")
    if len({engine["name"] for engine in engines}) != len(engines):
        raise ValueError("Engine names must be unique")
    for engine in engines:
        if engine.get("remote", False) and not allow_remote:
            raise ValueError("Remote adapter rejected. Use consented data and --allow-remote explicitly.")
        if engine.get("role") not in ("tuning", "holdout"):
            raise ValueError("Every engine needs a tuning or holdout role")
        if not isinstance(engine["command"], list) or not engine["command"]:
            raise ValueError("Engine command must be a nonempty argv array")
    pairs, versions = [], []
    for engine in engines:
        versions.append({k: engine.get(k) for k in ("name", "family", "version", "role", "remote")})
    for index, row in enumerate(read_jsonl(manifest)):
        for engine_index, engine in enumerate(engines):
            pair = {k: row[k] for k in ("id", "speaker", "language", "condition", "reference", "split")}
            pair.update(engine=engine["name"], key_facts=row.get("key_facts", []))
            for side in ("clean", "processed"):
                audio = (root / row[f"{side}_audio"]).resolve(strict=True)
                if audio.suffix.lower() != ".wav":
                    raise ValueError("Use WAV files; include the recorded receiver-side condition in the manifest")
                # Filenames never use transcript text or untrusted item identifiers.
                output = destination / f"adapter-{index}-{engine_index}-{side}"
                argv = [arg.replace("{audio}", str(audio)).replace("{output}", str(output)).replace("{language}", row["language"])
                        for arg in engine["command"]]
                subprocess.run(argv, check=True, timeout=engine.get("timeout_seconds", 300),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if engine.get("format") == "whisper_json":
                    data = json.loads(output.with_suffix(".json").read_text())
                    pair[side] = " ".join(segment["text"] for segment in data["transcription"])
                    output.with_suffix(".json").unlink()
                else:
                    pair[side] = output.read_text()
                    output.unlink()
            pairs.append(pair)
    result = summarize(pairs)
    result["engines"] = versions
    result["manifest_sha256"] = hashlib.sha256(Path(manifest).read_bytes()).hexdigest()
    result["engine_config_sha256"] = hashlib.sha256(Path(config).read_bytes()).hexdigest()
    return result


def process_audio(source, destination, library, strength):
    if not 0 <= strength <= 1:
        raise ValueError("strength must be between zero and one")
    if Path(source).resolve() == Path(destination).resolve():
        raise ValueError("Never overwrite original audio")
    lib = ctypes.CDLL(str(Path(library).resolve()))
    lib.shield_baseline_create.restype = ctypes.c_void_p
    lib.shield_baseline_destroy.argtypes = [ctypes.c_void_p]
    lib.shield_baseline_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_uint32, ctypes.c_float]
    instance = lib.shield_baseline_create()
    try:
        with wave.open(str(source), "rb") as src:
            if src.getframerate() != 48000 or src.getnchannels() != 1 or src.getsampwidth() != 2:
                raise ValueError("Baseline processor requires mono 48 kHz PCM16 WAV; normalize the corpus first")
            with wave.open(str(destination), "wb") as dst:
                dst.setparams(src.getparams())
                while raw := src.readframes(480):
                    pcm = array("h", raw)
                    inp = (ctypes.c_float * len(pcm))(*(x / 32768 for x in pcm))
                    out = (ctypes.c_float * len(pcm))()
                    lib.shield_baseline_process(instance, inp, out, len(pcm), strength)
                    encoded = array("h", (round(max(-1, min(.999969, x)) * 32768) for x in out))
                    dst.writeframes(encoded.tobytes())
    finally:
        lib.shield_baseline_destroy(instance)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    score = sub.add_parser("score")
    score.add_argument("pairs"); score.add_argument("--output", required=True)
    run = sub.add_parser("run")
    run.add_argument("manifest"); run.add_argument("--engines", required=True)
    run.add_argument("--work-dir", required=True); run.add_argument("--output", required=True)
    run.add_argument("--allow-remote", action="store_true")
    process = sub.add_parser("process")
    process.add_argument("input"); process.add_argument("output"); process.add_argument("--library", required=True)
    process.add_argument("--strength", type=float, default=.35)
    args = parser.parse_args()
    if args.mode == "process":
        process_audio(args.input, args.output, args.library, args.strength)
        return
    result = summarize(read_jsonl(args.pairs)) if args.mode == "score" else run_engines(args.manifest, args.engines, args.work_dir, args.allow_remote)
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()

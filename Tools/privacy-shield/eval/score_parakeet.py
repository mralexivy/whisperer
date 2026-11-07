#!/usr/bin/env python3
"""Re-score a finished run_eval.py work directory with NVIDIA Parakeet (a different ASR family, never
used in training). Reads the saved *.{clean,shielded}.{direct16,call16}.wav files.
usage: score_parakeet.py WORK_DIR CORPUS_DIR [--model mlx-community/parakeet-tdt-0.6b-v2]"""
import argparse, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import benchmark  # noqa: E402

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("work"); ap.add_argument("corpus"); ap.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v2")
    a = ap.parse_args()
    from parakeet_mlx import from_pretrained
    model = from_pretrained(a.model)
    work = Path(a.work)
    rows = [json.loads(l) for l in (Path(a.corpus) / "corpus.jsonl").read_text().splitlines() if l.strip()]
    out = {"direct": [], "call": []}
    for r in rows:
        for cond, suffix in (("direct", "direct16"), ("call", "call16")):
            clean = model.transcribe(str(work / f"{r['id']}.clean.{suffix}.wav")).text
            shielded = model.transcribe(str(work / f"{r['id']}.shielded.{suffix}.wav")).text
            drift = benchmark.transcript_metrics(clean or "empty", shielded, [])["wer"]
            facts = benchmark.transcript_metrics(r["reference"], shielded, r["key_facts"])
            cf = benchmark.transcript_metrics(r["reference"], clean, r["key_facts"])
            out[cond].append({"id": r["id"], "drift": drift,
                              "facts": facts["literal_key_facts_recovered"] / max(1, facts["key_fact_count"]),
                              "clean_facts": cf["literal_key_facts_recovered"] / max(1, cf["key_fact_count"]),
                              "clean": clean, "shielded": shielded})
    summary = {c: {"drift": round(sum(x["drift"] for x in v) / len(v), 3),
                   "key_facts": round(sum(x["facts"] for x in v) / len(v), 3),
                   "clean_key_facts": round(sum(x["clean_facts"] for x in v) / len(v), 3)} for c, v in out.items()}
    (work / "parakeet.json").write_text(json.dumps({"summary": summary, "clips": out}, indent=2))
    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    main()

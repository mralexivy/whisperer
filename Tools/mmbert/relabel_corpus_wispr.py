#!/usr/bin/env python3
"""Re-label the Wispr corpus audio via the Wispr chain API.

Reads ~/wispr_corpus/corpus.jsonl, picks rows that have an audio_path,
reads the WAV from ~/wispr_corpus/audio/, sends it to the Baseten chain
(Whisper ASR + Llama-3.1-8B formatter), and writes the returned
(asr_text, llm_text) pair to artifacts/data/wispr_relabeled.jsonl.

Credentials:
    Set WISPR_BASETEN_API_KEY in your shell, or pass --api-key.
    The JWT is read from ~/Library/Application Support/Wispr Flow/session.json.

Usage:
    ./.venv/bin/python relabel_corpus_wispr.py [--dry-run] [--out artifacts/data]
"""
from __future__ import annotations

import argparse
import base64
import difflib
import json
import os
import time
from pathlib import Path
from typing import Optional

import requests  # pip install requests (already in venv)

HERE = Path(__file__).resolve().parent
CORPUS = Path(os.path.expanduser("~/wispr_corpus/corpus.jsonl"))
AUDIO_DIR = Path(os.path.expanduser("~/wispr_corpus/audio"))
SESSION_JSON = Path(os.path.expanduser(
    "~/Library/Application Support/Wispr Flow/session.json"
))

CHAIN_URL = "https://chain-o232k03l.api.baseten.co/environments/production/run_remote"
USER_UUID = "5a6a30a4-902b-4cc6-b48c-5a758dbcca06"

SLEEP_S = 0.25   # inter-request delay
MIN_ASR_RATIO = 0.80  # SequenceMatcher ratio between chain asr_text and corpus asrText


def load_jwt() -> str:
    d = json.loads(SESSION_JSON.read_text())
    for k, v in d.items():
        if "auth" in k.lower():
            if isinstance(v, str):
                try:
                    v = json.loads(v)
                except Exception:
                    pass
            if isinstance(v, dict):
                tok = v.get("access_token", "")
                if tok:
                    return tok
    raise RuntimeError(f"Could not find access_token in {SESSION_JSON}")


def detect_script_simple(text: str) -> str:
    he = ru = la = 0
    for ch in text:
        o = ord(ch)
        if 0x0590 <= o <= 0x05FF or 0xFB1D <= o <= 0xFB4F:
            he += 1
        elif 0x0400 <= o <= 0x04FF:
            ru += 1
        elif ch.isalpha() and ch.isascii():
            la += 1
    total = he + ru + la
    if total < 3:
        return "unk"
    if he / total > 0.20:
        return "he"
    if ru / total > 0.20:
        return "ru"
    return "en"


def call_chain(audio_b64: str, jwt: str, api_key: str,
               lang_hint: list[str], session_id: str) -> dict:
    payload = {
        "request": {
            "access_token": jwt,
            "audio": audio_b64,
            "pipeline": [],
            "context": {"appBundleId": "other"},
            "language": lang_hint,
            "app": "other",
            "user": {"uuid": USER_UUID},
            "metadata": {
                "session_id": session_id,
                "platform": "macos",
                "source": "relabel_corpus",
            },
        }
    }
    resp = requests.post(
        CHAIN_URL,
        headers={"Authorization": f"Api-Key {api_key}", "Content-Type": "application/json"},
        json=payload,
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()


def asr_match_ratio(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(HERE / "artifacts/data"))
    parser.add_argument("--api-key", default=os.environ.get("WISPR_BASETEN_API_KEY", ""))
    parser.add_argument("--dry-run", action="store_true",
                        help="Process first 3 rows only and print results without writing")
    parser.add_argument("--limit", type=int, default=0, help="Max rows to process (0=all)")
    args = parser.parse_args()

    if not args.api_key:
        raise SystemExit(
            "Set WISPR_BASETEN_API_KEY or pass --api-key. "
            "The key is in /Applications/Wispr Flow.app/.webpack/main/index.js (module 47708)."
        )

    jwt = load_jwt()
    print(f"JWT loaded ({len(jwt)} chars)")

    rows = [json.loads(l) for l in CORPUS.read_text().splitlines() if l.strip()]
    audio_rows = [r for r in rows if r.get("audio_path")]
    print(f"Corpus: {len(rows)} total, {len(audio_rows)} with audio_path")

    if args.dry_run:
        audio_rows = audio_rows[:3]

    if args.limit > 0:
        audio_rows = audio_rows[:args.limit]

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "wispr_relabeled.jsonl"

    stats = {"sent": 0, "accepted": 0, "skipped_status": 0,
             "skipped_ratio": 0, "error": 0}

    with out_path.open("w", encoding="utf-8") as fout:
        for i, row in enumerate(audio_rows):
            audio_path = AUDIO_DIR / Path(row["audio_path"]).name
            if not audio_path.exists():
                print(f"[{i}] SKIP missing file: {audio_path}")
                continue

            audio_bytes = audio_path.read_bytes()
            audio_b64 = base64.b64encode(audio_bytes).decode()

            asr_text = (row.get("asrText") or "").strip()
            script = detect_script_simple(asr_text)
            lang_hint = {"en": ["en"], "he": ["he"], "ru": ["ru"]}.get(script, [])
            session_id = row.get("transcriptEntityId", f"row_{i}")

            stats["sent"] += 1
            try:
                resp = call_chain(audio_b64, jwt, args.api_key, lang_hint, session_id)
            except Exception as e:
                print(f"[{i}] ERROR: {e}")
                stats["error"] += 1
                time.sleep(SLEEP_S)
                continue

            status = resp.get("status", "")
            chain_asr = (resp.get("asr_text") or "").strip()
            chain_llm = (resp.get("llm_text") or "").strip()

            if status not in ("formatted", "raw_transcript") or not chain_llm:
                print(f"[{i}] SKIP status={status!r} asr={chain_asr[:40]!r}")
                stats["skipped_status"] += 1
                time.sleep(SLEEP_S)
                continue

            # Verify ASR fidelity — chain must agree with our existing asrText
            ratio = asr_match_ratio(chain_asr, asr_text) if asr_text else 1.0
            if ratio < MIN_ASR_RATIO:
                print(f"[{i}] SKIP ratio={ratio:.2f} chain={chain_asr[:40]!r} "
                      f"corpus={asr_text[:40]!r}")
                stats["skipped_ratio"] += 1
                time.sleep(SLEEP_S)
                continue

            out_row = {
                "asrText": chain_asr or asr_text,
                "formattedText": chain_llm,
                "detectedLanguage": resp.get("detected_language", script),
                "source": "wispr_relabeled",
                "transcriptEntityId": session_id,
            }
            print(f"[{i}] OK status={status!r} ratio={ratio:.2f} "
                  f"asr={chain_asr[:50]!r} → llm={chain_llm[:50]!r}")
            if not args.dry_run:
                fout.write(json.dumps(out_row, ensure_ascii=False) + "\n")
            stats["accepted"] += 1
            time.sleep(SLEEP_S)

    print(f"\nDone: {stats}")
    if not args.dry_run:
        print(f"Output: {out_path} ({stats['accepted']} rows)")


if __name__ == "__main__":
    main()

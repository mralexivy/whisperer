#!/bin/bash
# One command for the Wispr-corpus retrain.
#
# Order:
#   1. build_wispr_corpus    -- mine Wispr pairs into wispr_train.jsonl / wispr_val.jsonl
#   2. build_eval_large      -- pin holdout (if not already done)
#   3. build_corpus          -- merge all sources (no Wikipedia) into artifacts/data/
#   4. train                 -- 3 epochs (more data = more epochs than history retrain)
#   5. calibrate             -- fresh cache against pinned holdout
#   6. export_coreml         -- if training succeeded
#
# Usage:
#   ./run_wispr_retrain.sh [--skip-corpus] [--skip-train] [--dry-run]
#
# Flags:
#   --skip-corpus   skip steps 1-3 (use existing artifacts/data/)
#   --skip-train    skip step 4 (calibrate existing artifacts/model-wispr/)
#   --dry-run       print commands only
set -euo pipefail
cd "$(dirname "$0")"

PY=./.venv/bin/python
GOLDEN=artifacts/raw/history-golden.json
A=artifacts

SKIP_CORPUS=0
SKIP_TRAIN=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --skip-corpus) SKIP_CORPUS=1 ;;
        --skip-train)  SKIP_TRAIN=1  ;;
        --dry-run)     DRY_RUN=1     ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

run() {
    echo "  + $*"
    if [ "$DRY_RUN" -eq 0 ]; then
        "$@"
    fi
}

if [ "$SKIP_CORPUS" -eq 0 ]; then
    # ── Step 1: build Wispr corpus ──────────────────────────────────────────
    echo "=== 1/6 build_wispr_corpus  $(date +%T)"
    run $PY build_wispr_corpus.py \
        --corpus ~/wispr_corpus/corpus.jsonl \
        --audio-dir ~/wispr_corpus/audio/ \
        --our-asr "$A/our_asr_pairs.jsonl" \
        --out-train data/wispr_train.jsonl \
        --out-val   data/wispr_val.jsonl \
        --report    "$A/wispr_corpus_report.json" \
        > "$A/build_wispr_corpus.log" 2>&1
    grep -E "^\[" "$A/build_wispr_corpus.log" || true

    # ── Step 2: pin the history holdout ─────────────────────────────────────
    echo "=== 2/6 build_eval_large  $(date +%T)"
    run $PY build_eval_large.py \
        --golden "$GOLDEN" \
        --train-frac 0.55 --min-eval 300 \
        --report "$A/eval_real_large_report_wispr.json" \
        > "$A/build_eval_large_wispr.log" 2>&1
    grep -E "^\[" "$A/build_eval_large_wispr.log" || true

    # ── Step 3: merge all sources (no Wikipedia) ─────────────────────────────
    echo "=== 3/6 build_corpus  $(date +%T)"
    run $PY build_corpus.py \
        --golden "$GOLDEN" \
        --wiki-en 0 --wiki-he 0 --wiki-ru 0 \
        --indomain-repeats 8 --teacher-repeat 6 \
        --extra-train data/train_real_large.jsonl --extra-train-repeat 6 \
        --extra-train "data/wispr_train.jsonl" --extra-train-repeat 4 \
        --holdout data/eval_real_large.jsonl \
        --holdout data/wispr_val.jsonl \
        > "$A/build_corpus_wispr.log" 2>&1
    grep -E "^\[" "$A/build_corpus_wispr.log" || true
fi

if [ "$SKIP_TRAIN" -eq 0 ]; then
    # ── Step 4: train (3 epochs — more data warrants one extra pass) ─────────
    echo "=== 4/6 train  $(date +%T)"
    run $PY train.py \
        --epochs 3 \
        --out "$A/model-wispr" \
        --head-weights "error=0.5,punct=1.0,case=1.0,disf=1.0,append=1.5,repl=1.5,merge=0.8,para=1.0" \
        --script-balance "en=1.0,he=3.0,ru=3.0" \
        > "$A/train_wispr.log" 2>&1
    tail -5 "$A/train_wispr.log"
fi

# ── Step 5: calibrate ────────────────────────────────────────────────────────
echo "=== 5/6 calibrate  $(date +%T)"
# A fresh --cache: calib_rows_wispr.json holds proposals for the previous
# checkpoint, and reusing it would calibrate thresholds for a model that no
# longer exists.
run $PY calibrate.py \
    --model "$A/model-wispr" \
    --cache "$A/calib_rows_wispr.json" \
    --sweeps "$A/calib_sweeps_wispr.json" \
    --out thresholds-calibrated-wispr.json \
    > "$A/calibrate_wispr.log" 2>&1
tail -40 "$A/calibrate_wispr.log"

# ── Step 6: export CoreML ────────────────────────────────────────────────────
echo "=== 6/6 export_coreml  $(date +%T)"
if [ -d "$A/model-wispr" ]; then
    run $PY export_coreml.py \
        --model "$A/model-wispr" \
        --out "$A/mmbert-wispr.mlpackage" \
        > "$A/export_coreml_wispr.log" 2>&1
    tail -10 "$A/export_coreml_wispr.log"
else
    echo "  model-wispr not found — skipping CoreML export"
fi

echo "=== done  $(date +%T)"

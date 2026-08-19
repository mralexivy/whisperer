#!/bin/bash
# One command for the whole history-only retrain, so the steps chain themselves
# instead of being babysat between each one. Every step logs to artifacts/.
#
#   ./run_history_retrain.sh
#
# Order matters and is not obvious:
#   1. build_eval_large  -- mines real pairs from the FULL history decode and
#      pins the previous 326-pair holdout so the retrain is scored on the same
#      set the first run was. Must run BEFORE build_corpus, because it produces
#      the holdout that build_corpus has to exclude.
#   2. build_corpus      -- history-only clean text (no Wikipedia), with the
#      holdout excluded from the corruption pool and the strictly-audited real
#      pairs folded into train.
#   3. train             -- 2 epochs.
#   4. calibrate         -- against the pinned holdout.
set -euo pipefail
cd "$(dirname "$0")"

PY=./.venv/bin/python
GOLDEN=artifacts/raw/history-golden.json
A=artifacts

echo "=== 1/4 build_eval_large  $(date +%T)"
$PY build_eval_large.py \
    --golden "$GOLDEN" \
    --train-frac 0.55 --min-eval 300 \
    --report "$A/eval_real_large_report.json" > "$A/build_eval_large.log" 2>&1
grep -E "^\[" "$A/build_eval_large.log" || true

echo "=== 2/4 build_corpus  $(date +%T)"
$PY build_corpus.py \
    --golden "$GOLDEN" \
    --wiki-en 0 --wiki-he 0 --wiki-ru 0 \
    --indomain-repeats 8 --teacher-repeat 6 \
    --extra-train data/train_real_large.jsonl --extra-train-repeat 6 \
    --holdout data/eval_real_large.jsonl > "$A/build_corpus_history.log" 2>&1
grep -E "^\[" "$A/build_corpus_history.log" || true

echo "=== 3/4 train  $(date +%T)"
$PY train.py --epochs 2 --out "$A/model-history" > "$A/train_history.log" 2>&1
tail -5 "$A/train_history.log"

echo "=== 4/4 calibrate  $(date +%T)"
# A fresh --cache: calib_rows.json holds the OLD checkpoint's per-word proposals,
# and reusing it would calibrate thresholds for a model that no longer exists.
$PY calibrate.py --model "$A/model-history" \
    --cache "$A/calib_rows_history.json" \
    --sweeps "$A/calib_sweeps_history.json" \
    --out thresholds-calibrated-history.json \
    > "$A/calibrate_history.log" 2>&1
tail -40 "$A/calibrate_history.log"

echo "=== done  $(date +%T)"

#!/bin/bash
# run_gold_retrain.sh -- the authored-reference retrain, end to end.
#
#   ./run_gold_retrain.sh
#
# Sibling of run_history_retrain.sh, which it does NOT replace. That script and
# its outputs (artifacts/model-history, thresholds-calibrated-history.json,
# artifacts/calib_rows_history.json) are left untouched so the two runs stay
# comparable; everything here writes to a new path.
#
# What is different from the history run
# --------------------------------------
# The history run calibrated against pairs whose reference side was produced by
# the same Qwen-4B teacher the model was distilled from. A student and its
# teacher share their mistakes, so that measurement cannot see the errors that
# matter -- it flatters precision in exactly the direction that then fails the
# gate. This run calibrates against an independently authored reference corpus
# (Tools/llm-eval/authoring/gold-corpus.json, ~150 cases, punctuation / casing /
# paragraphing / filler removal / obvious grammar only) and folds the rest of
# that corpus into training.
#
# Order matters and is not obvious:
#   1. build_eval_large -- mines real pairs from the full history decode and
#      re-pins the previous holdout. Must run BEFORE build_corpus, which has to
#      exclude that holdout. Its leakage source is the PREVIOUS run's
#      artifacts/data/train.jsonl, which is why it goes first.
#   2. build_gold_split -- authored corpus -> edit labels, split BY CASE ID into
#      a calibration holdout and a training slice. Must run before build_corpus
#      so the holdout can be passed as --holdout.
#   3. build_corpus     -- history-only clean text, with BOTH holdouts excluded
#      from the corruption pool, the teacher pairs and the extra-train files.
#   4. leak check       -- hard stop if any holdout key reached train/val.
#   5. train            -- 2 epochs.
#   6. calibrate        -- primary split = the authored holdout.
set -euo pipefail
cd "$(dirname "$0")"

PY=./.venv/bin/python
GOLDEN=artifacts/raw/history-golden.json
GOLD=../llm-eval/authoring/gold-corpus.json
A=artifacts

# --- seeds, recorded here because a run whose split cannot be reproduced
#     cannot be audited ---
SEED_EVAL=20260817      # build_eval_large: train/eval split of the history pairs
SEED_GOLD=20260818      # build_gold_split: sha1 salt for the by-id split
SEED_CORPUS=1234        # build_corpus: corruption RNG
SEED_TRAIN=1234         # train: torch / numpy / random

# --- how hard to upweight the authored pairs in training ---
#
# ~45 authored pairs land on the training side against ~22,000 corpus rows. At
# x1 they are 0.2% of the corpus and cannot move a gradient; the temptation is
# to crank the factor until they can. That temptation is the trap: 45 examples
# repeated enough times to matter get memorised, and a memorised training set
# does not generalise to the calibration holdout -- it just makes the training
# loss look good.
#
# x12 is deliberately modest: double the teacher pairs' x6 (the labels are
# authored under a no-paraphrase constraint rather than distilled from a 4B, so
# they are worth more per row), which puts them at ~2.4% of the corpus and shows
# each pair 24 times across 2 epochs. The honest expectation is that this makes
# very little difference either way; the authored corpus earns its keep on the
# calibration side, not here. If a future run wants to test the supervision
# hypothesis properly it needs more authored pairs, not a bigger multiplier.
GOLD_TRAIN_REPEAT=12
GOLD_CALIB_FRAC=0.70    # 70% of cases to calibration -- see build_gold_split.py

if [ ! -f "$GOLD" ]; then
    echo "!!! $GOLD does not exist."
    echo "!!! Refusing to run: this script exists to calibrate against it."
    exit 2
fi

# Snapshot what step 1 and 3 overwrite, so the history run stays reconstructible.
if [ ! -d data.backup-pre-gold ]; then
    cp -R data data.backup-pre-gold
    echo "[snapshot] data -> data.backup-pre-gold"
fi
if [ ! -d "$A/data.backup-pre-gold" ]; then
    cp -R "$A/data" "$A/data.backup-pre-gold"
    echo "[snapshot] $A/data -> $A/data.backup-pre-gold"
fi

echo "=== 1/6 build_eval_large  $(date +%T)"
$PY build_eval_large.py \
    --golden "$GOLDEN" \
    --seed "$SEED_EVAL" \
    --train-frac 0.55 --min-eval 300 \
    --report "$A/eval_real_large_report.json" > "$A/build_eval_large_gold.log" 2>&1
grep -E "^\[" "$A/build_eval_large_gold.log" || true

echo "=== 2/6 build_gold_split  $(date +%T)"
$PY build_gold_split.py \
    --gold "$GOLD" \
    --seed "$SEED_GOLD" \
    --calib-frac "$GOLD_CALIB_FRAC" \
    --out-calib "$A/data/eval_gold.jsonl" \
    --out-train data/gold_train.jsonl \
    --report "$A/gold_split_report.json" > "$A/build_gold_split.log" 2>&1
cat "$A/build_gold_split.log"

echo "=== 3/6 build_corpus  $(date +%T)"
$PY build_corpus.py \
    --golden "$GOLDEN" \
    --seed "$SEED_CORPUS" \
    --wiki-en 0 --wiki-he 0 --wiki-ru 0 \
    --indomain-repeats 8 --teacher-repeat 6 \
    --extra-train data/train_real_large.jsonl --extra-train-repeat 6 \
    --extra-train-weighted "data/gold_train.jsonl:$GOLD_TRAIN_REPEAT" \
    --holdout data/eval_real_large.jsonl \
    --holdout "$A/data/eval_gold.jsonl" > "$A/build_corpus_gold.log" 2>&1
grep -E "^\[" "$A/build_corpus_gold.log" || true

echo "=== 4/6 leak check  $(date +%T)"
$PY check_gold_leak.py \
    --holdout "$A/data/eval_gold.jsonl" \
    --holdout data/eval_real_large.jsonl \
    --train "$A/data/train.jsonl" \
    --train "$A/data/val.jsonl" 2>&1 | tee "$A/leak_check_gold.log"

echo "=== 5/6 train  $(date +%T)"
$PY train.py --epochs 2 --seed "$SEED_TRAIN" \
    --out "$A/model-gold" > "$A/train_gold.log" 2>&1
tail -5 "$A/train_gold.log"

echo "=== 6/6 calibrate  $(date +%T)"
# A fresh --cache: the cached rows hold a previous checkpoint's per-word
# proposals, and reusing them would calibrate thresholds for a model that no
# longer exists.
$PY calibrate.py --model "$A/model-gold" \
    --extra-split "eval_gold.jsonl=authored_reference_holdout (LLM-authored gold, held out BY CASE ID; independent of the 4B teacher)" \
    --primary eval_gold.jsonl \
    --cache "$A/calib_rows_gold.json" \
    --sweeps "$A/calib_sweeps_gold.json" \
    --out thresholds-calibrated-gold.json \
    > "$A/calibrate_gold.log" 2>&1
tail -60 "$A/calibrate_gold.log"

echo "=== done  $(date +%T)"

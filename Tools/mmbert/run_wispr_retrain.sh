#!/bin/bash
# Wispr-corpus retrain — all 3 languages (en / he / ru).
#
# Steps:
#   1. build_wispr_corpus    -- dictation pairs (mostly en)
#   2. build_eval_large      -- pin holdout from history recordings
#   2b. build_meeting_corpus -- meeting pairs (he + ru heavy)
#   3. build_corpus          -- merge all, no Wikipedia
#   4. train                 -- 4 epochs, script-balanced for he/ru
#   5. calibrate             -- fresh cache
#   6. export_coreml         -- fixed-shape mlpackage
#
# Usage:
#   ./run_wispr_retrain.sh [--skip-corpus] [--skip-train] [--dry-run]
set -euo pipefail
cd "$(dirname "$0")"

PY=./.venv/bin/python
# The golden set that ships with the repo. The previous value pointed at
# artifacts/raw/history-golden.json, which does not exist — step 2 died with
# FileNotFoundError on every run.
GOLDEN=../../WhispererTests/TestData/golden-set.json
A=artifacts
D=data                    # pre-existing history data dir
AD=$A/data                # generated corpus output dir

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

mkdir -p "$AD"

if [ "$SKIP_CORPUS" -eq 0 ]; then
    # ── Step 1: Wispr dictation corpus (en-dominant) ─────────────────────────
    echo "=== 1/6 build_wispr_corpus  $(date +%T)"
    run $PY build_wispr_corpus.py \
        --corpus ~/wispr_corpus/corpus.jsonl \
        --out "$AD" \
        > "$A/build_wispr_corpus.log" 2>&1
    grep -E "train|val|Accepted|script" "$A/build_wispr_corpus.log" | tail -10 || true

    # ── Step 2: pin history holdout ──────────────────────────────────────────
    echo "=== 2/6 build_eval_large  $(date +%T)"
    run $PY build_eval_large.py \
        --golden "$GOLDEN" \
        --train-frac 0.55 \
        --min-eval 300 \
        > "$A/build_eval_large_wispr.log" 2>&1
    tail -5 "$A/build_eval_large_wispr.log" || true

    # ── Step 2b: meeting corpus (he=499, ru=248, en=207 grouped documents) ──
    # Segments are grouped into 60-120 word documents so PARA_BREAK exists
    # inside an example; this is the only he/ru supply for the para head.
    echo "=== 2b/6 build_meeting_corpus  $(date +%T)"
    run $PY build_meeting_corpus.py \
        --out "$AD" \
        > "$A/build_meeting_corpus.log" 2>&1
    grep -E "Accepted|en:|he:|ru:|Wrote" "$A/build_meeting_corpus.log" || true

    # ── Step 3: merge — no Wikipedia, all 3 languages ────────────────────────
    # Weighting rationale (before script-balance in trainer):
    #   wispr dictation: high quality en, 6x
    #   meeting:         real he/ru, 5x (heavy)
    #   train_real_large: in-domain en, 5x
    #   gold_train:      authored, 8x
    echo "=== 3/6 build_corpus  $(date +%T)"
    run $PY build_corpus.py \
        --golden "$GOLDEN" \
        --wiki-en 0 --wiki-he 0 --wiki-ru 0 \
        --indomain-repeats 5 \
        --extra-train-weighted "$AD/wispr_train.jsonl:6" \
        --extra-train-weighted "$AD/meeting_train.jsonl:5" \
        --extra-train-weighted "$D/train_real_large.jsonl:5" \
        --extra-train-weighted "$D/gold_train.jsonl:8" \
        --holdout "$D/eval_real_large.jsonl" \
        --holdout "$AD/wispr_val.jsonl" \
        --holdout "$AD/meeting_val.jsonl" \
        > "$A/build_corpus_wispr.log" 2>&1
    tail -10 "$A/build_corpus_wispr.log" || true
fi

if [ "$SKIP_TRAIN" -eq 0 ]; then
    # ── Step 4: train — 4 epochs, aggressively balance he/ru ─────────────────
    # script-balance: ru=4.0 (least data), he=2.5 (1025 pairs but still under en),
    #                 en=1.0 (dominant by raw count, needs no boost)
    # head-weights: append/repl 1.5x (new heads, need more gradient)
    #               para 1.5x — plus train.py defaults --para-keep-bias 0
    #                    (no KEEP prior) and --para-weight 8 (non-NONE class
    #                    weight boost). The head-weight alone did not stop the
    #                    first run collapsing to zero proposals.
    #               error 0.5x (simpler task, reduce domination)
    # Watch the per-epoch "[val] ... head=<h> nonNONE_pred=" lines: any head at
    # 0 is a collapse and step 5b will fail the run over it.
    echo "=== 4/6 train  $(date +%T)"
    run $PY train.py \
        --epochs 4 \
        --out "$A/model-wispr" \
        --script-balance "en=1.0,he=2.5,ru=4.0" \
        --head-weights "error=0.5,punct=1.0,case=1.0,disf=1.0,append=1.5,repl=1.5,merge=0.8,para=1.5" \
        > "$A/train_wispr.log" 2>&1
    tail -10 "$A/train_wispr.log"
fi

# ── Step 5: calibrate ────────────────────────────────────────────────────────
echo "=== 5/6 calibrate  $(date +%T)"
# Fresh cache — a stale calib_rows_wispr.json calibrates the WRONG checkpoint.
run $PY calibrate.py \
    --model "$A/model-wispr" \
    --cache "$A/calib_rows_wispr.json" \
    --sweeps "$A/calib_sweeps_wispr.json" \
    --out thresholds-calibrated-wispr.json \
    > "$A/calibrate_wispr.log" 2>&1
tail -40 "$A/calibrate_wispr.log"

# ── Step 5b: assert no head is collapsed ─────────────────────────────────────
# `set -euo pipefail` catches crashes only. The first wispr run completed with a
# clean exit code while the `para` head made ZERO proposals at every threshold —
# all 27 of its cells came back support=0 — and it shipped. A head that proposes
# nothing is a build failure, not a calibration result.
echo "=== 5b/6 assert no collapsed head  $(date +%T)"
if [ "$DRY_RUN" -eq 0 ]; then
    $PY - thresholds-calibrated-wispr.json <<'PYEOF'
import json, sys
from collections import defaultdict

path = sys.argv[1]
cells = json.load(open(path))["cells"]

support = defaultdict(int)
seen = defaultdict(int)
for name, c in cells.items():
    if c.get("action") == "ALL":      # aggregate cell, never enabled
        continue
    head = c["head"]
    seen[head] += 1
    support[head] += int(c.get("max_support_any_threshold") or 0)

dead = sorted(h for h, n in seen.items() if support[h] == 0)
for head in sorted(seen):
    print(f"  {head}: cells={seen[head]} max_support_any_threshold={support[head]}")
if dead:
    print(f"FAIL: head(s) with zero proposals at every threshold: "
          f"{', '.join(dead)}", file=sys.stderr)
    print("A collapsed head must not ship. Check the [val] head=... lines in "
          f"the train log for nonNONE_pred=0.", file=sys.stderr)
    sys.exit(1)
print("OK: every head produced at least one proposal.")
PYEOF
fi

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

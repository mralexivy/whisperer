#!/bin/zsh
cd "$(dirname "$0")/.."
M="manifests/{lang}.jsonl"
for spec in "nemotron nemotron-hint hint" "nemotron nemotron-auto auto" "qwen3 qwen3 hint" "omni10 omni10 hint" "omni5 omni5 hint"; do
  set -- ${=spec}
  /private/tmp/claude-501/-Users-alexivy-ai-whisperer/52f44c15-5b27-5cd8-b2cf-6e69e872be04/scratchpad/streambench/.build/release/streambench $1 --manifest "$M" --langs he,ru,en --n 6 --hop 1.0 --lang-mode $3 --out results/rt-$2-idle.jsonl 2>&1 | grep -E "^done|rror|Fatal"
done
echo RT_DONE

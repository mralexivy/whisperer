#!/bin/zsh
cd "$(dirname "$0")/.."
M="manifests/{lang}.jsonl"
for mode in hint auto; do
  for lang in he ru en; do
    [ $mode = auto ] && [ $lang != he ] && continue
    for n in 8 16 24 32 40 48 56 64 72 80 88 96 100; do
      /private/tmp/claude-501/-Users-alexivy-ai-whisperer/52f44c15-5b27-5cd8-b2cf-6e69e872be04/scratchpad/streambench/.build/release/streambench nemotron --manifest "$M" --langs $lang --n $n --min 0 --max 40 --speed 4 --lang-mode $mode --out results/rt-nemotron-$mode-full.jsonl 2>&1 | grep -E "^done|rror|Fatal|Abort" | sed "s/^/$mode $lang n=$n: /"
    done
  done
  for n in 4 8 12 16 20 24 28 32 36 40; do
    /private/tmp/claude-501/-Users-alexivy-ai-whisperer/52f44c15-5b27-5cd8-b2cf-6e69e872be04/scratchpad/streambench/.build/release/streambench nemotron --manifest "$M" --langs cs --n $n --min 0 --max 60 --speed 4 --lang-mode $mode --out results/rt-nemotron-$mode-full.jsonl 2>&1 | grep -E "^done|rror|Fatal|Abort" | sed "s/^/$mode cs n=$n: /"
  done
done
echo NEMO_FULL_DONE

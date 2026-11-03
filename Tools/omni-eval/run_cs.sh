#!/bin/zsh
cd "$(dirname "$0")"
for e in omni-7b-4 omni-3b-4 whisper-turbo qwen3-1.7b; do python3 run_engine.py $e cs; done
echo CS_DONE

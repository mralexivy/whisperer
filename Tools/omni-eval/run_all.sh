#!/bin/zsh
cd "$(dirname "$0")"
python3 run_engine.py omni-7b-4 ru en
python3 run_engine.py omni-3b-4 ru en
python3 run_engine.py whisper-turbo ru en
python3 run_engine.py qwen3-1.7b he ru en
python3 run_engine.py parakeet ru en
echo ALL_DONE

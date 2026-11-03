#!/bin/zsh
cd "$(dirname "$0")/.."
for k in wbase-cml-cpu wbase-cml-gpu omni300-cml-10; do
  rm -f /tmp/qstop; python3 qwen_loop.py with-$k --until-file /tmp/qstop &
  QP=$!
  sleep 8
  python3 stream_preview.py $k --n 6 --step 2.0 --tag loaded
  touch /tmp/qstop; wait $QP
  echo "== therm after $k"; pmset -g therm 2>&1 | head -4
done
echo LOADED_DONE

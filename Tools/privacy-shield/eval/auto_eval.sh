#!/bin/zsh
# Waits for step milestone checkpoints and evaluates each on the held-out Whisper model through the
# call proxy, appending one JSON line per checkpoint to results.jsonl. Monitor this file for numbers.
set -u
ROOT=/Users/alexivy/ai/whisperer-shield
E=$ROOT/build/privacy-shield/eval
RUN=$E/runs/pnet-rel
PYW=/Users/alexivy/ai/whisperer-landing/.tts-venv/bin/python
PYT=$E/.venv/bin/python
WC=/Users/alexivy/ai/whisperer/whisper.cpp/build-static/bin/whisper-cli
MODEL="$HOME/Library/Application Support/Whisperer/ggml-large-v3-turbo-q5_0.bin"
RES=$RUN/results.jsonl
: > $RES
for step in 00200 00500 01000 01500 02000; do
  CK=$RUN/step$step.pt
  until [ -f "$CK" ]; do sleep 30; [ -f "$RUN/.done" ] && [ ! -f "$CK" ] && break; done
  [ -f "$CK" ] || continue
  sleep 3
  $PYT -I $ROOT/Tools/privacy-shield/eval/export_pnet.py "$CK" $RUN/eval-$step.wspn >/dev/null 2>&1
  OUT=$($PYW -I $ROOT/Tools/privacy-shield/eval/run_eval.py $E/corpus --work $RUN/eval-$step \
     --whisper-cli $WC --model "$MODEL" --processor native:$RUN/eval-$step.wspn \
     --rnnoise $E/models/rn.rnnn --label "step$step" 2>/dev/null | $PYT -c 'import sys,json;t=sys.stdin.read();j=json.loads(t[t.index(chr(10)+chr(123))+1:]);c=j["conditions"]["call/shielded"];print(json.dumps({"step":"'$step'","call_wer_vs_clean":c["wer_vs_clean"],"call_key_facts":c["key_fact_recall"],"snr":j["mean_snr_db"]}))')
  echo "$OUT" | tee -a $RES
done
echo '{"done":true}' | tee -a $RES

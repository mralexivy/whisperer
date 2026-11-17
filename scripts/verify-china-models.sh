#!/bin/bash
# Checks that every model the China edition downloads is really on ModelScope, and that the whisper.cpp files
# are byte-identical to the checksums pinned in the app. Run before submitting the China build:
#
#   scripts/verify-china-models.sh
#
# The list below mirrors `ModelSources` (Whisperer/Transcription/ModelSources.swift): when that table changes,
# change this list. Needs only curl, jq and the standard macOS tools.
set -u
cd "$(dirname "$0")/.."

LIST="https://www.modelscope.cn/api/v1/models"
FAILS=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

listing() { curl -fsS -m 40 "$LIST/$1/repo/files?Recursive=true&Revision=master"; }

echo "whisper.cpp weights (community copy, must match the pinned SHA-256)"
repo="cjc1887415157/whisper.cpp"
json=$(listing "$repo") || { fail "$repo: listing unreachable"; json=""; }
for file in ggml-base.bin ggml-small.bin ggml-medium.bin ggml-large-v3.bin ggml-large-v3-q5_0.bin; do
  pinned=$(grep "\"$file\":" Whisperer/Transcription/ModelChecksums.swift | sed -E 's/.*: "([0-9a-f]{64})".*/\1/')
  remote=$(printf '%s' "$json" | jq -r --arg f "$file" '.Data.Files[] | select(.Path==$f) | .Sha256' 2>/dev/null)
  if [ -z "$remote" ]; then fail "$file: not on $repo"
  elif [ "$remote" = "$pinned" ]; then ok "$file"
  else fail "$file: ModelScope $remote != pinned $pinned"; fi
done

echo "Silero VAD"
json=$(listing "ggml-org/whisper-vad") || json=""
remote=$(printf '%s' "$json" | jq -r '.Data.Files[] | select(.Path=="ggml-silero-v6.2.0.bin") | .Sha256' 2>/dev/null)
[ -n "$remote" ] && ok "ggml-silero-v6.2.0.bin ($remote)" || fail "ggml-silero-v6.2.0.bin: not on ModelScope"

echo "MLX models (need config.json and weights)"
for repo in mlx-community/Qwen3-ASR-1.7B-8bit mlx-community/Qwen3.5-2B-MLX-4bit mlx-community/Qwen3.5-4B-MLX-4bit \
            mlx-community/Qwen3.5-9B-MLX-4bit mlx-community/Qwen2.5-1.5B-Instruct-8bit; do
  json=$(listing "$repo") || { fail "$repo: listing unreachable"; continue; }
  cfg=$(printf '%s' "$json" | jq -r '[.Data.Files[] | select(.Path=="config.json")] | length' 2>/dev/null)
  wts=$(printf '%s' "$json" | jq -r '[.Data.Files[] | select(.Path|endswith(".safetensors"))] | length' 2>/dev/null)
  if [ "${cfg:-0}" -ge 1 ] && [ "${wts:-0}" -ge 1 ]; then ok "$repo ($wts weight file(s))"; else fail "$repo: missing config.json or weights"; fi
done

echo "Raw-file download works (HEAD)"
code=$(curl -s -o /dev/null -I -m 30 -w '%{http_code}' "https://modelscope.cn/models/ggml-org/whisper-vad/resolve/master/ggml-silero-v6.2.0.bin")
[ "$code" = "200" ] && ok "resolve/master URL pattern (HTTP 200)" || fail "resolve/master URL pattern: HTTP $code"

echo
if [ "$FAILS" -eq 0 ]; then echo "China model sources: all good"; else echo "China model sources: $FAILS problem(s) — do not submit the China build"; exit 1; fi

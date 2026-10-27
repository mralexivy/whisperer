#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${SHIELD_BUILD_DIR:-$ROOT/build/privacy-shield}"
mkdir -p "$DEST"
clang++ -std=c++17 -O2 -dynamiclib "$ROOT/Whisperer/PrivacyShield/Native/ShieldAudio.cpp" -framework AudioUnit -framework CoreAudio -o "$DEST/libShieldBenchmark.dylib"
echo "Built: $DEST/libShieldBenchmark.dylib"

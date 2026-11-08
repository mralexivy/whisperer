#!/bin/bash
# Offline tests; no driver installation, microphone access, or network use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/whisperer-shield-validation.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$ROOT"
clang++ -std=c++17 -O2 -fsanitize=address,undefined Tools/privacy-shield/native-tests.cpp -o "$TEST_DIR/native"
"$TEST_DIR/native"
clang++ -std=c++17 -O2 -fsanitize=address,undefined Tools/privacy-shield/engine-tests.cpp -framework AudioUnit -framework CoreAudio -framework Accelerate -o "$TEST_DIR/engine"
"$TEST_DIR/engine"
if [[ -f build/privacy-shield/libWhispererASPL.a ]]; then
  clang++ -std=c++17 -O2 -Wno-reorder-init-list -fsanitize=address,undefined -I Vendor/libASPL/include Tools/privacy-shield/driver-tests.cpp build/privacy-shield/libWhispererASPL.a -framework CoreAudio -framework CoreFoundation -framework Accelerate -o "$TEST_DIR/driver"
  "$TEST_DIR/driver"
else
  echo "Driver callback tests require: SHIELD_ARCHS=$(uname -m) bash Tools/privacy-shield/build-driver.sh" >&2
  exit 1
fi
clang++ -std=c++17 -O3 Tools/privacy-shield/performance.cpp -o "$TEST_DIR/performance"
"$TEST_DIR/performance"
bash Tools/privacy-shield/test-standalone.sh
python3 -m unittest discover -s Tools/privacy-shield -p 'test_*.py'
# Jammer parity (native streaming == Python reference); needs numpy + scipy (the eval venv has both).
SHIELD_PY="${SHIELD_PYTHON:-$ROOT/build/privacy-shield/eval/.venv/bin/python}"
if [ -x "$SHIELD_PY" ]; then
    SHIELD_BUILD_DIR="$ROOT/build/privacy-shield" bash Tools/privacy-shield/build-benchmark.sh >/dev/null
    "$SHIELD_PY" Tools/privacy-shield/eval/test_jammer_native.py
else
    echo "Skipped jammer parity: set SHIELD_PYTHON to a Python with numpy and scipy."
fi

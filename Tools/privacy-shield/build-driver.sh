#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${SHIELD_BUILD_DIR:-$ROOT/build/privacy-shield}"
cmake -S "$ROOT/Platform/macOS/VirtualMicrophone" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="${SHIELD_ARCHS:-arm64;x86_64}"
cmake --build "$BUILD" --parallel 4
codesign --force --sign "${SHIELD_SIGN_ID:--}" "$BUILD/WhispererAudio.driver"
echo "Built: $BUILD/WhispererAudio.driver"

#!/bin/bash
#
# Rebuilds the vendored whisper.cpp static libraries that the macOS app links.
#
# The flags below are not a guess. They were recovered from
# whisper.cpp/build-static/CMakeCache.txt, which is the configuration the
# currently linked libwhisper.a was actually built with.
#
# WHISPER_COREML stays OFF on purpose. The fixed-shape MLMultiArray that the
# Core ML encoder builds from the mel tensor is incompatible with audio_ctx,
# which the eager streaming path needs in order to size the encoder to the
# window. See CLAUDE.md, "No Core ML / ANE on the whisper.cpp path".
#
# Output is static (BUILD_SHARED_LIBS=OFF) to match the Xcode link model.
# The iOS build is a separate script and produces a dynamic xcframework.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/whisper.cpp"
BUILD_DIR="$SRC_DIR/build-static"

if [ ! -d "$SRC_DIR" ]; then
    echo "error: whisper.cpp not found at $SRC_DIR" >&2
    exit 1
fi

# Resolve cmake explicitly. Xcode run-script phases and CI shells do not
# inherit a login PATH, so a bare `cmake` is not reliable here.
CMAKE="${CMAKE:-$(command -v cmake || true)}"
for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake /Applications/CMake.app/Contents/bin/cmake; do
    [ -n "$CMAKE" ] && break
    [ -x "$candidate" ] && CMAKE="$candidate"
done
if [ -z "$CMAKE" ]; then
    echo "error: cmake not found. Install it, or set CMAKE=/path/to/cmake" >&2
    exit 1
fi
echo "Using cmake: $CMAKE"

"$CMAKE" -B "$BUILD_DIR" -S "$SRC_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=ON \
    -DGGML_OPENMP=ON \
    -DWHISPER_COREML=OFF

"$CMAKE" --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

echo ""
echo "Built archives:"
for lib in \
    "$BUILD_DIR/src/libwhisper.a" \
    "$BUILD_DIR/ggml/src/libggml.a" \
    "$BUILD_DIR/ggml/src/libggml-base.a" \
    "$BUILD_DIR/ggml/src/libggml-cpu.a" \
    "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a" \
    "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a"
do
    if [ -f "$lib" ]; then
        printf '  %-28s %s\n' "$(basename "$lib")" "$(lipo -archs "$lib")"
    else
        echo "  MISSING: $lib" >&2
        exit 1
    fi
done

# Guard the Core ML invariant: a build that leaks Core ML symbols would
# silently reintroduce the audio_ctx incompatibility.
if nm "$BUILD_DIR/src/libwhisper.a" 2>/dev/null | grep -q "whisper_coreml"; then
    echo "" >&2
    echo "error: libwhisper.a exports Core ML symbols; WHISPER_COREML leaked ON" >&2
    exit 1
fi

echo ""
echo "OK. Core ML symbols absent, as expected."

#!/bin/bash
# Run the same processor XCTest source without launching the full application host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/whisperer-shield-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
DEVELOPER=$(xcode-select -p)
PLATFORM="$DEVELOPER/Platforms/MacOSX.platform/Developer"
python3 - "$ROOT" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys, re
root, target = map(Path, sys.argv[1:])
source = (root / 'WhispererTests/PrivacyShieldTests.swift').read_text().replace('@testable import whisperer', '')
(target / 'PrivacyShieldTests.swift').write_text(source)
count = len(re.findall(r'func test\w+\(', source))
(target / 'main.swift').write_text('import XCTest\nimport Foundation\nlet suite = XCTestSuite(forTestCaseClass: PrivacyShieldTests.self)\n'
    + f'precondition(suite.testCaseCount == {count}, "Expected all feature tests")\n'
    + 'suite.run()\nexit(suite.testRun?.hasSucceeded == true ? 0 : 1)\n')
PY
clang++ -std=c++17 -c "$ROOT/Whisperer/PrivacyShield/Native/ShieldAudio.cpp" -o "$TEST_DIR/ShieldAudio.o"
swiftc -swift-version 5 -import-objc-header "$ROOT/Whisperer/PrivacyShield/Native/ShieldAudio.h" \
  -F "$PLATFORM/Library/Frameworks" -I "$PLATFORM/usr/lib" -L "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$DEVELOPER/../SharedFrameworks" \
  "$ROOT/Whisperer/PrivacyShield/PrivacyShieldState.swift" \
  "$ROOT/Whisperer/PrivacyShield/PrivacyAudioProcessor.swift" \
  "$TEST_DIR/PrivacyShieldTests.swift" "$TEST_DIR/main.swift" "$TEST_DIR/ShieldAudio.o" \
  -lc++ -framework AudioUnit -framework CoreAudio -o "$TEST_DIR/run-tests"
"$TEST_DIR/run-tests"

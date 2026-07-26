# Phase: Verify

## Purpose

Confirms that all fixes compile and no banned patterns were re-introduced. Runs after `phase-fix.md`.

## Actions

### 1. Three-Config Parallel Builds

Run all three Xcode configurations and capture results:

```bash
# Debug build
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | tail -5

# Release build (local distribution)
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Release \
  -destination "platform=macOS" ARCHS=arm64 2>&1 | tail -5

# AppStore build
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration AppStore \
  -destination "platform=macOS" ARCHS=arm64 \
  CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements \
  ENABLE_APP_SANDBOX=YES 2>&1 | tail -5
```

Record: BUILD SUCCEEDED or BUILD FAILED + first error for each config.

### 2. Four Sequential Grep Gates

**Gate 1 — No print() statements**:
```bash
grep -rn 'print(' Whisperer/ --include='*.swift' | grep -v 'Logger\|// debug'
```
Expected: zero matches. Any match = FAIL.

**Gate 2 — No banned App Store APIs**:
```bash
grep -rn 'CGEventTap\|CGEvent\.tapCreate\|IOHIDManager\|IOKit\.hid\|addGlobalMonitorForEvents.*\.keyDown\|addGlobalMonitorForEvents.*\.keyUp\|IOHIDCheckAccess\|IOHIDRequestAccess' Whisperer/ --include='*.swift'
```
Expected: zero matches. Any match = FAIL.

**Gate 3 — stopAsync() invariant**:
```bash
grep -rn 'transcriber\.stop()\|streamingTranscriber?\?\.stop()' Whisperer/ --include='*.swift' | grep -v 'Async\|stopRecording\|stopAsync'
```
Expected: zero matches (only `stopAsync()` calls, never bare `stop()`). Any match = FAIL.

**Gate 4 — App Store binary strings scan** (only if AppStore build succeeded):
```bash
# Find the built binary
BINARY=$(find ~/Library/Developer/Xcode/DerivedData -name "whisperer" -type f -path "*/AppStore-*" 2>/dev/null | head -1)
if [ -n "$BINARY" ]; then
  /usr/bin/strings "$BINARY" | grep -iE 'AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive'
fi
```
Expected: zero matches. Any match = FAIL.

### 3. Write verification.md

Write to `.claude/review-state/verification.md`:

```
# Verification Report — Pass #N
[timestamp]

## Build Results
| Config | Result | First Error (if any) |
|--------|--------|---------------------|
| Debug | BUILD SUCCEEDED / FAILED | ... |
| Release | BUILD SUCCEEDED / FAILED | ... |
| AppStore | BUILD SUCCEEDED / FAILED | ... |

## Grep Gate Results
| Gate | Result | Matches |
|------|--------|---------|
| No print() | PASS / FAIL | [lines] |
| No banned APIs | PASS / FAIL | [lines] |
| stopAsync() invariant | PASS / FAIL | [lines] |
| Binary string scan | PASS / FAIL / SKIPPED | [lines] |

## Overall
PASS — all builds succeeded, all gates clean
FAIL — [list of failures]
```

### 4. On Build Failure

If any build fails, read the full build log for that config and report the first 10 errors. Do NOT proceed to `phase-commit.md` until all three builds succeed.

Common fixes for build failures after the review pass:
- Missing `await` after adding `stopAsync()` — add `async` to the calling function
- Type mismatch from `#if APP_STORE` refactoring — check that both branches return compatible types
- `weak self` in non-escaping closure — remove `[weak self]` from non-escaping closures (only escaping closures need it)

### 5. Return

Return one line:
```
Verify: Debug PASS/FAIL, Release PASS/FAIL, AppStore PASS/FAIL, Gates: N/4 clean
```

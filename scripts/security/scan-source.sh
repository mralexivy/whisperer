#!/bin/bash
# Fails if the source tree contains anything that looks like a live secret or a banned API.
# usage: scripts/security/scan-source.sh   (run from the repo root; exit 1 on any finding)
set -u
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"; export DEVELOPER_DIR
cd "$(dirname "$0")/../.."
fail=0
report() { echo "FAIL: $1"; echo "$2" | sed 's/^/    /'; fail=1; }

SECRETS='sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|AIza[0-9A-Za-z_-]{35}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
hits=$(grep -rEn "$SECRETS" Whisperer WhispererTests --include='*.swift' --include='*.plist' --include='*.json' --include='*.h' --include='*.hpp' --include='*.m' 2>/dev/null)
[ -n "$hits" ] && report "possible secret in source" "$hits"

# Guideline 2.4.5: no global event taps or HID monitors anywhere in the app target.
# A global .flagsChanged monitor (modifier-only push-to-talk) is the reviewed, allowed exception.
banned=$(grep -rEn 'CGEvent\.tapCreate|CGEventTapCreate|IOHIDManagerCreate|addGlobalMonitorForEvents\(matching: *\[?\.?(keyDown|keyUp)' Whisperer --include='*.swift' --include='*.m' 2>/dev/null | grep -v '^\s*//')
[ -n "$banned" ] && report "banned input-monitoring API (Guideline 2.4.5)" "$banned"

# No anti-debugging tricks that change behaviour under review (Guideline 2.3.1).
antidbg=$(grep -rEn 'PT_DENY_ATTACH|ptrace\(|sysctl.*P_TRACED' Whisperer --include='*.swift' --include='*.m' --include='*.c' --include='*.cpp' --include='*.hpp' 2>/dev/null)
[ -n "$antidbg" ] && report "anti-debugging code (behaviour must not differ under review)" "$antidbg"

[ -f Whisperer/PrivacyInfo.xcprivacy ] || report "privacy manifest missing" "Whisperer/PrivacyInfo.xcprivacy"
plutil -lint Whisperer/PrivacyInfo.xcprivacy >/dev/null 2>&1 || report "privacy manifest is not a valid plist" ""

# Shipping configs must be optimized (unset = -Onone).
for cfg in Release AppStore; do
  lvl=$(xcodebuild -project Whisperer.xcodeproj -scheme whisperer -configuration "$cfg" -showBuildSettings 2>/dev/null | awk -F' = ' '/ SWIFT_OPTIMIZATION_LEVEL /{print $2; exit}')
  [ "$lvl" = "-O" ] || report "$cfg builds with SWIFT_OPTIMIZATION_LEVEL='$lvl' (want -O)" ""
done

[ $fail -eq 0 ] && echo "scan-source: OK"
exit $fail

#!/bin/bash
# Audits a built Whisperer.app the way a reviewer or an attacker would see it.
# usage: scripts/security/audit-app.sh path/to/Whisperer.app [--app-store]
#   --app-store  also require the App Sandbox entitlement (the Mac App Store build)
# Exit 1 on any FAIL. WARN lines are informational.
set -u
APP="${1:?usage: audit-app.sh path/to/App.app [--app-store]}"; MAS="${2:-}"
BIN="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable 2>/dev/null)"
fail=0
ok()   { echo "OK:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
warn() { echo "WARN: $1"; }

[ -x "$BIN" ] || { echo "FAIL: no executable at $BIN"; exit 1; }

codesign --verify --deep --strict "$APP" 2>/dev/null && ok "code signature valid (resources sealed)" || bad "code signature invalid"
flags=$(codesign -dv "$APP" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)')
echo "$flags" | grep -q runtime && ok "hardened runtime ($flags)" || bad "hardened runtime off ($flags)"

ent=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
echo "$ent" | grep -q 'get-task-allow' && echo "$ent" | grep -A1 'get-task-allow' | grep -q true \
  && bad "get-task-allow=true (debuggable build)" || ok "no get-task-allow"
for risky in com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-unsigned-executable-memory com.apple.security.cs.allow-dyld-environment-variables; do
  echo "$ent" | grep -q "$risky" && bad "risky entitlement $risky" || true
done
if [ "$MAS" = "--app-store" ]; then
  echo "$ent" | grep -q com.apple.security.app-sandbox && ok "app sandbox on" || bad "app sandbox missing in App Store build"
fi

[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] && ok "privacy manifest bundled" || bad "PrivacyInfo.xcprivacy not in bundle"

# Debug info must live in the dSYM, not the shipped binary.
dwarf=$(otool -l "$BIN" | grep -c '__debug_info')
[ "$dwarf" -eq 0 ] && ok "no DWARF in shipped binary" || bad "binary carries __debug_info ($dwarf sections)"

syms=$(nm -U "$BIN" 2>/dev/null | wc -l | tr -d ' ')
swiftsyms=$(nm -U "$BIN" 2>/dev/null | grep -c ' _\$s' )
echo "INFO: defined symbols $syms, of which Swift-mangled $swiftsyms"
[ "$swiftsyms" -gt 2000 ] && warn "many Swift symbols remain; check STRIP_SWIFT_SYMBOLS / STRIP_INSTALLED_PRODUCT"

secrets=$(strings -a "$BIN" | grep -Ec 'sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|BEGIN [A-Z ]*PRIVATE KEY')
[ "$secrets" -eq 0 ] && ok "no secret-shaped strings in binary" || bad "$secrets secret-shaped strings in binary"

paths=$(strings -a "$BIN" | grep -c '/Users/')
[ "$paths" -eq 0 ] && ok "no build-machine paths in binary" || warn "$paths strings contain /Users/ (source paths from #file / assertions)"

echo "INFO: UUIDs $(dwarfdump --uuid "$BIN" 2>/dev/null | awk '{print $2"("$3")"}' | tr '\n' ' ')"
[ $fail -eq 0 ] && echo "audit-app: OK" || echo "audit-app: FAILED"
exit $fail

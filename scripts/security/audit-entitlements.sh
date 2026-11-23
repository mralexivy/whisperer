#!/bin/bash
# Every entitlement the signed app carries must have a feature in the source that uses it, a usage string where macOS needs
# one, and a sentence in the review notes. Apple's automated review rejects an entitlement it cannot match to functionality
# (2026-11-17: com.apple.security.network.server on the China build, guideline 2.4.5).
#
#   scripts/security/audit-entitlements.sh /absolute/path/to/whisperer.app
#
# It also fails when a public statement contradicts what the code does (the privacy policy said "microphone only" while the
# app records the call app's audio). Exit 0 = nothing found.
set -u
APP="${1:?usage: audit-entitlements.sh /absolute/path/to/whisperer.app}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Whisperer"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok()  { echo "OK:   $*"; }

ents="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
[ -n "$ents" ] || { bad "no entitlements read from $APP (is it signed?)"; exit 1; }
keys="$(printf '%s' "$ents" | plutil -convert json -o - - | tr ',' '\n' | grep -o '"com\.apple[^"]*"' | tr -d '"')"
plist="$APP/Contents/Info.plist"

used() { grep -rqE "$1" "$SRC" --include='*.swift'; }
has_string() { /usr/bin/defaults read "$plist" "$1" >/dev/null 2>&1; }

for k in $keys; do
  case "$k" in
    com.apple.security.app-sandbox) ok "$k (required for the Mac App Store)";;
    com.apple.security.network.client) used 'URLSession' && ok "$k: URLSession" || bad "$k has no URLSession use";;
    com.apple.security.network.server) used 'NWListener' && ok "$k: NWListener (MCP server, ChatGPT sign-in redirect)" || bad "$k has no NWListener use";;
    com.apple.security.device.audio-input) used 'AVAudioEngine' && has_string NSMicrophoneUsageDescription && ok "$k: AVAudioEngine + usage string" || bad "$k lacks AVAudioEngine use or NSMicrophoneUsageDescription";;
    # 2026-11-23: this used to match any 'AVCaptureDevice', which the microphone code also uses, so the camera entitlement
    # passed while nothing captured video. Apple (2.4.5(i)) found exactly that. The camera entitlement needs VIDEO capture.
    com.apple.security.device.camera) used 'AVCaptureSession|AVCaptureVideoDataOutput|AVCaptureDevice\.(default|DiscoverySession)\(.*video|for: *\.video|requestAccess\(for: *\.video' && has_string NSCameraUsageDescription && ok "$k: video capture + usage string" || bad "$k has no video-capture use (the in-use check via CoreMediaIO needs no entitlement in this build): remove it";;
    com.apple.security.files.user-selected.read-write|com.apple.security.files.user-selected.read-only) used 'NSOpenPanel|NSSavePanel|fileImporter' && ok "$k: open/save panels" || bad "$k has no open/save panel use";;
    *) bad "$k is not in the allow-list of this script: justify it in the code, the review notes and here before shipping";;
  esac
done

# Permissions the code asks for need their usage string, and the other way round.
if used 'AudioHardwareCreateProcessTap'; then
  has_string NSAudioCaptureUsageDescription && ok "call audio tap: NSAudioCaptureUsageDescription" || bad "call audio tap without NSAudioCaptureUsageDescription"
fi

# Claims that contradict the code. Add a line here whenever a document and a feature disagree.
if used 'AudioHardwareCreateProcessTap'; then
  if grep -rniE 'microphone only|never records? system audio|never records? the audio streams of other' "$SRC/Resources/PrivacyPolicy.md" >/dev/null 2>&1; then
    bad "PrivacyPolicy.md says the app records the microphone only, but the call audio tap is compiled in"
  else ok "PrivacyPolicy.md agrees with the call audio tap"; fi
fi
LANDING="$ROOT/../whisperer-landing"
if [ -d "$LANDING/app" ] && used 'AudioHardwareCreateProcessTap'; then
  if grep -rniE 'microphone only|never records? system audio' "$LANDING/app/privacy" "$LANDING/app/terms" >/dev/null 2>&1; then
    bad "the website privacy/terms pages say microphone only; the app records the call audio"
  else ok "website privacy/terms agree with the call audio tap"; fi
fi

[ $fail = 0 ] && echo "audit-entitlements: OK" || echo "audit-entitlements: FAILED"
exit $fail

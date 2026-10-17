#!/bin/bash
# Explicit administrator action: installing/removing restarts system audio.
set -euo pipefail
TARGET=/Library/Audio/Plug-Ins/HAL/WhispererAudio.driver
IDENTIFIER=com.ivy.whisperer.audio
if [[ $(id -u) != 0 ]]; then echo 'Run with sudo. This restarts audio; finish calls first.' >&2; exit 1; fi
if [[ -e "$TARGET" ]]; then
  [[ ! -L "$TARGET" && $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist") == "$IDENTIFIER" ]] || { echo 'Unexpected existing target; refusing replacement.' >&2; exit 1; }
fi
if [[ ${1:-} == --uninstall ]]; then
  rm -rf "$TARGET"
else
  SOURCE=${1:?Pass the built WhispererAudio.driver path or --uninstall}
  [[ -d "$SOURCE" && ! -L "$SOURCE" ]] || exit 1
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist") == "$IDENTIFIER" ]] || exit 1
  codesign --verify --strict "$SOURCE"
  STAGING=$(mktemp -d /Library/Audio/Plug-Ins/HAL/.whisperer-install.XXXXXX)
  trap 'rm -rf "$STAGING"' EXIT
  ditto "$SOURCE" "$STAGING/WhispererAudio.driver"
  chown -R root:wheel "$STAGING/WhispererAudio.driver"
  chmod -R go-w "$STAGING/WhispererAudio.driver"
  rm -rf "$TARGET"
  mv "$STAGING/WhispererAudio.driver" "$TARGET"
fi
launchctl kickstart -k system/com.apple.audio.coreaudiod

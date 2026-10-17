#!/bin/bash
# Explicit administrator action: installing/removing restarts system audio.
set -euo pipefail
STEP="validating installation"
trap 'code=$?; echo "Whisperer audio setup failed while $STEP (exit $code)." >&2' ERR
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
  STEP="checking driver signature"
  codesign --verify --strict "$SOURCE"
  STEP="installing driver"
  STAGING=$(mktemp -d /Library/Audio/Plug-Ins/HAL/.whisperer-install.XXXXXX)
  trap 'rm -rf "$STAGING"' EXIT
  ditto "$SOURCE" "$STAGING/WhispererAudio.driver"
  chown -R root:wheel "$STAGING/WhispererAudio.driver"
  chmod -R go-w "$STAGING/WhispererAudio.driver"
  rm -rf "$TARGET"
  mv "$STAGING/WhispererAudio.driver" "$TARGET"
fi
# macOS 14.4+ forbids launchctl kickstart -k for critical system services.
# Terminate only the audio daemon; launchd's existing job starts it again.
STEP="restarting system audio"
OLD_PID=$(/usr/bin/pgrep -x coreaudiod || true)
if [[ -n "$OLD_PID" ]]; then
  /usr/bin/killall -KILL coreaudiod
fi
for ((attempt=0; attempt<50; attempt++)); do
  NEW_PID=$(/usr/bin/pgrep -x coreaudiod || true)
  if [[ -n "$NEW_PID" && "$NEW_PID" != "$OLD_PID" ]]; then
    echo 'Whisperer audio support installed; system audio restarted.'
    exit 0
  fi
  /bin/sleep 0.2
done
echo 'Driver installed, but system audio did not restart. Restart your Mac to finish setup.' >&2
exit 75

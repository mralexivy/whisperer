#!/bin/bash
set -euo pipefail
DEST="${SHIELD_EMBED_DESTINATION:?Missing application resource destination}"
# Archive products live in DSTROOT, rather than the ordinary build-products folder.
if [[ ${ACTION:-} == install ]]; then
  DEST="${DSTROOT:?Missing archive install root}/Applications/whisperer.app/Contents/Resources/PrivacyShield"
fi
case "$DEST" in
  */whisperer.app/Contents/Resources/PrivacyShield) ;;
  *) echo 'Unexpected driver resource destination' >&2; exit 1 ;;
esac
if [[ ${CONFIGURATION:-} == AppStore ]]; then
  rm -rf "$DEST"
  exit 0
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export SHIELD_BUILD_DIR="$DERIVED_FILE_DIR/PrivacyShieldDriver"
export SHIELD_ARCHS="${ARCHS// /;}"
# Aggregate targets do not receive the app's expanded signing identity. Never
# silently embed an ad-hoc driver in an otherwise normally signed app.
export SHIELD_SIGN_ID="${SHIELD_SIGN_ID:-${EXPANDED_CODE_SIGN_IDENTITY:-Apple Development}}"
if [[ -n ${SHIELD_PREBUILT_DRIVER:-} ]]; then
  DRIVER="$SHIELD_PREBUILT_DRIVER"
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DRIVER/Contents/Info.plist") == com.ivy.whisperer.audio ]]
  codesign --verify --strict "$DRIVER"
else
  "$SRCROOT/Tools/privacy-shield/build-driver.sh"
  DRIVER="$SHIELD_BUILD_DIR/WhispererAudio.driver"
fi
read -r -a REQUIRED_ARCHS <<< "${ARCHS:-arm64}"
lipo "$DRIVER/Contents/MacOS/WhispererAudio" -verify_arch "${REQUIRED_ARCHS[@]}"
mkdir -p "$DEST"
ditto "$DRIVER" "$DEST/WhispererAudio.driver"
cp "$SRCROOT/Tools/privacy-shield/install-driver.sh" "$DEST/install-driver.sh"

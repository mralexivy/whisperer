# App Store Release Build

Build a Release version of Whisperer for App Store submission. Sandboxed, `APP_STORE` flag active (hides Accessibility, auto-paste, command mode, rewrite mode). Creates an archive for upload.

## Steps

### 1. Clean and archive for App Store

```bash
xcodebuild clean archive -project Whisperer.xcodeproj -scheme whisperer -configuration AppStore -destination "platform=macOS" -archivePath build/whisperer.xcarchive ARCHS=arm64
```

The `AppStore` configuration:
- Full compiler optimizations (same as Release)
- **`APP_STORE` compile flag** — hides Accessibility, auto-paste, rewrite, command mode
- Uses `whisperer.entitlements` with `ENABLE_APP_SANDBOX=YES`
- `ARCHS=arm64` — FluidAudio fails on x86_64 (Float16 issue)

### 2. Verify binary has no banned strings

```bash
BINARY="build/whisperer.xcarchive/Products/Applications/whisperer.app/Contents/MacOS/whisperer"
/usr/bin/strings "${BINARY}" | grep -iE "AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive"
```

This should return empty. If it returns matches, STOP and report the violations.

### 3. Read version info

```bash
VERSION=$(/usr/bin/defaults read "build/whisperer.xcarchive/Products/Applications/whisperer.app/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(/usr/bin/defaults read "build/whisperer.xcarchive/Products/Applications/whisperer.app/Contents/Info.plist" CFBundleVersion)
```

### 4. Upload to App Store Connect

```bash
xcodebuild -exportArchive -archivePath build/whisperer.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
```

### 5. Report result

Report: "App Store archive ready — version X.Y (build Z). Binary verified clean. Uploaded to App Store Connect." or report any binary verification failures.

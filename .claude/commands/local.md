# Local Release Build

Build a Release version of Whisperer for local testing with ALL features enabled (Accessibility, auto-paste, rewrite mode, command mode). Creates a zip in ~/Downloads.

## Steps

### 1. Clean and build Release (all features, no sandbox)

```bash
xcodebuild clean build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS"
```

The `Release` configuration:
- Full compiler optimizations (whole module, dead code stripping)
- **No `APP_STORE` flag** — all features enabled (Accessibility, auto-paste, rewrite, command mode)
- Uses `whisperer-nosandbox.entitlements` with `ENABLE_APP_SANDBOX=NO`

### 2. Copy to Downloads and create zip

```bash
BUILT_APP=$(xcodebuild -project Whisperer.xcodeproj -scheme whisperer -configuration Release -showBuildSettings 2>/dev/null | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}')
VERSION=$(/usr/bin/defaults read "${BUILT_APP}/whisperer.app/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(/usr/bin/defaults read "${BUILT_APP}/whisperer.app/Contents/Info.plist" CFBundleVersion)
rm -rf ~/Downloads/whisperer.app ~/Downloads/Whisperer.zip
cp -R "${BUILT_APP}/whisperer.app" ~/Downloads/whisperer.app
cd ~/Downloads && zip -r -y -q Whisperer.zip whisperer.app && rm -rf whisperer.app
ls -lh ~/Downloads/Whisperer.zip
```

### 3. Report result

Report: "Local build ready at ~/Downloads/Whisperer.zip — version X.Y (build Z), all features enabled. Unzip and double-click to run."

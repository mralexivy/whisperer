# Local Release Build

Build a Release version of Whisperer for local testing with ALL features enabled (Accessibility, auto-paste, rewrite mode, command mode). Creates a zip in ~/Downloads with a release log.

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

### 3. Generate release log

Generate a release log from commits since last local build:

```bash
MARKER_FILE="$HOME/.whisperer-last-local-build-commit"

# Get the last build commit (or use last 5 commits if no marker)
if [ -f "$MARKER_FILE" ]; then
    LAST_COMMIT=$(cat "$MARKER_FILE")
    RELEASE_LOG=$(git log --oneline "$LAST_COMMIT"..HEAD)
else
    RELEASE_LOG=$(git log --oneline -5)
fi

# Save current HEAD as the new marker
git rev-parse HEAD > "$MARKER_FILE"
```

Save the release log to `~/Downloads/Whisperer-release-log.txt` with a header:

```
Whisperer vX.Y (build Z) — Local Build
Date: YYYY-MM-DD HH:MM
─────────────────────────────
<commit log lines>
```

### 4. Report result

Report: "Local build ready at ~/Downloads/Whisperer.zip — version X.Y (build Z), all features enabled. Unzip and double-click to run."

Then display the release log contents.

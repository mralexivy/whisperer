# Recon Playbook — macOS .app Bundle (Static / Read-Only)

Use this playbook when the target is an installed `.app` or a `.dmg`-extracted bundle.
**Never modify, re-sign, patch, or launch the app. Read-only only.**

For each step: record what you found, the exact shell command or path you used, and a one-line FACT statement. If a step yields nothing useful, skip it and say so.

---

## Step 1 — Identity

```bash
APP="/Applications/TargetApp.app"   # adjust to actual path

# Bundle metadata
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleIdentifier|CFBundleName|CFBundleVersion|CFBundleShortVersionString|CFBundleExecutable|NSPrincipalClass|LSUIElement|LSBackgroundOnly|SMLoginItemServiceName"

# Minimum deployment target, entitlements
codesign -d --entitlements :- "$APP" 2>/dev/null

# Architecture
lipo -archs "$APP/Contents/MacOS/"* 2>/dev/null
file "$APP/Contents/MacOS/"*
```

Evidence signals:
- `LSUIElement = 1` → menu bar only (like us)
- `LSBackgroundOnly = 1` → headless launch agent
- `SMLoginItemServiceName` → has a privileged helper or login item
- Entitlement `com.apple.security.accessibility` present → uses Accessibility API for injection (we don't in App Store build)
- Entitlement `com.apple.security.app-sandbox` absent → non-sandboxed, can use CGEventTap

---

## Step 2 — Framework graph (tells you the tech stack)

```bash
otool -L "$APP/Contents/MacOS/"* 2>/dev/null | sort -u
```

Key frameworks and what they reveal:
| Framework | Signal |
|---|---|
| `CoreML.framework` | Uses Core ML models (ANE / CPU) |
| `Metal.framework` | GPU compute (may overlap with whisper Metal) |
| `AVFoundation.framework` | Audio capture |
| `Speech.framework` | Uses Apple's own ASR (online-capable) |
| `NaturalLanguage.framework` | On-device NLP / tokenization |
| `Accelerate.framework` | DSP, BLAS — often paired with GGML/CoreML |
| `WebKit.framework` | Electron wrapper or WKWebView UI |
| `AppKit.framework` (only, no `SwiftUI`) | Pure AppKit — older or performance-critical |
| `libswift*.dylib` | Swift runtime (vs pure ObjC/C) |
| `Electron` dylibs | Web-based UI — look for Resources/app/ |

---

## Step 3 — Bundled models and assets

```bash
# ML models
find "$APP" -name "*.mlmodelc" -o -name "*.mlpackage" | while read f; do
  echo "SIZE: $(du -sh "$f" | cut -f1)  PATH: $f"
done

# Weights / GGUF / CoreML ANE blobs
find "$APP" -name "*.gguf" -o -name "*.bin" -o -name "*.pt" -o -name "*.safetensors" | while read f; do
  echo "SIZE: $(du -sh "$f" | cut -f1)  PATH: $f"
done

# Tokenizer files
find "$APP" -name "vocab.txt" -o -name "tokenizer.json" -o -name "merges.txt" | while read f; do
  echo "$f"; head -3 "$f"
done

# Audio models
find "$APP" -name "*.tflite" -o -name "*.ort" | while read f; do
  echo "SIZE: $(du -sh "$f" | cut -f1)  PATH: $f"
done
```

Record: file names, sizes, directory structure. Do NOT read or extract model bytes. The directory structure and file names alone tell you which models they ship and roughly which architecture (GGUF = GGML/llama.cpp family, `.mlmodelc` = Core ML, `.pt`/`.safetensors` = PyTorch).

---

## Step 4 — String extraction (feature flags, endpoints, prompts)

```bash
# General string dump — pipe through grep to find features
strings "$APP/Contents/MacOS/"* | grep -iE \
  "https?://|api\.|whisper|openai|groq|assembly|deepgram|meeting|speaker|diariz|prompt|correction|dictionary|hotkey|shortcut|language|model|metal|coreml|anE|gpu|quality|latency|timeout|license|trial|premium|pro|subscription" \
  | sort -u | head -200

# Separate search for accessibility / injection patterns
strings "$APP/Contents/MacOS/"* | grep -iE \
  "AXUIElement|CGEvent|IOHIDManager|kAXFocused|accessibility|insertText|paste|clipboard|keystroke" \
  | sort -u

# Look for server endpoints
strings "$APP/Contents/MacOS/"* | grep -E "^https?://" | sort -u
```

Each hit: write as `SIGNAL: strings hit "<value>" SOURCE: strings <binary> FACT: <conclusion>`.

---

## Step 5 — Electron / web wrapper detection

```bash
# Is it Electron?
ls "$APP/Contents/Resources/" | head -30
ls "$APP/Contents/Frameworks/" | grep -i electron 2>/dev/null

# If electron: look at bundled JS for feature clues
find "$APP/Contents/Resources" -name "*.js" -o -name "*.asar" 2>/dev/null | head -10
# If .asar: note it exists; do not extract (would require `asar` tool)
# Read only plain .js files:
find "$APP/Contents/Resources/app" -name "*.js" -not -name "*.min.js" 2>/dev/null | head -5 | xargs head -50 2>/dev/null
```

---

## Step 6 — Preferences / local data schema

```bash
BUNDLE_ID=$(plutil -p "$APP/Contents/Info.plist" | grep CFBundleIdentifier | awk -F'"' '{print $4}')

# Prefs
defaults read "$BUNDLE_ID" 2>/dev/null | head -60

# Application Support
ls -la ~/Library/"Application Support"/"$BUNDLE_ID"/ 2>/dev/null
ls -la ~/Library/"Application Support"/$(basename "$APP" .app)/ 2>/dev/null

# Containers (sandboxed)
ls ~/Library/Containers/"$BUNDLE_ID"/ 2>/dev/null

# Logs
ls ~/Library/Logs/"$BUNDLE_ID"/ 2>/dev/null | head -20
ls ~/Library/Logs/$(basename "$APP" .app)/ 2>/dev/null | head -20
```

What to record:
- Prefs keys reveal feature flags (e.g. `diarizationEnabled`, `localModelPath`, `hotkey`)
- App Support schema shows how they persist history/sessions/models
- Log file existence and names reveal internal subsystem names

---

## Step 7 — Login item / background service wiring

```bash
# Launch agents installed by the app
ls /Library/LaunchAgents/ ~/Library/LaunchAgents/ 2>/dev/null | grep -i "$(basename "$APP" .app)"

# Privileged helper tool
ls "$APP/Contents/Library/LoginItems/" 2>/dev/null
ls "$APP/Contents/Library/LaunchServices/" 2>/dev/null

# XPC services
ls "$APP/Contents/XPCServices/" 2>/dev/null
```

---

## Step 8 — Public sources

Use WebFetch / WebSearch for:

1. Official product page and feature list
2. App Store listing: screenshots, description, version history
3. Changelog / release notes (GitHub releases, app website)
4. Forum discussions: Reddit, Hacker News, ProductHunt (search `site:reddit.com <AppName> voice`)
5. Support docs / help center
6. Developer blog posts or architecture write-ups
7. Reviews (MacStories, 9to5Mac, etc.) — often describe UX precisely

For each public source: cite the URL and date. Quote the relevant passage verbatim in the evidence file.

---

## What each signal licenses you to conclude

| Observation | Legitimate conclusion |
|---|---|
| No Accessibility entitlement | Does not use AXUIElement for text injection |
| `CGEvent` in strings, no sandbox entitlement | Likely uses CGEventTap for injection (rejected by App Store) |
| `Speech.framework` linked | Has access to Apple's online ASR — may fall back to it |
| `.gguf` file ≥ 1.5 GB | Ships a local LLM (size suggests 7B+ quantized) |
| `.mlmodelc` in `Resources/` | Compiled Core ML model runs on ANE/GPU |
| `https://api.openai.com` in strings | Calls OpenAI — not purely offline |
| Login item + XPC service | Two-process architecture — helper runs privileged or persistent |
| Electron dylibs present | UI is web-based — different perf/power profile than native |
| Prefs key `diarizationEnabled` | Ships speaker diarization, user-toggleable |

# Agent 11 — App Store Binary & Compliance Auditor

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source scan across all `Whisperer/` Swift files
- `Whisperer/whisperer.entitlements`, `Whisperer/whisperer-nosandbox.entitlements`, `Whisperer/Info.plist`
- Reference: `docs/exec-plans/app-store-submission.md`, `AGENTS.md` (App Store Compliance)

## Output
Write to `.claude/review-state/findings/agent-11.md`
Return: `Agent 11 (App Store Binary): X P0, Y P1, Z P2`

## Preamble — Always Runs

Agent 11 always runs regardless of diff scope. Read `docs/knowledge/app-store/rules.md` if it exists.

## Focus Checklist

### Banned API Scan (Automated)

**BUG-AS01 (P0)**: Zero tolerance — any of these patterns in the binary causes App Store rejection under Guideline 2.4.5:

```bash
grep -rn 'CGEventTap\|CGEvent\.tapCreate\|IOHIDManager\|IOKit\.hid\|addGlobalMonitorForEvents.*\.keyDown\|addGlobalMonitorForEvents.*\.keyUp\|IOHIDCheckAccess\|IOHIDRequestAccess' Whisperer/ --include='*.swift'
```

Expected: zero results. Every match is P0 — no exceptions.

### AX API Containment

**BUG-AS01 (P0)**: All AX and clipboard-simulation APIs must be inside `#if !APP_STORE`:

```bash
grep -rn 'AXIsProcessTrusted\|AXUIElementCreate\|AXUIElementCopyAttribute\|AXUIElementSetAttribute\|CGEvent\.post\|TextSelectionService' Whisperer/ --include='*.swift'
```

For every match, verify it is inside a `#if !APP_STORE` block. Any match outside such a block is P0.

### Directive Language Scan

**BUG-AS02 (P1)**: Directive permission language triggers Guideline 5.1.1(iv) rejection:

```bash
grep -rn '"Grant\|"Allow.*permiss\|Set Up Later\|Enable Auto-Paste\|autoPaste\|auto-paste\|assistive' Whisperer/ --include='*.swift'
```

Any match NOT inside `#if !APP_STORE` is P1. Approved alternatives: "Continue", "Open Permissions", "Microphone access is needed to transcribe".

### Build Configuration Guard

**BUG-AS04 (P1)**: `#if ENABLE_APP_SANDBOX` is a BUILD SETTING, not a Swift compile flag. It does not work as a Swift `#if` guard — the guarded code is ALWAYS compiled in.

```bash
grep -rn '#if ENABLE_APP_SANDBOX' Whisperer/ --include='*.swift'
```

Every match is P1. Replace with `#if APP_STORE`.

### Info.plist Banned Keys

**BUG-AS03 (P1)**: These keys must NOT be present in the App Store Info.plist:

```bash
grep -n 'NSAppleEventsUsageDescription\|NSServices\|NSInputMonitoringUsageDescription' Whisperer/Info.plist
```

Any match is P1 — these keys signal capabilities that cause App Store review red flags.

Required keys:
- `ITSAppUsesNonExemptEncryption = NO` — must be present
- `NSMicrophoneUsageDescription` — must be present, must say "transcribe your voice" not "record audio"

### Entitlements Audit

**App Store entitlements** (`whisperer.entitlements`) — required and permitted only:
```
com.apple.security.app-sandbox = true
com.apple.security.network.client = true
com.apple.security.device.audio-input = true
com.apple.security.files.user-selected.read-write = true
```

Forbidden (must not be present):
- `com.apple.security.network.server`
- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.disable-library-validation`
- `com.apple.security.temporary-exception.*`

Flag: any new entitlement key added without justification. Flag: `com.apple.security.network.server` as P0.

### Binary String Scan (AppStore Config)

After building the AppStore configuration, run a binary string scan:

```bash
/usr/bin/strings <path-to-binary>/Whisperer.app/Contents/MacOS/whisperer | grep -iE 'AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive'
```

Expected: zero results. Any match is P0 — binary string scanning is how Apple's automated review detects banned patterns even in dead code paths.

### APP_STORE Flag Verification

Verify the `APP_STORE` Swift compiler flag is ONLY present in the AppStore build configuration (Release with sandbox), not in Debug or local Release builds:

```bash
grep -n 'APP_STORE' Whisperer.xcodeproj/project.pbxproj
```

The flag must appear in the AppStore scheme's `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and NOT in Debug or Release configurations.

### Build Configuration Naming

Three configs must exist:
| Config | APP_STORE flag | Sandbox | Purpose |
|--------|---------------|---------|---------|
| Debug | No | No | Development |
| Release | No | No | Local distribution |
| AppStore | Yes | Yes | App Store submission |

Flag any config that has `APP_STORE` flag without sandbox or vice versa.

### Receipt Validation Scope

`ReceiptValidator` must only execute in non-Debug builds:

```bash
grep -n 'ReceiptValidator\|exit(173)' Whisperer/ -r --include='*.swift'
```

Every match must be inside `#if !DEBUG`. `exit(173)` in Debug builds causes crashes during development that waste significant time.

### Hardened Runtime

Hardened Runtime must be enabled for both Release and AppStore configurations. Flag any Xcode build setting that disables Hardened Runtime (`ENABLE_HARDENED_RUNTIME = NO`) outside of Debug.

### CGEvent.post vs CGEvent.tapCreate Distinction

Apple allows `CGEvent.post(tap: .cgAnnotatedSessionEventTap)` for posting synthetic events (clipboard paste). This is DISTINCT from `CGEventTap`/`CGEvent.tapCreate` which MONITORS events. The distinction matters:
- `CGEvent.post` = posting events (approved, no Input Monitoring required)
- `CGEventTap` = monitoring events (rejected by App Store)

When flagging `CGEvent` references, check: `post` is OK in non-APP_STORE builds; `tapCreate` is banned everywhere.

### Verified Approved APIs

These are safe and must NOT be flagged:
- `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` — modifier state changes (not keystrokes)
- `Carbon RegisterEventHotKey` / `UnregisterEventHotKey` — standard macOS hotkey mechanism
- `AXUIElement*` — when inside `#if !APP_STORE`
- `CGEvent.post(tap: .cgAnnotatedSessionEventTap)` — posting synthetic events, when inside `#if !APP_STORE`

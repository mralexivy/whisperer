# Agent 7 — Security, Privacy & Logging Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file
- `Whisperer/whisperer.entitlements`, `Whisperer/whisperer-nosandbox.entitlements`, `Whisperer/Info.plist`
- Reference: `AGENTS.md` (Logging Discipline), `docs/exec-plans/app-store-submission.md`

## Output
Write to `.claude/review-state/findings/agent-07.md`
Return: `Agent 7 (Security & Logging): X P0, Y P1, Z P2`

## Preamble — Always Runs

Agent 7 always runs regardless of diff scope. Read `docs/knowledge/app-store/rules.md` if it exists.

## Focus Checklist

### No print() in Production Code

Run this grep and flag every match as P0:
```bash
grep -rn 'print(' Whisperer/ --include='*.swift' | grep -v '// debug' | grep -v 'Logger'
```
`print()` is permitted ONLY inside `Logger.swift` itself (where it formats the message for console output in debug builds). Every other occurrence is P0.

### Logger Discipline

- Use `Logger.debug`, `Logger.info`, `Logger.warning`, `Logger.error` with the correct subsystem
- Subsystem mapping: `.app` (WhispererApp/AppDelegate), `.audio` (Audio/), `.transcription` (Transcription/), `.ui` (UI/), `.keyListener` (KeyListener/), `.textInjection` (TextInjection/), `.permissions` (Permissions/), `.model` (model loading)
- Log levels:
  - `.debug`: development details, buffer states, performance metrics — filtered in Release
  - `.info`: lifecycle events (model loaded, recording started, bridge initialized)
  - `.warning`: recoverable issues (device unavailable, lock timeout, VAD not loaded)
  - `.error`: failures requiring attention (transcription failed, engine start failed)
  - `.critical`: unrecoverable states (used sparingly)
- Flag: `.error` used for recoverable warnings, `.info` used for debugging details (P2)

### Sensitive Data Logging

- User speech content, transcribed text, file paths to user documents: log only at `.debug` level with `%{private}@` format specifier
- No tokens, passwords, API keys, OAuth tokens in any `Logger` call at any level
- No clipboard contents logged

### App Store Compliance — Banned APIs

**BUG-AS01 (P0)**: These APIs cause App Store rejection under Guideline 2.4.5:

```bash
grep -rn 'CGEventTap\|CGEvent.tapCreate\|IOHIDManager\|IOKit.hid\|addGlobalMonitorForEvents.*\.keyDown\|addGlobalMonitorForEvents.*\.keyUp\|IOHIDCheckAccess\|IOHIDRequestAccess' Whisperer/ --include='*.swift'
```

Zero matches required. Any match is P0.

### App Store Build — AX API Containment

**BUG-AS01 (P0)**: `AXIsProcessTrusted`, `AXUIElement*`, `CGEvent.post`, `TextSelectionService` must only appear inside `#if !APP_STORE` blocks in App Store build targets:

```bash
grep -rn 'AXIsProcessTrusted\|AXUIElementCreate\|AXUIElementCopy\|AXUIElementSet\|CGEvent.post\|TextSelectionService' Whisperer/ --include='*.swift'
```

Every match must be inside `#if !APP_STORE`. Flag any match outside such a block as P0.

### Directive Permission Language

**BUG-AS02 (P1)**: Apple rejects apps with directive language on permission flows (Guideline 5.1.1(iv)):

```bash
grep -rn '"Grant\|Grant.*Access\|Grant.*Permission\|Set Up Later\|Enable Auto-Paste\|autoPaste\|auto-paste\|assistive' Whisperer/ --include='*.swift'
```

Flag any match visible in the App Store build (not inside `#if !APP_STORE`) as P1.

### Build Configuration Guard Consistency

**BUG-AS04 (P1)**: `#if ENABLE_APP_SANDBOX` does NOT work as a Swift compile flag — it's a build setting. Only `#if APP_STORE` works. Flag any `#if ENABLE_APP_SANDBOX` as P1 — the code it guards is ALWAYS compiled in, regardless of the build configuration.

### Entitlements Audit

- Every key in `whisperer.entitlements` must be justified by active code usage
- Required: `com.apple.security.app-sandbox`, `com.apple.security.network.client` (model downloads), `com.apple.security.device.audio-input` (microphone), `com.apple.security.files.user-selected.read-write`
- **Forbidden**: `com.apple.security.network.server` — no server functionality
- Flag any new entitlement not justified by a specific code path

### Info.plist Audit

- `ITSAppUsesNonExemptEncryption = NO` must be present (HTTPS only — exempt)
- `NSMicrophoneUsageDescription` must be present and use informational language: "transcribe your voice" not "record audio"
- **Forbidden in App Store build**: `NSAppleEventsUsageDescription`, `NSServices`
- Flag any new `NS*UsageDescription` key without code-level justification

### Receipt Validation

- `ReceiptValidator` must only execute in Release builds (`#if !DEBUG`)
- `exit(173)` on missing/invalid receipt must only fire in Release

### Hardened Runtime

- The Xcode project must have Hardened Runtime enabled for all non-debug targets
- Flag any entitlement that would bypass Hardened Runtime protections (e.g., `com.apple.security.cs.allow-jit`, `com.apple.security.cs.disable-library-validation`) without explicit justification

---
name: app-store-check
description: >
  Scans Whisperer codebase for App Store Guideline 2.4.5 and 5.1.1(iv)
  violations including banned APIs, permission red flags, directive
  permission language, and features not hidden in APP_STORE build. Use
  when modifying KeyListener, TextInjector, Permissions, or UI code, or
  before App Store submission. Use when user says "check compliance",
  "App Store scan", "guideline check", "2.4.5", or touches input
  handling or text injection code.
metadata:
  version: 2.0.0
  category: compliance
  tags: [app-store, compliance, security, guideline-2.4.5, guideline-5.1.1]
---

# App Store Compliance Check — Guideline 2.4.5 + 5.1.1(iv) Scan

Full codebase scan for APIs and strings that cause App Store rejection. Run before every submission.

## Step 1: Scan for Banned APIs (Guideline 2.4.5)

Search the **entire** `Whisperer/` directory for these patterns. In APP_STORE build, ALL of these must be inside `#if !APP_STORE` blocks:

### Keystroke Monitoring APIs (instant rejection)
- [ ] `CGEvent.tapCreate` or `CGEventTapCreate`
- [ ] `CGEventTapEnable`
- [ ] `IOHIDManager` or `import IOKit.hid`
- [ ] `IOHIDCheckAccess` or `IOHIDRequestAccess`
- [ ] `addGlobalMonitorForEvents` with `.keyDown` or `.keyUp`

### Accessibility APIs (must be inside #if !APP_STORE)
- [ ] `AXIsProcessTrusted` — must not exist in App Store binary
- [ ] `AXUIElementCopyAttributeValue` — must not exist in App Store binary
- [ ] `AXUIElementSetAttributeValue` — must not exist in App Store binary
- [ ] `CGEvent.post` — must not exist in App Store binary
- [ ] `cgAnnotatedSessionEventTap` — must not exist in App Store binary

### Permission Red Flags
- [ ] Any reference to `inputMonitoring` permission type
- [ ] `kTCCServiceListenEvent`

## Step 2: Scan for Directive Permission Language (Guideline 5.1.1(iv))

Apple rejects apps that direct users to grant permissions. Search ALL Swift files:

### Banned Button Text
- [ ] "Grant Microphone Access" — use "Continue" instead
- [ ] "Grant Permissions" — use "Open Permissions" instead
- [ ] "Grant" + any permission name on a button
- [ ] "Set Up Later" or any skip/delay button before a permission request

### Banned Strings in Binary
- [ ] "Enable Auto-Paste" — must be inside `#if !APP_STORE`
- [ ] "auto-paste" or "autoPaste" — must be inside `#if !APP_STORE`
- [ ] "assistive" — must not appear in App Store binary

## Step 3: Verify Features Hidden in APP_STORE Build

These features must be wrapped with `#if !APP_STORE`:
- [ ] Command Mode (sidebar item + related files) — uses `APP_STORE` flag, NOT `ENABLE_APP_SANDBOX`
- [ ] Rewrite Mode (sidebar section, overlay label, accent color, shortcut callbacks, state routing)
- [ ] AI Post-Processing (menu bar settings card)
- [ ] Feedback (workspace sidebar item)
- [ ] Auto-Paste toggle and Accessibility permission UI
- [ ] TextSelectionService (entire file)
- [ ] macOS Services / DictationServiceProvider (should be deleted entirely)

IMPORTANT: `ENABLE_APP_SANDBOX` is a build setting, NOT a Swift compile flag. Any `#if !ENABLE_APP_SANDBOX` must be changed to `#if !APP_STORE`.

## Step 4: Verify Approved APIs

Check that remaining APIs follow required patterns:

### Carbon Hotkey Usage
- [ ] `RegisterEventHotKey` has matching `UnregisterEventHotKey` in teardown
- [ ] `InstallEventHandler` has matching `RemoveEventHandler` in teardown

### flagsChanged Monitor
- [ ] Only monitors `.flagsChanged` (modifier state), never `.keyDown` or `.keyUp`

## Step 5: Verify Binary (Post-Build)

After building, scan the actual binary:
```bash
/usr/bin/strings .../whisperer.app/Contents/MacOS/whisperer | grep -iE "AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive"
```
Must return empty.

## Step 6: Report

For each violation found, report:
- File path and line number
- What was found
- Which guideline it violates (2.4.5 or 5.1.1(iv))
- The fix

If all clean: "App Store compliance check passed — no Guideline 2.4.5 or 5.1.1(iv) violations found."

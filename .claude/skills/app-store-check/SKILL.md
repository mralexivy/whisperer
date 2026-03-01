---
name: app-store-check
description: >
  Scans Whisperer codebase for App Store Guideline 2.4.5 violations including
  banned APIs (CGEventTap, IOHIDManager, global keyDown/keyUp monitors),
  permission red flags, and framing issues. Use when modifying KeyListener,
  TextInjector, or Permissions code, or before App Store submission. Use when
  user says "check compliance", "App Store scan", "guideline check", "2.4.5",
  or touches input handling or text injection code.
metadata:
  version: 1.0.0
  category: compliance
  tags: [app-store, compliance, security, guideline-2.4.5]
---

# App Store Compliance Check — Guideline 2.4.5 Scan

Full codebase scan for APIs that cause App Store rejection. Run before every submission.

## Step 1: Scan for Banned APIs

Search the **entire** `Whisperer/` directory (not just changed files) for these red-flag patterns:

### Keystroke Monitoring APIs (instant rejection)
- [ ] `CGEvent.tapCreate` or `CGEventTapCreate` — keyboard event monitoring/interception
- [ ] `CGEventTapEnable` — enabling an event tap
- [ ] `IOHIDManager` — hardware-level input device monitoring
- [ ] `import IOKit.hid` — IOKit HID framework import
- [ ] `IOHIDCheckAccess` or `IOHIDRequestAccess` — Input Monitoring permission APIs
- [ ] `addGlobalMonitorForEvents` with `.keyDown` or `.keyUp` — global keystroke monitoring
- [ ] `CGEvent(keyboardEventSource:` with `.cghidEventTap` tap point — only `.cgAnnotatedSessionEventTap` is acceptable for posting

### Permission Red Flags
- [ ] Any reference to `inputMonitoring` permission type — should have been removed entirely
- [ ] `kTCCServiceListenEvent` — Input Monitoring TCC service name

### Framing Red Flags
- [ ] User-facing strings containing "keystroke", "key logging", "input monitoring", or "automation" — should use "assistive", "dictation", "voice input" instead
- [ ] `NSAppleEventsUsageDescription` mentioning "automation" without "assistive" context

## Step 2: Verify Approved APIs Are Used Correctly

Check that approved APIs follow required patterns:

### AXUIElement Usage
- [ ] Every `AXUIElementCopyAttributeValue` or `AXUIElementSetAttributeValue` call has `AXUIElementSetMessagingTimeout` set beforehand (100ms recommended)
- [ ] No AX calls dispatched to `DispatchQueue.global()` — must run inline to avoid latency from queue contention
- [ ] AX usage is for text insertion only — not for reading other apps' UI or controlling other apps

### Carbon Hotkey Usage
- [ ] `RegisterEventHotKey` has matching `UnregisterEventHotKey` in teardown
- [ ] `InstallEventHandler` has matching `RemoveEventHandler` in teardown
- [ ] `Unmanaged.passUnretained(self)` used (not `passRetained`) and the object outlives the handler

### CGEvent.post Usage
- [ ] Uses `.cgAnnotatedSessionEventTap` tap point (NOT `.cghidEventTap`)
- [ ] Only used for posting synthetic Cmd+V paste, nothing else

## Step 3: Verify Permissions Configuration

- [ ] `PermissionType` enum contains only `microphone` and `accessibility` — NO `inputMonitoring`
- [ ] Info.plist has `NSMicrophoneUsageDescription` with "transcribe your voice" framing
- [ ] No entitlements beyond: sandbox, network.client, audio-input, files.user-selected.read-write

## Step 4: Report

For each violation found, report:
- File path and line number
- What was found
- Why it causes rejection
- The recommended replacement

If all clean, report: "App Store compliance check passed — no Guideline 2.4.5 violations found."

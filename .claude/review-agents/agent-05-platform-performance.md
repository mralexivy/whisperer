# Agent 5 — macOS Platform & Performance Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file
- Reference: `CLAUDE.md` Critical Rules, `AGENTS.md` Critical Rules, `ARCHITECTURE.md` §5 (Text Injection), §6 (OverlayPanel)

## Output
Write to `.claude/review-state/findings/agent-05.md`
Return: `Agent 5 (Platform & Performance): X P0, Y P1, Z P2`

## Preamble

Read `docs/knowledge/ui/rules.md` if it exists. Check all `Check:` patterns first.

## Focus Checklist

### Overlay Panel Focus

- **P0**: Any call to `.makeKey()`, `.makeKeyAndOrderFront()`, or `.becomeKey()` on `OverlayPanel` or any overlay/HUD window. The overlay must NEVER steal focus from the app where text will be inserted.
- Always use `.orderFront(nil)`. Document any exception with a justification comment.

### Accessibility API Performance

- Every AX call must be preceded by `AXUIElementSetMessagingTimeout` on BOTH the app element AND the focused element — 100ms timeout each. Pattern: `AXUIElementSetMessagingTimeout(appElement, 0.1)` before `AXUIElementSetMessagingTimeout(focusedElement, 0.1)` before any AX attribute get/set. Missing either timeout is P1.
- `state = .idle` must be set **before** `textInjector.insertText(...)` so HUD dismissal runs concurrent with injection. Pattern: `state = .idle; textInjector.insertText(text)`. Flag any path where `state` changes to `.idle` AFTER `insertText` returns. (P0)
- AX calls must NOT be dispatched to `DispatchQueue.global()` — queue contention causes 2–4s multi-second delays. Pattern: any `DispatchQueue.global().async { axElement.setAttribute(...) }`. AX calls run inline on the calling thread. (P1)

### Double Main Queue Dispatch

- **BUG-G03 (P2)**: Callback already on main queue, but handler wraps it in another `DispatchQueue.main.async`. The sender (`AudioRecorder.onAmplitudeUpdate`) already dispatches to main before calling the closure. Wrapping the handler body in another `DispatchQueue.main.async` adds an extra runloop cycle per update — visible animation lag. Pattern: any stored callback (`onAmplitudeUpdate`, `onTranscription`, `onStreamingSamples`) whose handler body begins with `DispatchQueue.main.async { ... }`. Verify whether the sender already guarantees main dispatch.

### Main Actor Blocking

- **BUG-S04 (P1)**: `AudioObjectSetPropertyData`, `AudioObjectGetPropertyData`, `AudioDeviceSetProperty`, or any `CoreAudio` HAL property call on `@MainActor` — these can block 50–200ms on some devices. Must be dispatched to a background `DispatchQueue` or `Task.detached`.
- **BUG-S05 (P1)**: Synchronous `whisper_full()` or tail transcription (`transcribeTail()`, `stop()`) called on `@MainActor`. Whisper.cpp is blocking C code — must never run on the main thread. Use `withCheckedContinuation` on a background queue or a `Task.detached`.
- `unmuteSystemAudio()`: flag if called directly on `@MainActor` without dispatch (BUG-S04).

### Background Timer Suspension

- **BUG-S06 (P2)**: Non-critical background timers not suspended during recording. Any polling timer that checks permissions, processes analytics, or refreshes device lists should be suspended at `startRecording()` and resumed at `stopRecording()`. Flag: any `Timer.scheduledTimer` or `DispatchSourceTimer` that continues firing during recording without explicit justification.

### Layout Invalidation in Animation Loop

- **BUG-S07 (P2)**: `adjustFrameForContent()`, `NSHostingView.fittingSize`, or any NSWindow frame-set call triggered per word in the live transcription animation. These are expensive layout passes. Must be debounced — minimum 100ms between layout invalidations during animation.

### HUD Positioning

- **BUG-U02 (P1)**: HUD positioned using `NSScreen.main` — wrong screen when the user is working on a non-primary monitor. Must use the screen containing the cursor:
  ```swift
  let mouseLocation = NSEvent.mouseLocation
  guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
          ?? NSScreen.main ?? NSScreen.screens.first
  else { return }
  ```
  Flag any use of `NSScreen.main` in `OverlayPanel.position()` or equivalent.

### CALayer Compositing on macOS Tahoe

- **BUG-U01 (P1)**: `layer.masksToBounds = true` + `layer.cornerRadius` on any `NSHostingView` or `NSWindow.contentView` causes text compositing flip/mirror on macOS 26 (Tahoe) for rows created while the window is offscreen. Must use SwiftUI `.clipShape(RoundedRectangle(cornerRadius:))` instead. Flag: any `contentView.layer?.masksToBounds = true` or `contentView.layer?.cornerRadius = X` on an `NSHostingView`. Also flag `window.contentView?.wantsLayer = true` combined with `layer.cornerRadius`.

### Thread Count

- P-core-only thread count via `sysctlbyname("hw.perflevel0.logicalcpu")` minus 2 reserved. Verify `WhisperBridge.optimalThreadCount` is computed this way. Flag any hardcoded thread count or `ProcessInfo.processInfo.activeProcessorCount` without P-core filtering.

### SwiftUI Performance

- No unnecessary `AnyView` type erasure — use direct generic types or `@ViewBuilder`
- `@ObservedObject` granularity: only observe properties you actually use; don't observe the entire `AppState` when you only need one property
- `.id(recordingSessionID)` on `LiveTranscriptionCard` to force state reset between recordings — verify it's present

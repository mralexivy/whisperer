# Agent 10 — HUD, UX & Injection Latency Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file in `Whisperer/UI/`, `Whisperer/TextInjection/`, `WhispererApp.swift`, `Whisperer/Transcription/StreamingTranscriber.swift`
- Reference: `CLAUDE.md` Critical Rules, `ARCHITECTURE.md` §5 (Text Injection), §6 (OverlayPanel), §Live Transcription, §RTL Support, `DESIGN.md`

## Output
Write to `.claude/review-state/findings/agent-10.md`
Return: `Agent 10 (HUD & UX): X P0, Y P1, Z P2`

## Preamble

Run when `changed-files.txt` contains files from `UI/`, `TextInjection/`, or `WhispererApp.swift`. Read `docs/knowledge/ui/rules.md` if it exists.

## Focus Checklist

### state = .idle Before textInjector.insertText()

**P0**: `AppState.state` must be set to `.idle` BEFORE calling `textInjector.insertText(...)`. This allows HUD dismissal to run concurrently with text injection. Pattern: any code path in AppState where `textInjector.insertText(text)` is called before or without a prior `state = .idle`. The order is: `state = .idle` then `textInjector.insertText(text)`.

### OverlayPanel Focus

**P0**: OverlayPanel must NEVER become the key window. Pattern: any `.makeKey()`, `.makeKeyAndOrderFront()`, `.becomeKey()`, or `.activate(ignoringOtherApps:)` on the overlay/HUD panel. Always use `.orderFront(nil)`.

### AX Messaging Timeout

**P1**: Every accessibility API call must be preceded by `AXUIElementSetMessagingTimeout` on BOTH the app element AND the focused element (100ms each). Pattern:
```swift
AXUIElementSetMessagingTimeout(appElement, 0.1)
AXUIElementSetMessagingTimeout(focusedElement, 0.1)
// THEN: AX attribute get/set
```
Missing either timeout is P1 — a hung target app can block injection indefinitely.

### No AX on Background Queues

**P1**: AX calls (`AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`, etc.) must NOT be dispatched to `DispatchQueue.global()`. Queue contention causes 2-4s delays. AX injection runs inline on the calling thread. Pattern: any `DispatchQueue.global().async { axElement.setAttribute(...) }`.

### SmoothTextUpdater Monotonic Invariant

**P0**: `previewAccumulatedText` must only grow during a recording session — text must never shrink mid-recording. If `SmoothTextUpdater.hasPrefix()` fails, the text jumped backward (the preview was not append-only). Pattern: any code that reassigns `previewAccumulatedText` to a shorter string during an active recording session. The only valid reassignment is the chunk handoff (clear + reset after VAD chunk finalizes).

### RTL NSTextField Invariant

**P0**: RTL live transcription text must use `NSTextField` via `NSViewRepresentable` with `NSParagraphStyle.baseWritingDirection = .rightToLeft`. SwiftUI `Text` does NOT support paragraph base writing direction under en-US locale. Pattern: any replacement of `TranscriptionTextView` (NSViewRepresentable) with a SwiftUI `Text` view for RTL languages, or removal of the `baseWritingDirection = .rightToLeft` paragraph style. This was hard-won — 6 SwiftUI approaches were tested and all failed.

### Recording Session ID Reset

**P1**: `LiveTranscriptionCard` must carry `.id(recordingSessionID)` to force SwiftUI state reset between recordings (clears expand/collapse state, animation state, and scroll position). Pattern: `LiveTranscriptionCard(...)` without `.id(recordingSessionID)` modifier. Also verify `recordingSessionID` is incremented on each new recording start.

### Double Main Queue Dispatch

**BUG-G03 (P2)**: Any stored callback (`onAmplitudeUpdate`, `onTranscription`, `onStreamingSamples`) whose handler wraps its body in `DispatchQueue.main.async` when the sender already guarantees main dispatch. Verify by reading the sender — if it already dispatches to main before calling the closure, the handler must NOT re-wrap. Extra runloop cycle adds visible animation lag.

### Layout Pass Debounce

**BUG-S07 (P2)**: `adjustFrameForContent()`, `NSHostingView.fittingSize`, or any `NSWindow.setFrame(...)` call triggered per word in the live transcription animation. Must be debounced to ≥ 100ms between layout invalidations during animation. Pattern: `adjustFrameForContent()` called inside `SmoothTextUpdater`'s per-word update callback without debounce.

### HUD Screen Position

**BUG-U02 (P1)**: HUD must be positioned on the screen containing the user's cursor, not `NSScreen.main`. Pattern: `NSScreen.main` in `OverlayPanel.position()` or equivalent positioning logic. Correct:
```swift
let mouseLocation = NSEvent.mouseLocation
guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
    ?? NSScreen.main ?? NSScreen.screens.first
else { return }
```

### CALayer Compositing on macOS Tahoe

**BUG-U01 (P1)**: `layer.masksToBounds = true` + `layer.cornerRadius` on `NSHostingView` causes text compositing flip on macOS 26 (Tahoe) for rows created while the window is offscreen. Pattern: `contentView.wantsLayer = true; contentView.layer?.masksToBounds = true; contentView.layer?.cornerRadius = X` on any `NSHostingView`. Use SwiftUI `.clipShape(RoundedRectangle(cornerRadius:))` instead.

### Onboarding Shown Only Once

**BUG-U03 (P1)**: Any onboarding window show call must be guarded by `hasCompletedOnboarding` check. Pattern: `OnboardingWindowManager.shared.show()` or equivalent without `guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")`.

### Window Manager Fresh Instance

**BUG-U04 (P2)**: `show(startingAtPage:)` must always create a fresh window instance — it must NOT reuse an existing window that may be on a different page. Pattern: `if window == nil { ... }` check in the window manager's show method. Always deallocate and recreate.

### Window Restoration Zombies

**BUG-U05 (P2)**: Custom `NSWindow` subclasses must prevent macOS window restoration from creating zombie instances. Pattern: any `NSWindow` subclass without `NSQuitAlwaysKeepsWindows = false` in `Info.plist` and `closeOrphanedWindows()` guard in the manager's `init`.

### Animation State Re-Trigger

**BUG-U06 (P2)**: `.onAppear { isAnimating = true }` does not re-fire if SwiftUI view identity is stable between recordings. Pattern: any animation state reset that sets `isAnimating = false; isAnimating = true` in a single synchronous block — the UI won't animate because both assignments happen before the next render cycle. Fix: `isAnimating = false; DispatchQueue.main.async { isAnimating = true }`.

### Per-Item Hover State Cleanup

**BUG-U07 (P2)**: Any list or chart with per-item `onHover` state must also reset the hover state at the container level. Pattern: per-item `onHover { isHovered = true/false }` without a surrounding `ZStack.onHover { if !$0 { hoverIndex = nil } }` or equivalent container reset. Cursor exit through container boundaries doesn't trigger the item-level `onHover(false)`.

### Hands-Free Delete Guard

**BUG-U10 (P1)**: The synthetic `Delete` keystroke in hands-free/Fn+L mode must be guarded by `keyWasIntercepted` (or equivalent flag). Pattern: `deleteLastCharacter()` called without checking whether a physical character was typed or the Carbon hotkey intercepted the input. If the hotkey intercepted, no character was typed and the delete would remove existing content.

### 5-Second Safety Timeout

The 5-second parallel stop safety Task in `stopRecording()` must:
1. Run concurrently with `audioRecorder.stopRecording()`
2. Check `state == .stopping` before forcing idle
3. Clear `streamingTranscriber` and `liveTranscription` on timeout
4. The main stop Task must check `guard case .stopping = state` after `audioRecorder.stopRecording()` returns

Verify all four conditions exist and are intact.

### Clipboard Content Restoration

In non-App Store builds, `TextInjector`'s clipboard fallback must:
1. Save clipboard content BEFORE setting new text
2. Wait 100ms after simulated paste
3. Restore previous clipboard content
4. Guard against clipboard changeCount racing (save changeCount at backup time, only restore if current changeCount matches paste count) — **BUG-T04**

### Watchdog Registration

The audio progress watchdog (`startRecordingWatchdog()`) must be registered for each new recording session. Pattern: any `startRecording()` path that does not call `startRecordingWatchdog()` or its equivalent before starting the audio engine.

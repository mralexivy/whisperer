# Meeting Detection Redesign + Window Wiring

**Date:** 2026-08-09  
**Status:** Approved

## Context

The meeting detection notification card was functional but visually generic — a flat card with a pulsing dot and basic buttons that didn't match Whisperer's premium dark navy design language. Additionally, tapping "Start Notes" had two bugs: (1) the `MeetingSession` was created as a throwaway Task-local variable and immediately deallocated, leaving `AppState.activeMeetingSession` as a dangling weak reference; (2) no window was opened, so the live transcript was invisible to the user unless they manually navigated to History → Meeting Notes.

This spec covers: a premium animated notification card redesign, a session ownership fix, and wiring "Start Notes" to open the meeting window automatically.

---

## Part 1: Notification Card Redesign

### Placement
Stays inside the existing `OverlayPanel` (bottom-center, non-activating NSPanel). No position change.

### Dimensions
~380pt wide, ~120pt tall. Compact — does not dominate the screen.

### Background & Border
- Card surface: `#0C0C1A` background, `#14142B` card inner surface
- Outer border: 1pt stroke rendered as an `AngularGradient` with a bright accent spot (`#5B6CF7` → transparent → transparent → `#5B6CF7`) that rotates 360° on a **3s linear repeat** loop — the "light sweeping around the edge" effect
- Corner radius: 16pt

### Sonar Rings (App Icon)
The detected app icon (44pt, rounded 10pt corners) sits on a `#1C1C3A` elevated circle (56pt). Three concentric accent-blue (`#5B6CF7`) ring overlays animate in staggered sonar pulses on a **1.8s easeOut repeat** loop:

| Ring | Delay | Scale range | Opacity range |
|------|-------|-------------|---------------|
| 1 (inner) | 0.0s | 1.0 → 1.18 | 0.80 → 0.0 |
| 2 (mid)   | 0.5s | 1.0 → 1.32 | 0.50 → 0.0 |
| 3 (outer) | 1.0s | 1.0 → 1.48 | 0.30 → 0.0 |

Each ring is a `Circle` stroke (1pt for rings 1–2, 0.5pt for ring 3) scaled relative to the icon circle.

### Background Glow
A radial gradient blob behind the card (`#5B6CF7` → `#8B5CF6` → clear, opacity 0.08 max) scales 1.0 → 1.12 → 1.0 on a **2.4s easeInOut autoreverse repeat** loop. Barely perceptible — adds depth without distraction.

### Layout
```
┌─ [rotating gradient border] ──────────────────────────┐
│  MEETING DETECTED                          [gradient]  │  ← 10pt bold, tracking 1.2
│  ─────────────────────────────────────────────────     │  ← 0.5pt divider
│                                                        │
│  [◉⃝⃝⃝ sonar]  AppName                               │  ← 15pt semibold
│                Want to capture this meeting?           │  ← 13pt, white.opacity(0.5)
│                                                        │
│  [████████ Start Notes ████████]  [Dismiss]            │
└────────────────────────────────────────────────────────┘
```

- Header: "MEETING DETECTED" — 10pt bold, tracking 1.2, gradient text (blue → purple via `LinearGradient` on foregroundStyle)
- App name: 15pt semibold, `Color.white`
- Subtitle: "Want to capture this meeting?" — 13pt regular, `white.opacity(0.5)`
- **Start Notes button**: gradient fill (`#5B6CF7` → `#8B5CF6`), white text 14pt semibold, `Capsule` shape, full width minus dismiss button
- **Dismiss button**: ghost — transparent background, `white.opacity(0.40)` text, 14pt regular

### Appear Animation
Spring enter on `.onAppear` with a 0.05s delay:
- Scale: 0.90 → 1.0
- Y offset: +24 → 0
- Opacity: 0 → 1
- Spring: `response: 0.42, dampingFraction: 0.70`

All ring/border/glow animations start on `.onAppear`.

### Dismiss Animation
Same spring reversed (scale → 0.94, Y → +10, opacity → 0) applied before the state change removes the card. Use `withAnimation` + a 0.35s `Task.sleep` before the actual dismiss call so the animation completes visually.

---

## Part 2: Session Ownership Fix

### Problem
`startNotes()` in `MeetingNotificationCard` creates a `MeetingSession()` as a Task-local variable. After the Task completes, the session is deallocated. `AppState.activeMeetingSession` is declared `weak var`, so it becomes `nil` almost immediately. `MeetingStudioView` creates its own independent `@StateObject session = MeetingSession()` — completely disconnected from the one the card started.

### Fix

**`AppState.swift`**  
Change `private(set) weak var activeMeetingSession: MeetingSession?` to `private(set) var activeMeetingSession: MeetingSession?` (strong reference). AppState owns the session for its lifetime.

**`MeetingNotificationCard.startNotes()`**  
Create the session and pass it to `AppState.startMeetingRecording(session:)` before calling `session.startRecording(title:)`. The existing `startMeetingRecording(session:)` method already sets `activeMeetingSession` — with the strong reference fix, it will be retained.

**`MeetingStudioView`**  
Replace `@StateObject private var session = MeetingSession()` with a read from `AppState.shared.activeMeetingSession`. Since the view is only shown when a session is active (via `.meetingStudio` sidebar selection during recording), guard with `guard let session = AppState.shared.activeMeetingSession` and show a placeholder if nil. Pass `session` down to child views that currently receive it as `@ObservedObject`.

---

## Part 3: Window Opening Flow

**`MeetingNotificationCard.startNotes()` — full updated sequence:**
1. Trigger dismiss animation (new)
2. After 0.35s: call `AppState.shared.dismissMeetingNotification()` (existing)
3. Create `MeetingSession()`
4. Call `AppState.shared.startMeetingRecording(session: session)` — stores strong reference
5. Call `await session.startRecording(title: app.name)` — starts mic + whisper pipeline
6. Call `HistoryWindowManager.shared.showWindowAndDismissMenu()` — opens History window
7. Set `AppState.shared.sidebarSelection = .meetingStudio` — navigates to live view

**Result:** User sees the meeting window open immediately with live transcript appearing word-by-word. The existing "Stop Recording" button in `MeetingListPanel` remains unchanged.

---

## Files Modified

| File | Change |
|------|--------|
| `Whisperer/UI/MeetingNotificationCard.swift` | Full card redesign + all animations + updated `startNotes()` |
| `Whisperer/AppState.swift` | `weak var activeMeetingSession` → strong `var` |
| `Whisperer/Meetings/UI/MeetingStudioView.swift` | Read session from `AppState.shared` instead of `@StateObject` |

---

## Verification

1. Build Debug — no compile errors
2. Run app — trigger meeting detection manually (or launch Zoom/Slack)
3. Confirm card animates in with sonar rings, rotating border, background glow
4. Confirm card springs in from bottom and sinks out on dismiss
5. Tap "Start Notes" — confirm History window opens on Meeting Studio view
6. Confirm live transcript appears word-by-word as you speak
7. Tap "Stop Recording" in the window — confirm session ends cleanly
8. Re-trigger detection (quit/relaunch Zoom) — confirm new card appears with fresh session

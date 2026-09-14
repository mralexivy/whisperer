# Island: Configurable Placement + Intent-Gated Reveal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users choose where the Island lives (top/bottom/left/right edge) in workspace settings, and gate the idle bar's appearance behind a 700 ms dwell+stillness reveal with a 250 ms progressive sliver hint.

**Architecture:** A new `IslandPlacement` enum drives three layers: `IslandGeometryProvider` (pure frame math, injectable), `IslandContentSizer` (axis-aware sizes), and `IslandContentView`/`IslandLayout` (visual layout + vertical pill variants). A pure `IslandRevealGate` struct replaces the instant hover-reveal for the idle state. The coordinator observes a `.islandPlacementChanged` notification and re-applies geometry without rebuilding the panel.

**Tech Stack:** Swift/SwiftUI/AppKit (macOS), XCTest. No new dependencies.

**Spec:** `/Users/alexanderi/.claude/plans/foamy-honking-kettle.md`

## Global Constraints

- All new units that are not `@MainActor` classes must be `nonisolated` — CLAUDE.md warns that `@MainActor` pure-Swift class `deinit` in a synchronous test causes `pointer being freed was not allocated` in the test host.
- No `print()` — use `Logger.shared` (subsystem: `.ui`).
- `[weak self]` in all `Task.detached` closures and stored callbacks.
- Never add an early-return on "model unchanged" in `publishViewModel` / `apply(viewModel:screen:)` — per `IslandCoordinator.swift:301-303`, the panel is built lazily inside `apply()` and will silently never appear.
- Follow `PolishFeatureFlags` key+default pattern: every `UserDefaults` key and its default live in exactly one place (see `Transcription/Graph/PolishFeatureFlags.swift:70-95`).
- Run only the scoped test suites listed per task — never the full suite (slow corpus tests take 18+ minutes).

---

## File Map

| File | Role | New/Modified |
|---|---|---|
| `Whisperer/Island/IslandPlacement.swift` | Placement enum, key, default, `current` helper | **new** |
| `Whisperer/Island/IslandUX.swift` | Single `nonisolated enum IslandUX` constants table shared by views + tests | **new** |
| `Whisperer/Island/IslandRevealGate.swift` | Pure dwell+stillness reveal-phase gate | **new** |
| `Whisperer/Island/IslandGeometryProvider.swift` | Per-edge anchor, envelope clamp, header | modified |
| `Whisperer/Island/IslandContentSizer.swift` | Axis-aware sizes, `anchorSlack`, sliver geometry | modified |
| `Whisperer/Island/IslandState.swift` | `IslandLauncherHint.anchorX` → `anchor`; add `IslandRevealPhase` | modified |
| `Whisperer/Island/IslandContentView.swift` | Placement-driven root layout, 3-phase reveal, hit box | modified |
| `Whisperer/Island/IslandLayout.swift` | Vertical row variants, hint anchor along long axis | modified |
| `Whisperer/Island/IslandCoordinator.swift` | Drive the gate, observe placement notification, generalise edge retention | modified |
| `Whisperer/Island/IslandPanelController.swift` | Non-animated reframe on placement change; placement-aware logging | modified |
| `Whisperer/History/HistoryWindowView.swift` | `islandSection` — visual placement picker inserted before `overlaySection` | modified |
| `Whisperer/Extensions/Notification+Extensions.swift` | Add `.islandPlacementChanged` | modified |
| `WhispererTests/IslandPlacementTests.swift` | `IslandRevealGateTests` + `IslandRevealInteractionTests` + `IslandUXInvariantTests` + placement persistence | **new** |
| `WhispererTests/IslandGeometryTests.swift` | Extend with 4-placement × 7-screen matrix | modified |
| `WhispererTests/IslandContentSizerTests.swift` | Extend with axis-swap, long-axis clamp, sliver | modified |

---

## Task 1: Foundation — `IslandPlacement`, `IslandUX`, notifications

**Files:**
- Create: `Whisperer/Island/IslandPlacement.swift`
- Create: `Whisperer/Island/IslandUX.swift`
- Modify: `Whisperer/Extensions/Notification+Extensions.swift`

**Interfaces:**
- Produces:
  - `nonisolated enum IslandPlacement: String, CaseIterable, Identifiable` with cases `topCenter`, `bottomCenter`, `leftCenter`, `rightCenter`
  - `IslandPlacement.isVertical: Bool`
  - `IslandPlacement.displayName: String`
  - `IslandPlacement.defaultsKey: String` = `"islandPlacement"`
  - `IslandPlacement.defaultValue: IslandPlacement` = `.bottomCenter`
  - `IslandPlacement.current: IslandPlacement` (reads UserDefaults, returns `defaultValue` if missing)
  - `nonisolated enum IslandUX` with all timing/sizing constants (replaces magic numbers in views)
  - `NSNotification.Name.islandPlacementChanged`

- [ ] **Step 1: Create `IslandPlacement.swift`**

This file also defines `IslandRevealPhase` so it is available to `IslandContentSizer` (Task 3) before `IslandRevealGate.swift` is created (Task 4).

```swift
// Whisperer/Island/IslandPlacement.swift
import Foundation

// MARK: - Reveal phase (defined here so IslandContentSizer can reference it without forward deps)

nonisolated enum IslandRevealPhase: Equatable {
    case hidden
    /// Progressive sliver visible at the edge — intent suspected, not confirmed
    case sliver
    /// Full bar revealed — user is aiming at it
    case revealed
}

// MARK: - Placement

nonisolated enum IslandPlacement: String, CaseIterable, Identifiable {
    case topCenter    = "topCenter"
    case bottomCenter = "bottomCenter"
    case leftCenter   = "leftCenter"
    case rightCenter  = "rightCenter"

    var id: String { rawValue }

    var isVertical: Bool { self == .leftCenter || self == .rightCenter }

    var displayName: String {
        switch self {
        case .topCenter:    return "Top"
        case .bottomCenter: return "Bottom"
        case .leftCenter:   return "Left"
        case .rightCenter:  return "Right"
        }
    }

    /// SF Symbol for the settings diagram button
    var settingsGlyph: String {
        switch self {
        case .topCenter:    return "arrow.up.to.line"
        case .bottomCenter: return "arrow.down.to.line"
        case .leftCenter:   return "arrow.left.to.line"
        case .rightCenter:  return "arrow.right.to.line"
        }
    }

    // MARK: - Persistence (follow PolishFeatureFlags pattern: one place for key + default)
    static let defaultsKey   = "islandPlacement"
    static let defaultValue  = IslandPlacement.bottomCenter

    static var current: IslandPlacement {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let p = IslandPlacement(rawValue: raw) else { return defaultValue }
        return p
    }

    static func save(_ placement: IslandPlacement) {
        UserDefaults.standard.set(placement.rawValue, forKey: defaultsKey)
    }
}
```

- [ ] **Step 2: Create `IslandUX.swift`**

Extract every magic number from `IslandContentView.swift` and `IslandLayout.swift` (hover padding 40/22/12, hint band 31, spring responses, reveal timings) into one authoritative source. Views will be updated to read from this in later tasks.

```swift
// Whisperer/Island/IslandUX.swift
import Foundation

/// Single authoritative source for Island UX constants.
/// Views and tests both read from here so a single edit is the only way to drift.
nonisolated enum IslandUX {

    // MARK: - Reveal timing
    /// Duration the pointer must dwell still before the sliver appears (seconds)
    static let sliverDelay: TimeInterval  = 0.25
    /// Duration the pointer must dwell still before the full bar appears (seconds)
    static let revealDelay: TimeInterval  = 0.70
    /// Max pointer movement (pt) that counts as "still" during dwell
    static let stillnessRadius: CGFloat   = 12
    /// How long after hover-exit before the bar hides (seconds)
    static let hoverExitDebounce: TimeInterval = 0.10

    // MARK: - Hover padding (for hit box / hover rect)
    /// Extra horizontal padding around the idle/peek pill for the hover zone
    static let hoverHPadGenerous: CGFloat  = 40
    /// Extra upward padding for the idle/peek pill
    static let hoverVPadUpGenerous: CGFloat = 22
    /// Extra downward padding for the idle/peek pill
    static let hoverVPadDownGenerous: CGFloat = 12
    /// Standard narrow padding for a visible non-idle row
    static let hoverPadNarrow: CGFloat     = 12
    static let hoverVPadNarrowUp: CGFloat  = 3
    static let hoverVPadNarrowDown: CGFloat = 3

    // MARK: - Hint label
    /// Fixed height reserved for the floating hint chip band above the pill
    static let hintBandHeight: CGFloat    = 31

    // MARK: - Animation durations / springs
    /// Open spring response (seconds)
    static let springResponseOpen: Double  = 0.42
    /// Close spring response (seconds)
    static let springResponseClose: Double = 0.45
    /// Hint chip cross-fade duration (seconds)
    static let hintFadeDuration: Double    = 0.18
    /// Max allowed animation duration for any reveal-path animation (for UX invariant tests)
    static let maxRevealAnimDuration: Double = 0.45
    /// ReduceMotion linear duration (seconds)
    static let reduceMotionDuration: Double = 0.12

    // MARK: - Sliver
    /// Thickness of the progressive sliver (pt) on the anchored edge
    static let sliverThickness: CGFloat   = 3

    // MARK: - Tap targets (UX invariant: every action ≥ 44 pt on both axes)
    static let minTapTarget: CGFloat      = 28  // glyph capsule (matches launcherItemWidth)
    static let minA11yTapTarget: CGFloat  = 44  // full accessibility minimum

    // MARK: - Hot-zone area cap
    /// Hover rect must cover ≤ this fraction of the screen (anti-hijack guard)
    static let maxHoverZoneFraction: CGFloat = 0.12
}
```

- [ ] **Step 3: Add `.islandPlacementChanged` notification name**

In `Whisperer/Extensions/Notification+Extensions.swift`, add after the `.overlaySettingsChanged` line:
```swift
static let islandPlacementChanged = Notification.Name("islandPlacementChanged")
```

- [ ] **Step 4: Build to verify compilation**
```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | grep -E "error:|Build succeeded"
```
Expected: `Build succeeded`

- [ ] **Step 5: Commit**
```bash
git add Whisperer/Island/IslandPlacement.swift \
        Whisperer/Island/IslandUX.swift \
        Whisperer/Extensions/Notification+Extensions.swift
git commit -m "feat(island): add IslandPlacement enum, IslandUX constants, placement notification"
```

---

## Task 2: Geometry — per-edge anchor in `IslandGeometryProvider`

**Files:**
- Modify: `Whisperer/Island/IslandGeometryProvider.swift`
- Modify: `WhispererTests/IslandGeometryTests.swift`

**Interfaces:**
- Consumes: `IslandPlacement` (Task 1)
- Produces:
  - `IslandGeometryProvider` gains `var placement: IslandPlacement = .bottomCenter`
  - `IslandGeometryProvider.edgeAnchor(for:placement:) -> CGFloat` (nonisolated static)
  - `IslandGeometryProvider.hasEdgeObstruction(_:edge:) -> Bool` (nonisolated static)
  - `IslandGeometryProvider.envelopeOuterEdge(for:placement:) -> CGFloat` (nonisolated static)
  - Existing `bottomAnchor`, `hasBottomObstruction`, `envelopeBottom` remain as `@available(*, deprecated)` aliases delegating to the new API so existing call sites compile while being updated in later tasks

- [ ] **Step 1: Write failing geometry tests for the 4 placements**

Add to `WhispererTests/IslandGeometryTests.swift` a new section `// MARK: - Multi-placement` after the existing tests:

```swift
// MARK: - Multi-placement anchor tests

/// Compact frame lands on the anchored edge for every placement.
func testCompactFrameAnchoredEdge_bottomCenter() {
    var geo = IslandGeometryProvider(); geo.placement = .bottomCenter
    let s = standardScreen
    let f = geo.compactFrame(for: s)
    XCTAssertEqual(f.minY, IslandGeometryProvider.edgeAnchor(for: s, placement: .bottomCenter),
                   accuracy: 0.5, "bottomCenter: compact minY must equal edgeAnchor")
}

func testCompactFrameAnchoredEdge_topCenter() {
    var geo = IslandGeometryProvider(); geo.placement = .topCenter
    let s = standardScreen
    let f = geo.compactFrame(for: s)
    // For topCenter the pill's maxY touches the anchor (the frame grows downward from the top edge)
    XCTAssertEqual(f.maxY, IslandGeometryProvider.edgeAnchor(for: s, placement: .topCenter),
                   accuracy: 0.5, "topCenter: compact maxY must equal edgeAnchor")
}

func testCompactFrameAnchoredEdge_leftCenter() {
    var geo = IslandGeometryProvider(); geo.placement = .leftCenter
    let s = standardScreen
    let f = geo.compactFrame(for: s)
    XCTAssertEqual(f.minX, IslandGeometryProvider.edgeAnchor(for: s, placement: .leftCenter),
                   accuracy: 0.5, "leftCenter: compact minX must equal edgeAnchor")
}

func testCompactFrameAnchoredEdge_rightCenter() {
    var geo = IslandGeometryProvider(); geo.placement = .rightCenter
    let s = standardScreen
    let f = geo.compactFrame(for: s)
    XCTAssertEqual(f.maxX, IslandGeometryProvider.edgeAnchor(for: s, placement: .rightCenter),
                   accuracy: 0.5, "rightCenter: compact maxX must equal edgeAnchor")
}

/// Envelope contains all three tier frames for every placement.
func testEnvelopeContainsAllTiers_allPlacements() {
    for placement in IslandPlacement.allCases {
        var geo = IslandGeometryProvider(); geo.placement = placement
        let s = standardScreen
        let env = geo.panelEnvelope(for: s)
        XCTAssert(env.contains(geo.peekFrame(for: s)),
                  "\(placement): envelope must contain peekFrame")
        XCTAssert(env.contains(geo.compactFrame(for: s)),
                  "\(placement): envelope must contain compactFrame")
        XCTAssert(env.contains(geo.expandedFrame(for: s)),
                  "\(placement): envelope must contain expandedFrame")
    }
}

/// Pill stays inside visibleFrame for every placement on every screen fixture.
func testPillInsideVisibleFrame_allPlacementsAllScreens() {
    let screens = [standardScreen, hdScreen, negativeOriginScreen, narrowScreen]
    for placement in IslandPlacement.allCases {
        var geo = IslandGeometryProvider(); geo.placement = placement
        for s in screens {
            let f = geo.compactFrame(for: s)
            XCTAssert(s.visibleFrame.contains(f) || s.frame.contains(f),
                      "\(placement) on \(s.frame): compactFrame \(f) outside screen")
        }
    }
}

/// Dock on left must not be occluded when placement is leftCenter.
func testLeftCenterClearsLeftDock() {
    // Simulate a left-side Dock: visibleFrame.minX > frame.minX
    let leftDockScreen = ScreenDescription(
        frame:        NSRect(x: 0, y: 0,   width: 2560, height: 1600),
        visibleFrame: NSRect(x: 80, y: 25, width: 2480, height: 1543),
        backingScale: 2
    )
    var geo = IslandGeometryProvider(); geo.placement = .leftCenter
    let f = geo.compactFrame(for: leftDockScreen)
    XCTAssertGreaterThanOrEqual(f.minX,
        IslandGeometryProvider.edgeAnchor(for: leftDockScreen, placement: .leftCenter) - 0.5,
        "leftCenter pill must clear the left Dock")
}
```

- [ ] **Step 2: Run — expect failures because the API doesn't exist yet**
```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:WhispererTests/IslandGeometryTests 2>&1 | grep -E "error:|FAILED|passed"
```

- [ ] **Step 3: Implement per-edge anchor in `IslandGeometryProvider`**

Replace the entire file with this updated version. The key changes are:
1. Add `var placement: IslandPlacement = .bottomCenter`
2. Add generic `edgeAnchor(for:placement:)`, `hasEdgeObstruction(_:edge:)`, `envelopeOuterEdge(for:placement:)`
3. Replace `centeredFrame` with `anchoredFrame(width:height:screen:)` that switches on placement
4. Keep `bottomAnchor`/`hasBottomObstruction`/`envelopeBottom` as deprecated forwarders

Add to the `// MARK: - Frame builders` section:

```swift
var placement: IslandPlacement = .bottomCenter

func peekFrame(for screen: ScreenDescription) -> NSRect {
    if placement.isVertical {
        return anchoredFrame(long: IslandContentSizer.idlePeekWidth,
                             thick: IslandContentSizer.idlePeekHeight, screen: screen)
    }
    return centeredFrame(width: C.peekWidth, height: C.peekHeight, screen: screen)
}

func compactFrame(for screen: ScreenDescription) -> NSRect {
    if placement.isVertical {
        return anchoredFrame(long: IslandContentSizer.idleCompactWidth,
                             thick: IslandContentSizer.idleCompactHeight, screen: screen)
    }
    return centeredFrame(width: C.compactWidth, height: C.compactHeight, screen: screen)
}

func expandedFrame(for screen: ScreenDescription) -> NSRect {
    if placement.isVertical {
        return anchoredFrame(long: C.expandedWidth,
                             thick: C.expandedHeight, screen: screen)
    }
    return centeredFrame(width: C.expandedWidth, height: C.expandedHeight, screen: screen)
}
```

Replace `private func centeredFrame(...)` with `private func centeredFrame(...)` (keep existing horizontal logic) and add:

```swift
/// Axis-agnostic frame: `long` runs along the anchored edge, `thick` is the pill's depth
/// away from the edge. Growth is always away from the anchored edge.
private func anchoredFrame(long: CGFloat, thick: CGFloat, screen: ScreenDescription) -> NSRect {
    switch placement {
    case .bottomCenter:
        var x = screen.frame.origin.x + (screen.frame.width - long) / 2
        x = max(screen.frame.origin.x + C.minHClearance,
                min(screen.frame.maxX - long - C.minHClearance, x))
        let y = IslandGeometryProvider.edgeAnchor(for: screen, placement: .bottomCenter)
        return NSRect(x: x, y: y, width: long, height: thick)

    case .topCenter:
        var x = screen.frame.origin.x + (screen.frame.width - long) / 2
        x = max(screen.frame.origin.x + C.minHClearance,
                min(screen.frame.maxX - long - C.minHClearance, x))
        let anchor = IslandGeometryProvider.edgeAnchor(for: screen, placement: .topCenter)
        // Pill grows downward: maxY == anchor
        return NSRect(x: x, y: anchor - thick, width: long, height: thick)

    case .leftCenter:
        let anchor = IslandGeometryProvider.edgeAnchor(for: screen, placement: .leftCenter)
        var y = screen.frame.origin.y + (screen.frame.height - long) / 2
        y = max(screen.frame.origin.y + C.minHClearance,
                min(screen.frame.maxY - long - C.minHClearance, y))
        // Pill grows rightward: minX == anchor
        return NSRect(x: anchor, y: y, width: thick, height: long)

    case .rightCenter:
        let anchor = IslandGeometryProvider.edgeAnchor(for: screen, placement: .rightCenter)
        var y = screen.frame.origin.y + (screen.frame.height - long) / 2
        y = max(screen.frame.origin.y + C.minHClearance,
                min(screen.frame.maxY - long - C.minHClearance, y))
        // Pill grows leftward: maxX == anchor
        return NSRect(x: anchor - thick, y: y, width: thick, height: long)
    }
}
```

Replace the `// MARK: - Dock-aware bottom anchor` extension with:

```swift
extension IslandGeometryProvider {

    // MARK: - Generic edge anchor (all four edges)

    /// True when the OS (Dock, Stage Manager, menu bar, etc.) insets `visibleFrame`
    /// from `frame` by more than 1 pt on the given edge.
    nonisolated static func hasEdgeObstruction(_ s: ScreenDescription,
                                               placement: IslandPlacement) -> Bool {
        switch placement {
        case .bottomCenter: return s.visibleFrame.minY - s.frame.minY > 1
        case .topCenter:    return s.frame.maxY - s.visibleFrame.maxY > 1
        case .leftCenter:   return s.visibleFrame.minX - s.frame.minX > 1
        case .rightCenter:  return s.frame.maxX - s.visibleFrame.maxX > 1
        }
    }

    /// Global coordinate of the pill's edge that touches the screen border.
    nonisolated static func edgeAnchor(for s: ScreenDescription,
                                       placement: IslandPlacement) -> CGFloat {
        switch placement {
        case .bottomCenter:
            return hasEdgeObstruction(s, placement: .bottomCenter)
                ? s.visibleFrame.minY + C.dockGap
                : s.frame.minY        + C.edgeInset
        case .topCenter:
            return hasEdgeObstruction(s, placement: .topCenter)
                ? s.visibleFrame.maxY - C.dockGap
                : s.frame.maxY        - C.edgeInset
        case .leftCenter:
            return hasEdgeObstruction(s, placement: .leftCenter)
                ? s.visibleFrame.minX + C.dockGap
                : s.frame.minX        + C.edgeInset
        case .rightCenter:
            return hasEdgeObstruction(s, placement: .rightCenter)
                ? s.visibleFrame.maxX - C.dockGap
                : s.frame.maxX        - C.edgeInset
        }
    }

    /// Outer-edge coordinate for the panel envelope clamp (slack subtracted inward).
    nonisolated static func envelopeOuterEdge(for s: ScreenDescription,
                                              placement: IslandPlacement) -> CGFloat {
        switch placement {
        case .bottomCenter:
            return max(edgeAnchor(for: s, placement: .bottomCenter) - C.panelSlack, s.frame.minY)
        case .topCenter:
            return min(edgeAnchor(for: s, placement: .topCenter) + C.panelSlack, s.frame.maxY)
        case .leftCenter:
            return max(edgeAnchor(for: s, placement: .leftCenter) - C.panelSlack, s.frame.minX)
        case .rightCenter:
            return min(edgeAnchor(for: s, placement: .rightCenter) + C.panelSlack, s.frame.maxX)
        }
    }

    // MARK: - Deprecated forwarding aliases (remove once all call sites are updated)

    @available(*, deprecated, renamed: "edgeAnchor(for:placement:)")
    nonisolated static func bottomAnchor(for s: ScreenDescription) -> CGFloat {
        edgeAnchor(for: s, placement: .bottomCenter)
    }

    @available(*, deprecated, renamed: "hasEdgeObstruction(_:placement:)")
    nonisolated static func hasBottomObstruction(_ s: ScreenDescription) -> Bool {
        hasEdgeObstruction(s, placement: .bottomCenter)
    }

    @available(*, deprecated, renamed: "envelopeOuterEdge(for:placement:)")
    nonisolated static func envelopeBottom(for s: ScreenDescription) -> CGFloat {
        envelopeOuterEdge(for: s, placement: .bottomCenter)
    }
}
```

Update `panelEnvelope(for:)` to clamp the correct edge based on `placement`:

```swift
func panelEnvelope(for screen: ScreenDescription) -> NSRect {
    let peek     = peekFrame(for: screen)
    let compact  = compactFrame(for: screen)
    let expanded = expandedFrame(for: screen)
    let union    = peek.union(compact).union(expanded)

    let s = C.panelSlack
    let inflated = NSRect(x: union.minX - s, y: union.minY - s,
                          width: union.width + s*2, height: union.height + s*2)

    // Clamp the anchored edge to reach the screen border; other edges stay inside visibleFrame.
    let outerEdge = IslandGeometryProvider.envelopeOuterEdge(for: screen, placement: placement)
    switch placement {
    case .bottomCenter:
        let minX = max(inflated.minX, screen.visibleFrame.minX)
        let maxX = min(inflated.maxX, screen.visibleFrame.maxX)
        let maxY = min(inflated.maxY, screen.visibleFrame.maxY)
        return NSRect(x: minX, y: outerEdge, width: max(0, maxX - minX),
                      height: max(0, maxY - outerEdge))
    case .topCenter:
        let minX = max(inflated.minX, screen.visibleFrame.minX)
        let maxX = min(inflated.maxX, screen.visibleFrame.maxX)
        let minY = max(inflated.minY, screen.visibleFrame.minY)
        return NSRect(x: minX, y: minY, width: max(0, maxX - minX),
                      height: max(0, outerEdge - minY))
    case .leftCenter:
        let minY = max(inflated.minY, screen.visibleFrame.minY)
        let maxY = min(inflated.maxY, screen.visibleFrame.maxY)
        let maxX = min(inflated.maxX, screen.visibleFrame.maxX)
        return NSRect(x: outerEdge, y: minY, width: max(0, maxX - outerEdge),
                      height: max(0, maxY - minY))
    case .rightCenter:
        let minY = max(inflated.minY, screen.visibleFrame.minY)
        let maxY = min(inflated.maxY, screen.visibleFrame.maxY)
        let minX = max(inflated.minX, screen.visibleFrame.minX)
        return NSRect(x: minX, y: minY, width: max(0, outerEdge - minX),
                      height: max(0, maxY - minY))
    }
}
```

Also update `localPeekFrame`, `localCompactFrame`, `localExpandedFrame` — they already use `offsetBy(dx:dy:)` and don't change. Update `shouldDrawShadow` to remain `true`. Update the file header comment to remove "no top-edge placement."

- [ ] **Step 4: Run geometry tests — expect them to pass**
```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:WhispererTests/IslandGeometryTests 2>&1 | grep -E "error:|FAILED|passed|succeeded"
```
Expected: all tests pass.

- [ ] **Step 5: Commit**
```bash
git add Whisperer/Island/IslandGeometryProvider.swift \
        WhispererTests/IslandGeometryTests.swift
git commit -m "feat(island): per-edge anchor in IslandGeometryProvider; geometry tests for all 4 placements"
```

---

## Task 3: Sizer — axis-aware sizes + sliver geometry

**Files:**
- Modify: `Whisperer/Island/IslandContentSizer.swift`
- Modify: `WhispererTests/IslandContentSizerTests.swift`

**Interfaces:**
- Consumes: `IslandPlacement` (Task 1), `IslandUX.sliverThickness` (Task 1)
- Produces:
  - `IslandContentSizer.targetSize(capture:presentation:screen:isHovering:gestureProgress:placement:revealPhase:) -> CGSize` — placement-aware, sliver-aware
  - `IslandContentSizer.anchorSlack(screen:placement:) -> CGFloat` replaces `bottomSlack(screen:)`
  - `IslandContentSizer.bottomSlack(screen:)` deprecated, forwarding to `anchorSlack`

- [ ] **Step 1: Write failing sizer tests**

Extend `WhispererTests/IslandContentSizerTests.swift`:

```swift
// MARK: - Axis swap

func testTargetSize_verticalPlacement_swapsAxes() {
    // At leftCenter the returned CGSize has width==thick and height==long
    let hSize = IslandContentSizer.targetSize(
        capture: .idle, presentation: .compact, screen: stdScreen,
        isHovering: false, gestureProgress: 0,
        placement: .bottomCenter, revealPhase: .revealed
    )
    let vSize = IslandContentSizer.targetSize(
        capture: .idle, presentation: .compact, screen: stdScreen,
        isHovering: false, gestureProgress: 0,
        placement: .leftCenter, revealPhase: .revealed
    )
    // Vertical: width and height swap
    XCTAssertEqual(vSize.width, hSize.height, accuracy: 0.5,
                   "vertical width should equal horizontal height")
    XCTAssertEqual(vSize.height, hSize.width, accuracy: 0.5,
                   "vertical height should equal horizontal width")
}

func testTargetSize_sliver_returnsCorrectThickness() {
    for placement in IslandPlacement.allCases {
        let sz = IslandContentSizer.targetSize(
            capture: .idle, presentation: .compact, screen: stdScreen,
            isHovering: false, gestureProgress: 0,
            placement: placement, revealPhase: .sliver
        )
        let thickness = placement.isVertical ? sz.width : sz.height
        XCTAssertEqual(thickness, IslandUX.sliverThickness, accuracy: 0.5,
                       "\(placement) sliver thickness mismatch")
    }
}

func testTargetSize_verticalLongAxisClamped() {
    // 420 pt recording bar must clamp to short screen height
    let shortScreen = ScreenDescription(
        frame: NSRect(x: 0, y: 0, width: 1280, height: 700),
        visibleFrame: NSRect(x: 0, y: 23, width: 1280, height: 655),
        backingScale: 2
    )
    let sz = IslandContentSizer.targetSize(
        capture: .recording, presentation: .compact, screen: shortScreen,
        isHovering: false, gestureProgress: 0,
        placement: .leftCenter, revealPhase: .revealed
    )
    XCTAssertLessThanOrEqual(sz.height,
        shortScreen.frame.height - IslandGeometryProvider.C.minHClearance * 2,
        "long axis must not overflow short screen")
}

func testAnchorSlack_allPlacements() {
    // anchorSlack must be ≥ 0 for all placements and screen fixtures
    for placement in IslandPlacement.allCases {
        let slack = IslandContentSizer.anchorSlack(screen: stdScreen, placement: placement)
        XCTAssertGreaterThanOrEqual(slack, 0,
            "\(placement): anchorSlack should be non-negative")
    }
}
```

- [ ] **Step 2: Run — expect failures**
```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:WhispererTests/IslandContentSizerTests 2>&1 | grep -E "error:|FAILED|passed"
```

- [ ] **Step 3: Update `IslandContentSizer`**

Add `placement` and `revealPhase` parameters to `targetSize`; compute `(long, thick)` then map to `CGSize`. Add `anchorSlack`. Keep `bottomSlack` as a deprecated forwarder.

```swift
static func targetSize(
    capture: IslandCaptureState,
    presentation: IslandPresentation,
    screen: ScreenDescription,
    isHovering: Bool,
    gestureProgress: CGFloat,
    placement: IslandPlacement = .bottomCenter,
    revealPhase: IslandRevealPhase = .revealed
) -> CGSize {
    guard presentation != .hidden else { return .zero }

    // Sliver: the progressive edge hint before the full bar appears
    if capture == .idle && revealPhase == .sliver {
        let longAxis: CGFloat
        switch capture {
        case .idle: longAxis = idleCompactWidth
        default:    longAxis = recordingWidth
        }
        if placement.isVertical {
            return CGSize(width: IslandUX.sliverThickness, height: longAxis)
        } else {
            return CGSize(width: longAxis, height: IslandUX.sliverThickness)
        }
    }

    let isIdle = capture == .idle

    if presentation == .peek {
        let hoverExtra: CGFloat = isHovering ? peekHoverLift : 0
        let stretchExtra: CGFloat = max(gestureProgress * 0.5, 0)
        let baseLong = isIdle ? idlePeekWidth : GC.peekWidth
        let baseThick = isIdle ? idlePeekHeight : GC.peekHeight
        let longAxis = min(baseLong + hoverExtra + stretchExtra,
                           (placement.isVertical ? screen.frame.height : screen.frame.width)
                           - GC.minHClearance * 2)
        if placement.isVertical { return CGSize(width: baseThick, height: longAxis) }
        return CGSize(width: longAxis, height: baseThick)
    }

    let isExpanded = presentation == .expanded && !isIdle
    let hoverLift: CGFloat = isHovering && !isExpanded ? 8 : 0
    let stretch: CGFloat = max(gestureProgress * 0.8, 0)

    let baseLong: CGFloat
    switch capture {
    case .idle:                        baseLong = idleCompactWidth
    case .starting, .finalizing:       baseLong = statusWidth
    case .permissionRequired, .failed: baseLong = attentionWidth
    case .recording, .paused:          baseLong = recordingWidth
    }

    let screenLongAxis = placement.isVertical ? screen.frame.height : screen.frame.width
    let longAxis = min(
        baseLong + hoverLift + stretch + (isExpanded ? expandedExtraWidth : 0),
        screenLongAxis - GC.minHClearance * 2
    )
    let thick = compactHeight(for: capture) + (isExpanded ? expandedExtraHeight : 0)

    if placement.isVertical { return CGSize(width: thick, height: max(longAxis, 0)) }
    return CGSize(width: max(longAxis, 0), height: thick)
}

/// Padding on the anchored side of the island body inside the panel.
static func anchorSlack(screen: ScreenDescription, placement: IslandPlacement) -> CGFloat {
    let anchor = IslandGeometryProvider.edgeAnchor(for: screen, placement: placement)
    let outer  = IslandGeometryProvider.envelopeOuterEdge(for: screen, placement: placement)
    switch placement {
    case .bottomCenter, .leftCenter:
        return max(0, anchor - outer)
    case .topCenter, .rightCenter:
        return max(0, outer - anchor)
    }
}

@available(*, deprecated, renamed: "anchorSlack(screen:placement:)")
static func bottomSlack(screen: ScreenDescription) -> CGFloat {
    anchorSlack(screen: screen, placement: .bottomCenter)
}
```

- [ ] **Step 4: Run sizer tests — expect pass**
```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:WhispererTests/IslandContentSizerTests 2>&1 | grep -E "error:|FAILED|passed"
```

- [ ] **Step 5: Commit**
```bash
git add Whisperer/Island/IslandContentSizer.swift \
        WhispererTests/IslandContentSizerTests.swift
git commit -m "feat(island): axis-aware targetSize, anchorSlack, sliver geometry in IslandContentSizer"
```

---

## Task 4: `IslandRevealGate` — pure dwell+stillness state machine

**Files:**
- Create: `Whisperer/Island/IslandRevealGate.swift`
- Create: `WhispererTests/IslandPlacementTests.swift` (partial — gate tests only)

**Interfaces:**
- Produces:
  - `nonisolated enum IslandRevealPhase: Equatable` with cases `hidden`, `sliver`, `revealed`
  - `nonisolated struct IslandRevealGate` with `mutating func step(point:inside:now:) -> IslandRevealPhase`
  - `IslandRevealGate.reset() -> IslandRevealPhase` (.hidden)

- [ ] **Step 1: Write the failing gate unit tests**

Create `WhispererTests/IslandPlacementTests.swift`:

```swift
//
//  IslandPlacementTests.swift
//  WhispererTests
//
//  Tests for IslandRevealGate, IslandRevealInteraction, IslandUXInvariants,
//  and settings persistence.
//  Run: xcodebuild test -only-testing:WhispererTests/IslandPlacementTests
//

import XCTest
@testable import whisperer

final class IslandRevealGateTests: XCTestCase {

    // MARK: - Helpers

    /// Tick the gate `n` times at the given point, spacing ticks by `dt` seconds.
    @discardableResult
    private func tick(_ gate: inout IslandRevealGate,
                      at point: NSPoint, inside: Bool, n: Int,
                      dt: TimeInterval, startTime: TimeInterval = 0) -> IslandRevealPhase {
        var phase = IslandRevealPhase.hidden
        for i in 0..<n {
            phase = gate.step(point: point, inside: inside, now: startTime + Double(i) * dt)
        }
        return phase
    }

    // MARK: - Fast pass-through

    func testFastPassThrough_neverReveals() {
        var gate = IslandRevealGate()
        // 10 ticks, each 0.01 s apart, pointer moving 30 pt — total 0.09 s, well under sliverDelay
        var phase = IslandRevealPhase.hidden
        for i in 0..<10 {
            phase = gate.step(point: NSPoint(x: CGFloat(i * 30), y: 0),
                              inside: true, now: Double(i) * 0.01)
        }
        XCTAssertEqual(phase, .hidden, "fast pass-through should never reveal")
    }

    // MARK: - Sliver threshold

    func testStillDwell_reachesSliver() {
        var gate = IslandRevealGate()
        let pt = NSPoint(x: 100, y: 50)
        // Tick just past the sliver threshold with tiny jitter (< stillnessRadius)
        let phase = tick(&gate, at: pt, inside: true,
                         n: 30, dt: IslandUX.sliverDelay / 28)
        XCTAssertEqual(phase, .sliver, "still dwell past sliverDelay should produce .sliver")
    }

    func testStillDwell_reachesRevealed() {
        var gate = IslandRevealGate()
        let pt = NSPoint(x: 100, y: 50)
        let phase = tick(&gate, at: pt, inside: true,
                         n: 80, dt: IslandUX.revealDelay / 78)
        XCTAssertEqual(phase, .revealed, "still dwell past revealDelay should produce .revealed")
    }

    // MARK: - Stillness radius

    func testJitterUnderRadius_doesNotReset() {
        var gate = IslandRevealGate()
        let origin = NSPoint(x: 100, y: 100)
        // Advance to sliver
        tick(&gate, at: origin, inside: true, n: 30, dt: IslandUX.sliverDelay / 28)
        // Now jitter ±(stillnessRadius - 1) — should not reset
        var phase = IslandRevealPhase.hidden
        let jitter = IslandUX.stillnessRadius - 1
        for i in 0..<20 {
            let moved = NSPoint(x: origin.x + (i % 2 == 0 ? jitter : -jitter), y: origin.y)
            phase = gate.step(point: moved, inside: true,
                              now: IslandUX.sliverDelay + Double(i) * 0.03)
        }
        XCTAssertNotEqual(phase, .hidden,
                          "jitter under stillnessRadius must not reset the gate")
    }

    func testLargeMove_resetsGate() {
        var gate = IslandRevealGate()
        let origin = NSPoint(x: 100, y: 100)
        tick(&gate, at: origin, inside: true, n: 30, dt: IslandUX.sliverDelay / 28)
        // Move more than stillnessRadius — gate should reset
        let moved = NSPoint(x: origin.x + IslandUX.stillnessRadius + 5, y: origin.y)
        let phase = gate.step(point: moved, inside: true,
                              now: IslandUX.sliverDelay + 0.01)
        XCTAssertEqual(phase, .hidden, "move beyond stillnessRadius should reset to .hidden")
    }

    // MARK: - Zone exit

    func testLeavingZone_resetsToHidden() {
        var gate = IslandRevealGate()
        let pt = NSPoint(x: 100, y: 100)
        tick(&gate, at: pt, inside: true, n: 80, dt: IslandUX.revealDelay / 78)
        let phase = gate.step(point: pt, inside: false, now: IslandUX.revealDelay + 0.1)
        XCTAssertEqual(phase, .hidden, "exiting the zone must reset to .hidden")
    }

    // MARK: - Monotonic advance

    func testRevealIsMonotonic() {
        var gate = IslandRevealGate()
        let pt = NSPoint(x: 200, y: 200)
        var seen = Set<IslandRevealPhase>()
        var prev = IslandRevealPhase.hidden
        for i in 0..<100 {
            let phase = gate.step(point: pt, inside: true, now: Double(i) * 0.01)
            seen.insert(phase)
            // Must never go backwards (hidden < sliver < revealed)
            let rank = { (p: IslandRevealPhase) -> Int in
                switch p { case .hidden: 0; case .sliver: 1; case .revealed: 2 }
            }
            XCTAssertGreaterThanOrEqual(rank(phase), rank(prev),
                                        "reveal must be monotonically advancing")
            prev = phase
        }
    }
}
```

- [ ] **Step 2: Run — expect failures**
```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:WhispererTests/IslandPlacementTests 2>&1 | grep -E "error:|FAILED|passed"
```

- [ ] **Step 3: Implement `IslandRevealGate.swift`**

```swift
// Whisperer/Island/IslandRevealGate.swift
// Note: IslandRevealPhase is declared in IslandPlacement.swift (Task 1).
import Foundation

// MARK: - Gate

/// Pure dwell+stillness state machine for the idle Island reveal.
/// nonisolated and @MainActor-free so it can be tested without the MainActor deinit hazard.
nonisolated struct IslandRevealGate {

    // MARK: State
    private var phase:      IslandRevealPhase = .hidden
    private var entryTime:  TimeInterval = 0
    private var entryPoint: NSPoint = .zero

    // MARK: - Mutating step

    /// Advance or reset the gate. Call on every mouseMoved event from the container.
    ///
    /// - Parameters:
    ///   - point: Pointer location in any consistent coordinate space (panel or screen).
    ///   - inside: Whether the pointer is inside the hot zone.
    ///   - now: Monotonic timestamp (e.g. `CACurrentMediaTime()`).
    /// - Returns: The new reveal phase.
    @discardableResult
    mutating func step(point: NSPoint, inside: Bool, now: TimeInterval) -> IslandRevealPhase {
        guard inside else {
            return reset()
        }

        // Once revealed, stillness no longer applies — the user is interacting with buttons.
        if phase == .revealed { return .revealed }

        let distance = hypot(point.x - entryPoint.x, point.y - entryPoint.y)

        if distance > IslandUX.stillnessRadius {
            // Re-anchor. The clock restarts from the new point.
            entryPoint = point
            entryTime  = now
            phase = .hidden
            return .hidden
        }

        // Pointer is still within the stillness radius.
        let elapsed = now - entryTime
        if elapsed >= IslandUX.revealDelay {
            phase = .revealed
        } else if elapsed >= IslandUX.sliverDelay {
            phase = .sliver
        }
        return phase
    }

    /// Force the gate back to `.hidden` and reset the clock.
    @discardableResult
    mutating func reset() -> IslandRevealPhase {
        phase      = .hidden
        entryTime  = 0
        entryPoint = .zero
        return .hidden
    }

    /// Entry-point for when the pointer first enters the zone (call before `step`).
    mutating func entered(point: NSPoint, now: TimeInterval) {
        entryPoint = point
        entryTime  = now
        phase      = .hidden
    }
}
```

- [ ] **Step 4: Run gate tests — expect pass**
```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:WhispererTests/IslandPlacementTests 2>&1 | grep -E "error:|FAILED|passed"
```

- [ ] **Step 5: Commit**
```bash
git add Whisperer/Island/IslandRevealGate.swift \
        WhispererTests/IslandPlacementTests.swift
git commit -m "feat(island): IslandRevealGate — pure dwell+stillness reveal phase machine with unit tests"
```

---

## Task 5: `IslandState` — rename `anchorX` → `anchor`, add `IslandRevealPhase`

**Files:**
- Modify: `Whisperer/Island/IslandState.swift`

**Interfaces:**
- Produces: `IslandLauncherHint.anchor: CGFloat` (replaces `anchorX`)

- [ ] **Step 1: Update `IslandLauncherHint` in `IslandState.swift`**

Change line 132:
```swift
// Before:
nonisolated struct IslandLauncherHint: Equatable {
    var title: String
    var anchorX: CGFloat
}

// After:
nonisolated struct IslandLauncherHint: Equatable {
    var title: String
    /// Position of the glyph's centre along the hint-label axis (X when horizontal, Y when vertical).
    var anchor: CGFloat
}
```

- [ ] **Step 2: Build and fix every call site that used `anchorX`**

Call sites (`IslandCoordinator.swift:153-154`, `IslandContentView.swift:251`, `IslandLayout.swift:392-397`) will produce compiler errors. Fix each:
- `IslandCoordinator.setLauncherHint(_:anchorX:)` → `setLauncherHint(_:anchor:)` (rename param)
- `IslandCoordinator.clearLauncherHint(ifTitleIs:)` — no change
- `IslandLayout.LauncherItem` — rename `anchorX` stored property to `anchor`, update the `setLauncherHint` call

```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Step 3: Commit**
```bash
git add Whisperer/Island/IslandState.swift \
        Whisperer/Island/IslandCoordinator.swift \
        Whisperer/Island/IslandContentView.swift \
        Whisperer/Island/IslandLayout.swift
git commit -m "refactor(island): rename IslandLauncherHint.anchorX → anchor for axis-agnostic hint placement"
```

---

## Task 6: Coordinator — drive the gate, observe placement, generalise edge retention

**Files:**
- Modify: `Whisperer/Island/IslandCoordinator.swift`
- Modify: `Whisperer/Island/IslandPanelController.swift`

**Interfaces:**
- Consumes: `IslandRevealGate` (Task 4), `IslandPlacement` (Task 1)
- Produces:
  - `IslandCoordinator.idleRevealPhase: IslandRevealPhase` (published)
  - `IslandCoordinator.placement: IslandPlacement` (reading `IslandPlacement.current` on init)
  - `IslandCoordinator.handlePointerMoved(point:inside:)` — new method called from `IslandContainerView`

- [ ] **Step 1: Add placement + gate properties to `IslandCoordinator`**

After the existing `private var hoverTask` block, add:

```swift
// Placement
private(set) var placement: IslandPlacement = IslandPlacement.current {
    didSet {
        // Propagate to the geometry provider used by the panel controller
        panelController?.geo.placement = placement
        rehomeToActiveScreen()
    }
}

// Reveal gate (idle-only intent detection)
private var revealGate = IslandRevealGate()
@Published private(set) var idleRevealPhase: IslandRevealPhase = .hidden
```

- [ ] **Step 2: Subscribe to `.islandPlacementChanged` in `wireAppState()`**

Add after the existing `.objectWillChange` subscription in `wireAppState()`:

```swift
NotificationCenter.default.publisher(for: .islandPlacementChanged)
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in
        guard let self else { return }
        let newPlacement = IslandPlacement.current
        guard newPlacement != self.placement else { return }
        // Reset the gate on placement change — any in-progress hover belongs to the old edge
        self.revealGate.reset()
        withAnimation(.none) { self.idleRevealPhase = .hidden }
        self.placement = newPlacement
    }
    .store(in: &cancellables)
```

- [ ] **Step 3: Add `handlePointerMoved(point:inside:)` to the coordinator**

```swift
/// Called by `IslandContainerView.mouseMoved` with the pointer location and whether
/// the cursor is inside the hover rect. Drives `IslandRevealGate` for idle state.
func handlePointerMoved(point: NSPoint, inside: Bool) {
    let isIdle = currentViewModel.capture == .idle
    guard isIdle else {
        // Non-idle capture states bypass the gate — always fully opaque
        if idleRevealPhase != .revealed {
            idleRevealPhase = .revealed
        }
        return
    }

    let now = CACurrentMediaTime()
    let newPhase = revealGate.step(point: point, inside: inside, now: now)
    if newPhase != idleRevealPhase {
        withAnimation(newPhase == .hidden
            ? .easeOut(duration: IslandUX.hoverExitDebounce)
            : .easeIn(duration: 0.12)) {
            idleRevealPhase = newPhase
        }
    }
}
```

Also update `handleHover(_ hovering: Bool)`: when `hovering == false`, call `revealGate.reset()` and set `idleRevealPhase = .hidden` in addition to the existing debounce logic. The existing `isHovering` path remains for the non-idle hover lift animation.

- [ ] **Step 4: Generalise `shouldRetainHoverAtBottomEdge()` to all edges**

Replace `IslandCoordinator.shouldRetainHoverAtBottomEdge()` (`:174-184`):

```swift
private func shouldRetainHoverAtAnchoredEdge() -> Bool {
    let loc = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: {
        $0.frame.contains(loc) || abs($0.frame.minY - loc.y) < 2
    }) else { return false }

    switch placement {
    case .bottomCenter:
        guard loc.y <= screen.frame.minY + 1.5 else { return false }
    case .topCenter:
        guard loc.y >= screen.frame.maxY - 1.5 else { return false }
    case .leftCenter:
        guard loc.x <= screen.frame.minX + 1.5 else { return false }
    case .rightCenter:
        guard loc.x >= screen.frame.maxX - 1.5 else { return false }
    }

    let span = hoverRectOnScreen
    guard span.width > 0, span.height > 0 else { return false }

    return placement.isVertical
        ? loc.y >= span.minY && loc.y <= span.maxY
        : loc.x >= span.minX && loc.x <= span.maxX
}
```

Rename all call sites from `shouldRetainHoverAtBottomEdge()` to `shouldRetainHoverAtAnchoredEdge()`.

- [ ] **Step 5: Make `IslandPanelController.geo` mutable**

In `IslandPanelController.swift`, change:
```swift
// Before:
private let geo = IslandGeometryProvider()

// After:
var geo = IslandGeometryProvider()
```

Also update `logPlacement(for:screen:)` to log the current `geo.placement`.

- [ ] **Step 6: Build**
```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Step 7: Commit**
```bash
git add Whisperer/Island/IslandCoordinator.swift \
        Whisperer/Island/IslandPanelController.swift
git commit -m "feat(island): coordinator drives reveal gate, observes placement notification, generalises edge retention"
```

---

## Task 7: `IslandPanel` — forward pointer location to coordinator

**Files:**
- Modify: `Whisperer/Island/IslandPanel.swift`

**Interfaces:**
- Consumes: `IslandCoordinator.handlePointerMoved(point:inside:)` (Task 6)

The existing `updateHover(with:)` in `IslandContainerView` (`:129-136`) fires on every `mouseMoved`. Add the pointer location forwarding here.

- [ ] **Step 1: Update `updateHover` in `IslandContainerView`**

Replace the existing `updateHover(with:)` method body:

```swift
private func updateHover(with event: NSEvent) {
    let loc = flip(convert(event.locationInWindow, from: nil))
    let inside = hitBox?.hoverRect.contains(loc) ?? false

    // Forward raw pointer position so the coordinator's reveal gate can apply
    // dwell+stillness logic. The global-space point is needed for the edge-retention test.
    let globalLoc = event.locationInWindow.applying(
        CGAffineTransform(translationX: frame.origin.x, y: frame.origin.y)
    )
    coordinator?.handlePointerMoved(point: globalLoc, inside: inside)

    DispatchQueue.main.async { [weak self] in
        guard let coord = self?.coordinator, inside != coord.isHovering else { return }
        coord.handleHover(inside)
    }
}
```

- [ ] **Step 2: Build**
```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Step 3: Commit**
```bash
git add Whisperer/Island/IslandPanel.swift
git commit -m "feat(island): forward pointer location to coordinator for reveal gate"
```

---

## Task 8: `IslandContentView` — placement-driven layout, 3-phase reveal, hit box

**Files:**
- Modify: `Whisperer/Island/IslandContentView.swift`

**Interfaces:**
- Consumes: `IslandCoordinator.idleRevealPhase` (Task 6), `IslandPlacement` (Task 1), `IslandUX` constants (Task 1), `IslandContentSizer.anchorSlack(screen:placement:)` (Task 3), updated `targetSize` (Task 3)

- [ ] **Step 1: Thread placement through `IslandContentView`**

Add at top of `IslandContentView`:
```swift
private var placement: IslandPlacement { coordinator.placement }
private var revealPhase: IslandRevealPhase { coordinator.idleRevealPhase }
```

- [ ] **Step 2: Update `isIdleHidden` / `isIdleBar` to use `revealPhase`**

Replace lines 124-126:
```swift
private var isIdleBar:    Bool { vm.capture == .idle }
private var isIdleHidden: Bool { isIdleBar && revealPhase == .hidden }
private var isIdleSliver: Bool { isIdleBar && revealPhase == .sliver }
```

- [ ] **Step 3: Update `targetSize` call**

In `var targetSize` (`:95-103`), add `placement:` and `revealPhase:` arguments:
```swift
private var targetSize: CGSize {
    IslandContentSizer.targetSize(
        capture: vm.capture,
        presentation: vm.presentation,
        screen: screen,
        isHovering: isHovering,
        gestureProgress: coordinator.gestureProgress,
        placement: placement,
        revealPhase: revealPhase
    )
}
```

- [ ] **Step 4: Update `bottomSlack` → `anchorSlack`**

```swift
private var anchorSlack: CGFloat {
    IslandContentSizer.anchorSlack(screen: screen, placement: placement)
}
```

- [ ] **Step 5: Replace hardcoded VStack with placement-driven container in `rootBodyView`**

Replace `rootBodyView` (`:225-237`):

```swift
private var rootBodyView: some View {
    placementContainer
        .animation(nil, value: morphKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .sensoryFeedback(.alignment, trigger: coordinator.hapticToken)
}

@ViewBuilder
private var placementContainer: some View {
    switch placement {
    case .bottomCenter:
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            hintLabel
            islandBody
            Color.clear.frame(height: anchorSlack)
        }
    case .topCenter:
        VStack(spacing: 0) {
            Color.clear.frame(height: anchorSlack)
            islandBody
            hintLabel
            Spacer(minLength: 0)
        }
    case .leftCenter:
        HStack(spacing: 0) {
            Color.clear.frame(width: anchorSlack)
            islandBody
            hintLabel   // chip appears to the right of pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    case .rightCenter:
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            hintLabel   // chip appears to the left of pill
            islandBody
            Color.clear.frame(width: anchorSlack)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
```

- [ ] **Step 6: Update `hintLabel` to use `anchor` (not `anchorX`) and handle vertical axis**

In `hintLabel` (`:247-262`), update the hint offset:
```swift
// Before:
.offset(x: hint.anchorX - envelopeWidth / 2)

// After — X for horizontal, Y for vertical:
.offset(
    x: placement.isVertical ? 0 : (hint.anchor - envelopeWidth / 2),
    y: placement.isVertical ? (hint.anchor - envelopeHeight / 2) : 0
)
```

Add `private var envelopeHeight: CGFloat` mirroring `envelopeWidth`:
```swift
private var envelopeHeight: CGFloat {
    IslandGeometryProvider().panelEnvelope(for: screen).height
}
```

- [ ] **Step 7: Update `islandBody` scale/offset to grow from the anchored edge**

Replace the three `.opacity`/`.scaleEffect`/`.offset` modifiers (`:306-309`):

```swift
.opacity(isIdleHidden ? 0 : 1)
.scaleEffect(
    CGSize(
        width:  isIdleHidden ? 0.94 : (isIdleSliver && !placement.isVertical ? 1.0 : 1.0),
        height: isIdleHidden ? 0.94 : (isIdleSliver && placement.isVertical  ? 1.0 : 1.0)
    ),
    anchor: anchorForScaleEffect
)
.offset(
    x: isIdleHidden ? (placement == .leftCenter ? -5 : placement == .rightCenter ? 5 : 0) : 0,
    y: isIdleHidden ? (placement == .bottomCenter ? 5 : placement == .topCenter ? -5 : 0) : 0
)
.allowsHitTesting(!isIdleHidden && !isIdleSliver)  // sliver: hover zone only, no clicks
```

Add helper:
```swift
private var anchorForScaleEffect: UnitPoint {
    switch placement {
    case .bottomCenter: return .bottom
    case .topCenter:    return .top
    case .leftCenter:   return .leading
    case .rightCenter:  return .trailing
    }
}
```

- [ ] **Step 8: Update `hintBandHeight` constant to use `IslandUX.hintBandHeight`**

```swift
// Before:
private static let hintBandHeight: CGFloat = 31

// After: reference the constant table
private var hintBandHeight: CGFloat { IslandUX.hintBandHeight }
```

Update `.frame(height: Self.hintBandHeight)` → `.frame(height: hintBandHeight)`.

- [ ] **Step 9: Update hover padding constants in `updateHitBox` to use `IslandUX`**

Replace the four magic numbers in `updateHitBox` (`:382-384`):
```swift
let hPad:     CGFloat = generousCatch ? IslandUX.hoverHPadGenerous     : IslandUX.hoverPadNarrow
let vPadUp:   CGFloat = generousCatch ? IslandUX.hoverVPadUpGenerous   : IslandUX.hoverVPadNarrowUp
let vPadDown: CGFloat = generousCatch ? IslandUX.hoverVPadDownGenerous : IslandUX.hoverVPadNarrowDown
```

- [ ] **Step 10: Build**
```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Step 11: Commit**
```bash
git add Whisperer/Island/IslandContentView.swift
git commit -m "feat(island): placement-driven root layout, 3-phase reveal, anchorSlack in IslandContentView"
```

---

## Task 9: `IslandLayout` — vertical row variants + hint anchor along long axis

**Files:**
- Modify: `Whisperer/Island/IslandLayout.swift`

**Interfaces:**
- Consumes: `IslandCoordinator.placement` (Task 6)
- No new public interfaces

- [ ] **Step 1: Add placement accessor to `IslandLayout`**

Add after `private var isExpanded`:
```swift
private var placement: IslandPlacement { coordinator.placement }
private var isVertical: Bool { placement.isVertical }
```

- [ ] **Step 2: Make `idleLauncherRow` axis-aware**

Replace `idleLauncherRow` body — currently `HStack(spacing: 2)` — with:

```swift
private var idleLauncherRow: some View {
    Group {
        if isVertical {
            VStack(spacing: 2) { launcherItems }
        } else {
            HStack(spacing: 2) { launcherItems }
        }
    }
    .padding(isVertical ? .vertical : .horizontal, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.layoutDirection, .leftToRight)
}

@ViewBuilder
private var launcherItems: some View {
    launcherItem(icon: "mic.fill", title: "Dictate",
                 help: "Start dictation — click the stop button in the recording bar to finish") {
        coordinator.send(.dictateRequested)
    }
    launcherItem(icon: "person.2.fill", title: "Meeting",
                 help: "Start a meeting recording") {
        coordinator.send(.startMeetingRequested)
    }
    launcherDivider
    launcherItem(icon: "list.clipboard.fill", title: "Paste Bin",
                 help: "Open recent transcriptions") {
        coordinator.send(.openPasteBinRequested)
    }
    launcherItem(icon: "square.grid.2x2.fill", title: "Workspace",
                 help: "Open the Whisperer workspace") {
        coordinator.send(.openWorkspaceRequested)
    }
}

private var launcherDivider: some View {
    Rectangle()
        .fill(IC.primary.opacity(0.12))
        .frame(width: isVertical ? 16 : 1,
               height: isVertical ? 1 : 16)
        .padding(isVertical ? .horizontal : .vertical, 5)
        .accessibilityHidden(true)
}
```

- [ ] **Step 3: Make `recordingRow` axis-aware**

When `isVertical`, the waveform should be rotated and the controls stacked:

```swift
private func recordingRow(isPaused: Bool) -> some View {
    if isVertical {
        verticalRecordingRow(isPaused: isPaused)
    } else {
        horizontalRecordingRow(isPaused: isPaused)
    }
}

private func horizontalRecordingRow(isPaused: Bool) -> some View {
    // existing strip { ... } implementation, no change
    strip {
        RecordingDot(isPaused: isPaused)
    } trailing: {
        HStack(spacing: 8) {
            IslandWaveform(levelBridge: levelBridge, isPaused: isPaused || vm.isMicMuted)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.rowHeight)
            Text(clock.displayText)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(IC.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 40, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.3), value: clock.displayText)
            IslandHoverButton(
                icon: isPaused ? "play.fill" : "pause.fill",
                diameter: metrics.controlSize,
                iconColor: IC.primary
            ) {
                coordinator.send(.pauseResumeRequested(sessionID: vm.sessionID))
            }
            .help(isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
            inlineStopButton
        }
    }
}

private func verticalRecordingRow(isPaused: Bool) -> some View {
    VStack(spacing: 6) {
        RecordingDot(isPaused: isPaused)

        IslandWaveform(levelBridge: levelBridge, isPaused: isPaused || vm.isMicMuted)
            .frame(maxHeight: .infinity)
            .rotationEffect(.degrees(-90))

        Text(clock.displayText)
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundColor(IC.primary)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.3), value: clock.displayText)

        IslandHoverButton(
            icon: isPaused ? "play.fill" : "pause.fill",
            diameter: metrics.controlSize,
            iconColor: IC.primary
        ) {
            coordinator.send(.pauseResumeRequested(sessionID: vm.sessionID))
        }
        .help(isPaused ? "Resume recording" : "Pause recording")
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")

        inlineStopButton
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

- [ ] **Step 4: Update `LauncherItem` to track anchor along the long axis**

Replace the `anchorX` state and `setLauncherHint` call in `LauncherItem`:

```swift
private struct LauncherItem: View {
    @ObservedObject var coordinator: IslandCoordinator
    let icon: String
    let title: String
    let help: String
    let action: () -> Void

    @State private var anchor: CGFloat = 0

    var body: some View {
        IslandHoverButton(
            icon: icon,
            diameter: IslandContentSizer.launcherItemWidth,
            iconColor: IC.glyph,
            hoverIconColor: IC.glyphHover,
            action: action
        )
        .background(
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear
                    .onAppear {
                        anchor = coordinator.placement.isVertical ? frame.midY : frame.midX
                    }
                    .onChange(of: frame) { _, newFrame in
                        anchor = coordinator.placement.isVertical ? newFrame.midY : newFrame.midX
                    }
            }
        )
        .onHover { hovering in
            if hovering {
                coordinator.setLauncherHint(title, anchor: anchor)
            } else {
                coordinator.clearLauncherHint(ifTitleIs: title)
            }
        }
        .accessibilityLabel(help)
    }
}
```

- [ ] **Step 5: Build**
```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Step 6: Commit**
```bash
git add Whisperer/Island/IslandLayout.swift
git commit -m "feat(island): vertical row variants and axis-aware hint anchor in IslandLayout"
```

---

## Task 10: Settings UI — `islandSection` in workspace settings

**Files:**
- Modify: `Whisperer/History/HistoryWindowView.swift`

**Interfaces:**
- Consumes: `IslandPlacement` (Task 1), `NSNotification.Name.islandPlacementChanged` (Task 1)

- [ ] **Step 1: Add `@State private var islandPlacement` to `HistorySettingsView`**

Find the `private struct HistorySettingsView: View` block (around line 1132). Add after the existing `@AppStorage` declarations:

```swift
@State private var islandPlacement: IslandPlacement = IslandPlacement.current
```

- [ ] **Step 2: Insert `islandSection` into the settings body**

In the `VStack(spacing: 28)` body at around line 1159, insert `islandSection` **before** `overlaySection`:

```swift
islandSection
overlaySection
```

- [ ] **Step 3: Implement `islandSection`**

Add after `displaySection` and before `overlaySection` in `HistorySettingsView`:

```swift
private var islandSection: some View {
    SettingsCard(colorScheme: colorScheme) {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionHeader(
                icon: "rectangle.bottomthird.inset.filled",
                title: "Island",
                colorScheme: colorScheme,
                color: .blue
            )

            SettingsRow(colorScheme: colorScheme) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(0.18), Color.blue.opacity(0.10)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Island Position")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                        Text("Where the recording bar appears on screen")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(IslandPlacement.allCases) { placement in
                            islandPlacementButton(placement)
                        }
                    }
                }
            }
        }
    }
}

private func islandPlacementButton(_ placement: IslandPlacement) -> some View {
    let selected = islandPlacement == placement
    return Button {
        islandPlacement = placement
        IslandPlacement.save(placement)
        NotificationCenter.default.post(name: .islandPlacementChanged, object: nil)
    } label: {
        VStack(spacing: 4) {
            // Tiny screen diagram with a bar on the chosen edge
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected
                        ? Color.blue.opacity(0.8)
                        : WhispererColors.secondaryText(colorScheme).opacity(0.3),
                        lineWidth: selected ? 1.5 : 1)
                    .frame(width: 36, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selected
                                ? Color.blue.opacity(0.08)
                                : Color.clear)
                    )
                // The mini bar on the appropriate edge
                islandDiagramBar(for: placement)
            }
            Text(placement.displayName)
                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                .foregroundColor(selected
                    ? .blue
                    : WhispererColors.secondaryText(colorScheme))
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Island position: \(placement.displayName)")
    .accessibilityAddTraits(selected ? .isSelected : [])
}

@ViewBuilder
private func islandDiagramBar(for placement: IslandPlacement) -> some View {
    let barColor = Color.blue.opacity(0.7)
    switch placement {
    case .topCenter:
        RoundedRectangle(cornerRadius: 1.5)
            .fill(barColor)
            .frame(width: 18, height: 3)
            .offset(y: -8)
    case .bottomCenter:
        RoundedRectangle(cornerRadius: 1.5)
            .fill(barColor)
            .frame(width: 18, height: 3)
            .offset(y: 8)
    case .leftCenter:
        RoundedRectangle(cornerRadius: 1.5)
            .fill(barColor)
            .frame(width: 3, height: 14)
            .offset(x: -13)
    case .rightCenter:
        RoundedRectangle(cornerRadius: 1.5)
            .fill(barColor)
            .frame(width: 3, height: 14)
            .offset(x: 13)
    }
}
```

- [ ] **Step 4: Build**
```bash
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Step 5: Commit**
```bash
git add Whisperer/History/HistoryWindowView.swift
git commit -m "feat(island): islandSection placement picker in workspace settings"
```

---

## Task 11: Interaction tests + UX invariants + settings persistence

**Files:**
- Modify: `WhispererTests/IslandPlacementTests.swift` (add `IslandRevealInteractionTests`, `IslandUXInvariantTests`, `IslandPlacementPersistenceTests`)

- [ ] **Step 1: Add `IslandRevealInteractionTests`**

Append to `WhispererTests/IslandPlacementTests.swift`:

```swift
// MARK: - Interaction (pointer traces)

final class IslandRevealInteractionTests: XCTestCase {

    // Constant-velocity crossing — never dwells
    func testPassThrough_neverReveals() {
        var gate = IslandRevealGate()
        var last = IslandRevealPhase.hidden
        for i in 0..<50 {
            // Pointer crosses in 0.3s (under sliverDelay)
            let t = Double(i) * (0.3 / 50)
            let x = CGFloat(i) * 6  // 300 pt in 0.3 s — fast
            last = gate.step(point: NSPoint(x: x, y: 0), inside: i < 40, now: t)
        }
        XCTAssertEqual(last, .hidden, "fast crossing should never reveal")
    }

    // Decelerating approach then tremor → reveals and stays revealed through jitter
    func testApproachAndRest_revealsAndStaysThroughTremor() {
        var gate = IslandRevealGate()
        let restPoint = NSPoint(x: 100, y: 100)
        // Approach (large moves)
        for i in 0..<5 {
            _ = gate.step(point: NSPoint(x: CGFloat(i * 40), y: 100),
                          inside: false, now: Double(i) * 0.02)
        }
        // Arrive at rest
        gate.entered(point: restPoint, now: 0.1)
        // Tremor ±3 pt (well under stillnessRadius=12) for 0.8 s — past revealDelay
        var phase = IslandRevealPhase.hidden
        for i in 0..<80 {
            let t = 0.1 + Double(i) * (IslandUX.revealDelay / 78)
            let jitterX = restPoint.x + (i % 3 == 0 ? 3.0 : -3.0)
            phase = gate.step(point: NSPoint(x: jitterX, y: restPoint.y),
                              inside: true, now: t)
        }
        XCTAssertEqual(phase, .revealed, "resting with tremor should reveal")

        // Confirm still revealed after more tremor
        for i in 0..<10 {
            let t = 0.1 + IslandUX.revealDelay + Double(i) * 0.05
            let jitter = NSPoint(x: restPoint.x + (i % 2 == 0 ? 4 : -4), y: restPoint.y)
            phase = gate.step(point: jitter, inside: true, now: t)
        }
        XCTAssertEqual(phase, .revealed, "revealed state must not be knocked back by tremor")
    }

    // Reveal then exit → hidden after exit
    func testRestThenLeave_hiddenAfterExit() {
        var gate = IslandRevealGate()
        let pt = NSPoint(x: 50, y: 50)
        gate.entered(point: pt, now: 0)
        for i in 0..<80 {
            _ = gate.step(point: pt, inside: true,
                          now: Double(i) * (IslandUX.revealDelay / 78))
        }
        let phase = gate.step(point: pt, inside: false, now: IslandUX.revealDelay + 0.1)
        XCTAssertEqual(phase, .hidden)
    }
}
```

- [ ] **Step 2: Add `IslandUXInvariantTests`**

These tests run the same assertions across all 4 placements × 7 screen fixtures × selected states. They are table-driven so adding a new fixture/placement is one line.

```swift
// MARK: - UX Invariants

final class IslandUXInvariantTests: XCTestCase {

    // MARK: Screen fixtures
    private var screens: [ScreenDescription] {[
        // Standard 5K iMac with bottom Dock
        ScreenDescription(frame: NSRect(x:0,y:0,width:2560,height:1600),
                          visibleFrame: NSRect(x:0,y:23,width:2560,height:1480), backingScale:2),
        // HD no Dock
        ScreenDescription(frame: NSRect(x:0,y:0,width:1920,height:1080),
                          visibleFrame: NSRect(x:0,y:0,width:1920,height:1080), backingScale:2),
        // Negative origin
        ScreenDescription(frame: NSRect(x:-1920,y:0,width:1920,height:1200),
                          visibleFrame: NSRect(x:-1920,y:23,width:1920,height:1100), backingScale:1),
        // Narrow
        ScreenDescription(frame: NSRect(x:0,y:0,width:500,height:600),
                          visibleFrame: NSRect(x:0,y:23,width:500,height:537), backingScale:1),
        // Left Dock
        ScreenDescription(frame: NSRect(x:0,y:0,width:2560,height:1600),
                          visibleFrame: NSRect(x:80,y:25,width:2480,height:1543), backingScale:2),
        // Right Dock
        ScreenDescription(frame: NSRect(x:0,y:0,width:2560,height:1600),
                          visibleFrame: NSRect(x:0,y:25,width:2480,height:1543), backingScale:2),
        // Short external (900pt tall)
        ScreenDescription(frame: NSRect(x:0,y:0,width:1280,height:900),
                          visibleFrame: NSRect(x:0,y:23,width:1280,height:840), backingScale:1),
    ]}

    // MARK: Invariant 1: Pill never occludes system chrome

    func testPillNeverOccludesSystemChrome() {
        for placement in IslandPlacement.allCases {
            var geo = IslandGeometryProvider(); geo.placement = placement
            for s in screens {
                let f = geo.compactFrame(for: s)
                // Must not go above visibleFrame.maxY (menu bar region)
                XCTAssertLessThanOrEqual(f.maxY, s.visibleFrame.maxY + 0.5,
                    "\(placement) on \(s.frame): pill above menu bar")
                // Must not go below frame.minY (raw screen edge)
                XCTAssertGreaterThanOrEqual(f.minY, s.frame.minY - 0.5,
                    "\(placement) on \(s.frame): pill below screen")
                // Must not go left of visibleFrame.minX
                XCTAssertGreaterThanOrEqual(f.minX, s.frame.minX - 0.5,
                    "\(placement) on \(s.frame): pill past left edge")
                // Must not go right of frame.maxX
                XCTAssertLessThanOrEqual(f.maxX, s.frame.maxX + 0.5,
                    "\(placement) on \(s.frame): pill past right edge")
            }
        }
    }

    // MARK: Invariant 2: Envelope fully on screen

    func testEnvelopeFullyOnScreen() {
        for placement in IslandPlacement.allCases {
            var geo = IslandGeometryProvider(); geo.placement = placement
            for s in screens {
                let env = geo.panelEnvelope(for: s)
                XCTAssertGreaterThanOrEqual(env.minX, s.frame.minX - 0.5,
                    "\(placement): envelope minX outside screen")
                XCTAssertLessThanOrEqual(env.maxX, s.frame.maxX + 0.5,
                    "\(placement): envelope maxX outside screen")
                XCTAssertGreaterThanOrEqual(env.minY, s.frame.minY - 0.5,
                    "\(placement): envelope minY outside screen")
                XCTAssertLessThanOrEqual(env.maxY, s.frame.maxY + 0.5,
                    "\(placement): envelope maxY outside screen")
            }
        }
    }

    // MARK: Invariant 3: Sliver is strictly thinner than revealed bar

    func testSliverThickerThanNothing_ThinnerThanFull() {
        for placement in IslandPlacement.allCases {
            let s = screens[0]
            let sliver = IslandContentSizer.targetSize(
                capture: .idle, presentation: .compact, screen: s,
                isHovering: false, gestureProgress: 0,
                placement: placement, revealPhase: .sliver)
            let full = IslandContentSizer.targetSize(
                capture: .idle, presentation: .compact, screen: s,
                isHovering: false, gestureProgress: 0,
                placement: placement, revealPhase: .revealed)

            let sliverThick = placement.isVertical ? sliver.width : sliver.height
            let fullThick   = placement.isVertical ? full.width   : full.height
            XCTAssertEqual(sliverThick, IslandUX.sliverThickness, accuracy: 0.5,
                           "\(placement): sliver thickness wrong")
            XCTAssertGreaterThan(fullThick, sliverThick,
                           "\(placement): full bar must be thicker than sliver")
        }
    }

    // MARK: Invariant 4: Placement parity — sizes match across placements

    func testPlacementParity_sameLongAxisSize() {
        // All four placements must produce the same long-axis size for idle compact
        let s = screens[0]
        var longSizes: [IslandPlacement: CGFloat] = [:]
        for placement in IslandPlacement.allCases {
            let sz = IslandContentSizer.targetSize(
                capture: .idle, presentation: .compact, screen: s,
                isHovering: false, gestureProgress: 0,
                placement: placement, revealPhase: .revealed)
            longSizes[placement] = placement.isVertical ? sz.height : sz.width
        }
        let reference = longSizes[.bottomCenter]!
        for (p, size) in longSizes {
            XCTAssertEqual(size, reference, accuracy: 0.5,
                "\(p): long-axis size \(size) differs from bottomCenter \(reference)")
        }
    }

    // MARK: Invariant 5: Motion budget (constants only — no UI spawn)

    func testMotionBudget_revealAnimationsWithinLimit() {
        XCTAssertLessThanOrEqual(IslandUX.springResponseOpen,   IslandUX.maxRevealAnimDuration)
        XCTAssertLessThanOrEqual(IslandUX.springResponseClose,  IslandUX.maxRevealAnimDuration)
        XCTAssertLessThanOrEqual(IslandUX.hintFadeDuration,     IslandUX.maxRevealAnimDuration)
        XCTAssertEqual(IslandUX.reduceMotionDuration, 0.12, accuracy: 0.001)
    }

    // MARK: Invariant 6: Tap target size ≥ minimum

    func testTapTargetMeetsMinimum() {
        XCTAssertGreaterThanOrEqual(IslandContentSizer.launcherItemWidth,
                                    IslandUX.minTapTarget)
    }
}
```

- [ ] **Step 3: Add `IslandPlacementPersistenceTests`**

```swift
// MARK: - Settings persistence

final class IslandPlacementPersistenceTests: XCTestCase {

    private var savedValue: String?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.string(forKey: IslandPlacement.defaultsKey)
    }

    override func tearDown() {
        if let saved = savedValue {
            UserDefaults.standard.set(saved, forKey: IslandPlacement.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: IslandPlacement.defaultsKey)
        }
        super.tearDown()
    }

    func testSaveAndLoad() {
        for placement in IslandPlacement.allCases {
            IslandPlacement.save(placement)
            let loaded = IslandPlacement.current
            XCTAssertEqual(loaded, placement,
                "Saved \(placement.rawValue), got \(loaded.rawValue)")
        }
    }

    func testMissingKey_returnsDefault() {
        UserDefaults.standard.removeObject(forKey: IslandPlacement.defaultsKey)
        XCTAssertEqual(IslandPlacement.current, IslandPlacement.defaultValue)
    }

    func testInvalidRawValue_returnsDefault() {
        UserDefaults.standard.set("invalid_value", forKey: IslandPlacement.defaultsKey)
        XCTAssertEqual(IslandPlacement.current, IslandPlacement.defaultValue)
    }
}
```

- [ ] **Step 4: Run all placement tests**
```bash
xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:WhispererTests/IslandPlacementTests \
  -only-testing:WhispererTests/IslandGeometryTests \
  -only-testing:WhispererTests/IslandContentSizerTests \
  -only-testing:WhispererTests/IslandReducerTests 2>&1 | grep -E "error:|FAILED|passed|succeeded"
```
Expected: all pass.

- [ ] **Step 5: Commit**
```bash
git add WhispererTests/IslandPlacementTests.swift
git commit -m "test(island): interaction tests, UX invariants, placement persistence tests"
```

---

## Task 12: Design-system check + manual smoke test

**Files:** none (review only)

- [ ] **Step 1: Run design-check skill**

Invoke `/design-check` against the changed view files to verify DESIGN.md compliance for the new vertical layout, hint chip positioning, and settings card.

- [ ] **Step 2: Manual smoke test — run the Debug build**

Follow the manual checklist from the spec:
1. Open workspace settings → Island section → select each of the 4 placements. Bar teleports immediately (no slide animation).
2. At each placement: move pointer fast across the hot zone → nothing appears. Drag a window through it → nothing appears. Rest on it → faint sliver at ~250 ms, full bar at ~700 ms.
3. Start a meeting recording at each placement; verify the waveform, timer, pause/stop, expanded row all render correctly and are not clipped.
4. Toggle the Dock to left, then right, then auto-hide; verify the bar stays clear of the Dock at each placement.
5. Move the pointer to a second display; the bar migrates only when idle and not hovering.
6. Change placement while recording — bar moves, waveform and elapsed clock continue uninterrupted.
7. Change placement while hovering — bar resets to hidden, requires a fresh dwell.
8. Enable Reduce Motion; verify the sliver cross-fades (no grow) and bar appears in 0.12 s.

- [ ] **Step 3: Final commit**
```bash
git add -p   # stage only intentional leftover changes
git commit -m "feat(island): configurable placement + intent-gated progressive reveal

- IslandPlacement enum (topCenter/bottomCenter/leftCenter/rightCenter)
- IslandRevealGate: 250ms sliver + 700ms reveal, dwell+stillness gated
- Per-edge geometry in IslandGeometryProvider
- Vertical pill layout in IslandLayout (waveform rotated, glyphs stacked)
- Placement picker in workspace settings (visual edge diagrams)
- IslandUX constants table; UX invariant + interaction test suites"
```

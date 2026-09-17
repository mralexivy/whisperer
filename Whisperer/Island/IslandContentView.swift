//
//  IslandContentView.swift
//  Whisperer
//
//  Island UI — bottom-anchored, three-tier morph.
//
//  The Island is always on screen once onboarding is done. While idle it rests as a small
//  glass capsule — the "handle" — with a single hairline inside it. Hovering grows the
//  handle and fills that line across the reveal dwell window, so the wait before the
//  launcher opens is visible instead of a mystery; completing the dwell (or clicking the
//  handle outright) opens the four-action launcher row
//  (Dictate · Meeting · Paste Bin · Workspace).
//
//  Tiers (bottom-up growth):
//   .peek     → 104 × 24 pt idle launcher, or 208 × 30 pt recording nub.
//   .compact  → 147 × 36 pt launcher bar, or 420 × 60 pt recording row.
//   .expanded → 460 × 150 pt recording + controls row (recording only).
//
//  Key Atoll techniques preserved:
//   1. Animation split: outer root frame carries .animation(nil) so the panel VStack
//      never animates; the inner island body carries the springs so only its own
//      frame springs to the target size.
//   2. Distinct open/close springs + hover lift spring.
//   3. Content-driven size via IslandContentSizer.
//   4. Hover-to-open with dwell (120 ms peek→compact), debounced exit (100 ms).
//   5. Scroll gesture: UP → expand, DOWN → collapse (bottom-anchored surface).
//   6. Haptic feedback (.alignment) rate-limited to 300 ms.
//
//  Root layout (bottom-aligned):
//    [Spacer (flexible)]
//    [islandBody]
//    [Color.clear height: bottomSlack]
//
//  islandBody grows upward from the fixed bottom, which is exactly what a
//  bottom-anchored floating widget should do.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Morph key (drives animation value comparison)

private struct MorphKey: Hashable {
    let capture: String
    let presentation: IslandPresentation
}

// MARK: - Root view

struct IslandContentView: View {

    @ObservedObject var coordinator: IslandCoordinator
    var hitBox: IslandHitBox

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live centre of each launcher glyph, republished on every layout pass.
    @State private var launcherAnchors: [String: CGFloat] = [:]

    private var vm: IslandViewModel        { coordinator.currentViewModel }
    private var screen: ScreenDescription  { coordinator.currentScreen }
    private var level: IslandLevelBridge   { coordinator.levelBridge }
    private var clock: IslandElapsedTimer  { coordinator.elapsedTimer }
    private var isExpanded: Bool           { vm.presentation == .expanded }
    private var isPeek: Bool               { vm.presentation == .peek }
    private var isHovering: Bool           { coordinator.isHovering }
    private var placement: IslandPlacement { coordinator.placement }
    private var revealPhase: IslandRevealPhase {
        vm.capture == .idle ? coordinator.idleRevealPhase : .revealed
    }

    // MARK: - Animation constants

    private var openSpring: Animation {
        reduceMotion ? .linear(duration: 0.12)
            : .spring(response: 0.42, dampingFraction: 1.0, blendDuration: 0)
    }
    private var closeSpring: Animation {
        reduceMotion ? .linear(duration: 0.12)
            : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    }
    private var hoverAnim: Animation {
        reduceMotion ? .linear(duration: 0.12) : .bouncy.speed(1.2)
    }
    private var activeSpring: Animation { isExpanded ? openSpring : closeSpring }

    private var morphKey: MorphKey {
        MorphKey(capture: captureTag, presentation: vm.presentation)
    }
    private var captureTag: String {
        switch vm.capture {
        case .idle:              "idle"
        case .starting:          "starting"
        case .permissionRequired:"perm"
        case .recording:         "rec"
        case .paused:            "paused"
        case .finalizing:        "finalizing"
        case .failed:            "failed"
        }
    }

    // MARK: - Geometry

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

    private var radii: (top: CGFloat, bottom: CGFloat) {
        IslandContentSizer.cornerRadii(
            capture: vm.capture, presentation: vm.presentation, screen: screen,
            revealPhase: revealPhase
        )
    }

    private var pillShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius:     radii.top,
            bottomLeadingRadius:  radii.bottom,
            bottomTrailingRadius: radii.bottom,
            topTrailingRadius:    radii.top,
            style: .continuous
        )
    }

    // MARK: - Surface

    /// Idle launcher bar — always compact now; no nub transition.
    private var isIdleBar: Bool { vm.capture == .idle }
    /// True while the idle Island is resting as the handle rather than the launcher row.
    /// The handle is always on screen; only its fill and length change before reveal.
    private var isIdleHandle: Bool { isIdleBar && revealPhase != .revealed }

    @ViewBuilder
    private var surface: some View {
        if isIdleHandle {
            handleFill
        } else if isIdleBar {
            idleGlass
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                Rectangle().fill(IC.surface.opacity(scrimOpacity))
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }

    /// Resting handle — one solid, unbroken capsule, the way the iPhone Dynamic Island sits
    /// when nothing is happening. No blur, no tint stack, no inner content: at 15 pt tall,
    /// translucency only lets the desktop through and turns a crisp shape into a smudge.
    /// Hover lifts it from near-black to a soft graphite so the reaction is purely tonal.
    private var handleFill: some View {
        Rectangle().fill(isHovering ? IC.elevated : Self.islandSurface)
    }

    /// Open launcher — the same solid black as the handle, just a wider capsule.
    ///
    /// This is the whole point of the Dynamic Island morph: one continuous piece of black
    /// that changes shape. The bar used to be `.ultraThinMaterial` with a sheen gradient,
    /// which meant opening the handle swapped materials mid-animation — a solid capsule
    /// visibly turning into a pane of frosted glass. Now only the silhouette changes.
    private var idleGlass: some View {
        Rectangle().fill(Self.islandSurface)
    }

    /// The single colour the Island is made of, at rest and open alike.
    ///
    /// Was a neutral `Color(white: 0.06)`. That put a grey-black object next to a navy HUD, and
    /// the two read as parts of different apps. This is `IC.raised` (#14142B) — the same fill the
    /// HUD capsule uses, so the two surfaces are literally the same colour.
    static let islandSurface = IC.raised

    private var scrimOpacity: Double {
        isPeek ? 0.62 : 0.78
    }

    /// Rim for the recording tiers only — the idle Island is unstroked.
    private var hairlineColor: Color { Color.white.opacity(0.16) }

    private var shadowOpacity: Double {
        // Wide and faint rather than tight and dark — a contact shadow under a thin sheet.
        // A dense shadow is most of what made the pill look like a solid block.
        // The resting handle carries almost none: it must not cast a visible smudge on the
        // desktop while the user is doing something else.
        // The solid handle gets a tight contact shadow so it reads as sitting ON the desktop
        // rather than floating over it — a wide soft shadow around a small dark shape is
        // indistinguishable from the shape itself being blurry.
        if isIdleHandle { return isHovering ? 0.30 : 0.18 }
        if isIdleBar    { return isHovering ? 0.16 : 0.06 }
        return (isHovering || isExpanded) ? 0.55 : 0.34
    }

    /// Overall opacity of the idle surface.
    ///
    /// The handle is fully opaque. It used to rest at 0.55, which let the desktop bleed
    /// through and made the shape read as a grey smear; a solid capsule that is *small* and
    /// *dark* is quieter than a translucent one, and stays crisp on any wallpaper.
    private var idleSurfaceOpacity: Double { 1 }

    /// Padding between the island body and the anchored edge of the panel envelope.
    private var anchorSlack: CGFloat {
        IslandContentSizer.anchorSlack(screen: screen, placement: placement)
    }
    @available(*, deprecated, renamed: "anchorSlack")
    private var bottomSlack: CGFloat { anchorSlack }
    private var rowMetrics: IslandRowMetrics {
        IslandContentSizer.rowMetrics(screen: screen,
                                      isHovering: isHovering,
                                      gestureProgress: coordinator.gestureProgress)
    }

    // MARK: - Body

    var body: some View {
        rootBodyView
            .onAppear {
                hitBox.onScrollWheel = { [weak coordinator] delta, phase in
                    coordinator?.handleScrollWheel(delta: delta, phase: phase)
                }
                hitBox.onHoverChanged = { [weak coordinator] hovering in
                    coordinator?.handleHover(hovering)
                }
                coordinator.teardownHook = { [weak coordinator] in
                    coordinator?.cancelHoverTask()
                }
                updateHitBox()
            }
    }

    // MARK: - Root (outer, never animates)

    private var rootBodyView: some View {
        placementContainer
            // Atoll's key trick: barrier stops any morphKey spring from propagating to the
            // outer frame, so the panel never jitters on state change.
            .animation(nil, value: morphKey)
            // A Space switch changes only `anchorSlack` (Dock present → 80, absent → 5). That must
            // land in the very first frame after the switch, not slide there: an animated slack is
            // exactly the "appears in the old position, then moves" flicker.
            .animation(nil, value: anchorSlack)
            .sensoryFeedback(.alignment, trigger: coordinator.hapticToken)
            .coordinateSpace(name: IslandPanelSpace.name)
            .onPreferenceChange(LauncherAnchorKey.self) { launcherAnchors = $0 }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

        case .topCenter:
            VStack(spacing: 0) {
                Color.clear.frame(height: anchorSlack)
                islandBody
                hintLabel
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .leftCenter:
            HStack(spacing: 0) {
                Color.clear.frame(width: anchorSlack)
                islandBody
                hintLabel
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .rightCenter:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                hintLabel
                islandBody
                Color.clear.frame(width: anchorSlack)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Hint label (floats above the pill, outside its clip)

    /// Names the launcher glyph under the pointer.
    ///
    /// Lives in the root VStack rather than inside `islandBody` because the body is clipped
    /// to its capsule — a label drawn in there would be sliced off. The band is a constant
    /// height whether or not a hint is showing, so revealing one eats into the Spacer above
    /// instead of shoving the bar down.
    private var hintLabel: some View {
        ZStack(alignment: hintBandAlignment) {
            // A zero-size clear anchor so the ZStack keeps its band size even when empty;
            // without it the band collapses and the bar shifts as hints come and go.
            Color.clear.frame(width: 0, height: 0)

            // The anchor lookup is part of the condition on purpose: until the hovered glyph
            // has reported a centre there is no correct place to draw the chip, and drawing
            // it at a guessed one is the bug. One layout pass later it appears, correctly.
            if let hint = coordinator.launcherHint, isIdleBar, isHovering,
               let anchor = launcherAnchors[hint.title] {
                IslandLauncherHintLabel(title: hint.title)
                    .padding(placement.isVertical ? .horizontal : .vertical, 6)
                    .offset(hintOffset(anchor: anchor))
                    .transition(
                        .opacity.combined(with: .offset(y: 4)).combined(with: .scale(scale: 0.94))
                    )
                    .id(hint.title)
            }
        }
        // Vertical placements need a real band WIDTH — a chip reading "Workspace" is far
        // wider than the 31 pt reserved for the horizontal band's height.
        .frame(maxWidth:  placement.isVertical ? Self.hintBandWidth : .infinity,
               maxHeight: placement.isVertical ? .infinity : Self.hintBandHeight)
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.18), value: coordinator.launcherHint)
    }

    /// Which side of the band the chip hugs, so it always sits beside the pill rather than
    /// drifting off toward the middle of the screen.
    private var hintBandAlignment: Alignment {
        switch placement {
        case .leftCenter:  return .leading
        case .rightCenter: return .trailing
        default:           return .center
        }
    }

    /// `anchor` is the glyph's centre in the panel's named coordinate space, and the chip is
    /// centred in a band that spans the same panel — so the offset is just the distance from
    /// the panel's midpoint. Both sides now measure against one origin; the old version mixed
    /// a `.global` glyph centre with a recomputed envelope width.
    private func hintOffset(anchor: CGFloat) -> CGSize {
        if placement.isVertical {
            return CGSize(width: 0, height: anchor - envelopeHeight / 2)
        }
        return CGSize(width: anchor - envelopeWidth / 2, height: 0)
    }

    /// Chip height (23) + the gap that keeps it clear of the pill.
    private static let hintBandHeight: CGFloat = IslandUX.hintBandHeight
    /// Band width reserved beside a vertical pill — wide enough for the longest glyph name.
    private static let hintBandWidth: CGFloat = IslandUX.hintBandWidth

    private var envelopeWidth: CGFloat {
        var g = IslandGeometryProvider(); g.placement = placement
        return g.panelEnvelope(for: screen).width
    }

    private var envelopeHeight: CGFloat {
        var g = IslandGeometryProvider(); g.placement = placement
        return g.panelEnvelope(for: screen).height
    }

    /// UnitPoint from which the pill scales toward the anchored edge when hidden.
    private var anchorForScale: UnitPoint {
        switch placement {
        case .bottomCenter: return .bottom
        case .topCenter:    return .top
        case .leftCenter:   return .leading
        case .rightCenter:  return .trailing
        }
    }

    /// The resting handle sits exactly on its anchor.
    ///
    /// It used to be nudged 3 pt further toward the edge so the reveal read as the bar rising
    /// out of the screen. Now that the anchor hugs the real screen edge when no Dock is up
    /// (`IslandGeometryProvider.C.chromeThreshold`), that nudge pushes the capsule's rounded
    /// bottom off-screen and flattens it into a slab.
    private var offsetForReveal: CGSize { .zero }

    // MARK: - Island body (inner, springs)

    private var islandBody: some View {
        IslandLayout(
            coordinator: coordinator,
            levelBridge: level,
            clock: clock,
            metrics: rowMetrics,
            isIdleHandle: isIdleHandle
        )
        .frame(width: targetSize.width, height: targetSize.height, alignment: .center)
        .background(surface)
        .overlay {
            if isIdleBar {
                // No rim anywhere on the idle Island. A stroke is how you suggest a pane of
                // glass has an edge; solid black needs no edge, and drawing one only softens
                // the silhouette that carries the whole look.
                EmptyView()
            } else {
                pillShape.strokeBorder(hairlineColor, lineWidth: 0.75)
            }
        }
        .clipShape(pillShape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(shadowOpacity),
            radius: isIdleHandle ? 5 : (isIdleBar ? 14 : 18),
            x: 0,
            y: isIdleHandle ? 1 : (isIdleBar ? 2 : 8)
        )
        // Springs live HERE — never on the root.
        .animation(activeSpring, value: morphKey)
        .animation(hoverAnim, value: isHovering)
        .animation(.easeOut(duration: 0.22), value: revealPhase)
        .animation(.smooth, value: coordinator.gestureProgress)
        // The idle Island is never fully hidden any more — at rest it is the handle, held
        // back in opacity so it stays quiet against whatever is behind it. Hover brings it
        // to full strength. Any non-idle capture state is always fully opaque.
        .opacity(idleSurfaceOpacity)
        .offset(offsetForReveal)
        // Centre the pill across the panel's CROSS axis — width for a horizontal pill in a
        // VStack, height for a vertical pill in an HStack. Growing on the wrong axis made the
        // body greedy inside the left/right HStack and squashed the hint band to nothing,
        // which is why hovering a glyph named nothing in those placements.
        .frame(maxWidth:  placement.isVertical ? nil : .infinity,
               maxHeight: placement.isVertical ? .infinity : nil,
               alignment: .center)
        .contentShape(pillShape)
        .onTapGesture { handleTap() }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { updateHitBox(proxy) }
                .onChange(of: targetSize)  { updateHitBox(proxy) }
                .onChange(of: anchorSlack) { updateHitBox(proxy) }
                .onChange(of: placement)   { updateHitBox(proxy) }
        })
    }

    // MARK: - Tap

    private func handleTap() {
        switch vm.capture {
        case .idle:
            // Clicking the resting handle opens the launcher immediately rather than making
            // the user hold still for the dwell. Taps on the open row are ignored — the four
            // action buttons own it, and a stray background click must not launch anything.
            if isIdleHandle {
                coordinator.revealLauncherNow()
            } else if vm.presentation == .peek {
                coordinator.send(.expand)
            }
        case .recording, .paused:
            switch vm.presentation {
            case .peek:     coordinator.send(.expand)   // peek → compact
            case .compact:  coordinator.send(.expand)   // compact → expanded
            case .expanded: coordinator.send(.collapse) // expanded → compact
            default:        break
            }
        default:
            break
        }
    }

    // MARK: - Hit box

    /// Publishes two rects in the hosting view's TOP-LEFT origin space:
    ///  - `rect`      the exact pill — click-through boundary
    ///  - `hoverRect` generously padded so the nub (10 pt tall) is still reachable
    ///
    /// `IslandContainerView` flips these into AppKit's bottom-left space before testing.
    private func updateHitBox(_ proxy: GeometryProxy? = nil) {
        let size = targetSize
        guard size.width > 0, size.height > 0 else {
            hitBox.rect = .zero
            hitBox.hoverRect = .zero
            coordinator.hoverRectOnScreen = .zero
            return
        }

        var g = IslandGeometryProvider(); g.placement = placement
        let envelope = g.panelEnvelope(for: screen)

        let originY: CGFloat  // top-left Y of the pill in the panel's SwiftUI coordinate space
        let centerX: CGFloat

        if let proxy {
            let frame = proxy.frame(in: .global)
            originY = frame.minY
            centerX = frame.midX
        } else {
            // Fallback before first layout: estimate pill position from envelope + anchorSlack.
            let slack = anchorSlack
            switch placement {
            case .bottomCenter:
                originY = envelope.height - slack - size.height
                centerX = envelope.width / 2
            case .topCenter:
                originY = slack
                centerX = envelope.width / 2
            case .leftCenter:
                originY = (envelope.height - size.height) / 2
                centerX = slack + size.width / 2
            case .rightCenter:
                originY = (envelope.height - size.height) / 2
                centerX = envelope.width - slack - size.width / 2
            }
        }

        let pillX = centerX - size.width / 2

        hitBox.rect = NSRect(x: pillX, y: originY, width: size.width, height: size.height)

        // Hover rect — generous for invisible/tiny targets, narrow for visible rows.
        let generousCatch = isPeek || isIdleBar
        let hPad:    CGFloat = generousCatch ? IslandUX.hoverHPadGenerous : IslandUX.hoverPadNarrow
        let vPadUp:  CGFloat = generousCatch ? IslandUX.hoverVPadUpGenerous : IslandUX.hoverVPadNarrowUp
        let vPadDown:CGFloat = generousCatch ? IslandUX.hoverVPadDownGenerous : IslandUX.hoverVPadNarrowDown

        // For vertical placements, extend toward the anchor edge (left or right).
        let (leftPad, rightPad, topPad, botPad): (CGFloat, CGFloat, CGFloat, CGFloat)
        switch placement {
        case .bottomCenter:
            leftPad = hPad; rightPad = hPad; topPad = vPadUp; botPad = vPadDown
        case .topCenter:
            leftPad = hPad; rightPad = hPad; topPad = vPadDown; botPad = vPadUp
        case .leftCenter:
            leftPad = vPadDown; rightPad = vPadUp; topPad = hPad; botPad = hPad
        case .rightCenter:
            leftPad = vPadUp; rightPad = vPadDown; topPad = hPad; botPad = hPad
        }

        hitBox.hoverRect = NSRect(
            x:      pillX   - leftPad,
            y:      originY - topPad,
            width:  size.width  + leftPad + rightPad,
            height: size.height + topPad  + botPad
        )

        // Screen-space span for the anchored-edge hover-retention test.
        let appKitY = envelope.origin.y + (envelope.height - (originY + size.height))
        coordinator.hoverRectOnScreen = NSRect(
            x:      envelope.origin.x + pillX   - leftPad,
            y:      appKitY - botPad,
            width:  size.width  + leftPad + rightPad,
            height: size.height + topPad  + botPad
        )
    }
}

// MARK: - Elapsed timer

@MainActor
final class IslandElapsedTimer: ObservableObject {
    @Published var displayText: String = "0:00"
    private var elapsedSeconds: Double = 0
    private var timer: Timer?

    func sync(to seconds: Double) {
        elapsedSeconds = seconds
        displayText = format(seconds)
        if timer == nil { startTimer() }
    }

    func pause() { timer?.invalidate(); timer = nil }

    func resume() {
        guard timer == nil else { return }
        startTimer()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        elapsedSeconds = 0; displayText = "0:00"
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.elapsedSeconds += 1
                self.displayText = self.format(self.elapsedSeconds)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func format(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        let m = t / 60, sec = t % 60
        return m >= 60
            ? String(format: "%d:%02d:%02d", m / 60, m % 60, sec)
            : String(format: "%d:%02d", m, sec)
    }
}

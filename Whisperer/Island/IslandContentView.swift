//
//  IslandContentView.swift
//  Whisperer
//
//  Island UI — bottom-anchored, three-tier morph.
//
//  The Island is always on screen once onboarding is done. While idle it rests as a
//  near-transparent launcher nub; hovering opens a four-action launcher row
//  (Dictate · Meeting · File · Workspace).
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

    private var vm: IslandViewModel        { coordinator.currentViewModel }
    private var screen: ScreenDescription  { coordinator.currentScreen }
    private var level: IslandLevelBridge   { coordinator.levelBridge }
    private var clock: IslandElapsedTimer  { coordinator.elapsedTimer }
    private var isExpanded: Bool           { vm.presentation == .expanded }
    private var isPeek: Bool               { vm.presentation == .peek }
    private var isHovering: Bool           { coordinator.isHovering }

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
            gestureProgress: coordinator.gestureProgress
        )
    }

    private var radii: (top: CGFloat, bottom: CGFloat) {
        IslandContentSizer.cornerRadii(
            capture: vm.capture, presentation: vm.presentation, screen: screen
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
    /// Resting idle launcher: on screen but not yet revealed.
    private var isIdleHidden: Bool { isIdleBar && !isHovering }

    @ViewBuilder
    private var surface: some View {
        if isIdleBar {
            idleGlass
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                Rectangle().fill(Color.black.opacity(scrimOpacity))
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }

    /// Flat glass launcher pill — a thin sheet, not a lozenge.
    ///
    /// A strong top sheen paired with a bottom bounce shades the pill like a cylinder, and
    /// a cylinder reads as bulky at this size. Flat glass wants the opposite: mostly just
    /// the backdrop blur, the faintest tint to hold glyph contrast, and one short highlight
    /// hugging the top edge to say "this surface is lit" without implying any thickness.
    private var idleGlass: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)

            Rectangle().fill(Color.black.opacity(0.07))

            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.13), location: 0.00),
                    .init(color: Color.white.opacity(0.03), location: 0.18),
                    .init(color: Color.clear,               location: 0.42),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var scrimOpacity: Double {
        isPeek ? 0.62 : 0.78
    }

    /// Rim light — a hairline catch along the top edge only, fading out by the middle.
    /// Relighting the bottom edge is what wraps the outline around a solid-looking body;
    /// leaving it dark keeps the pill reading as a flat sheet seen face-on.
    private var idleRim: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.24), location: 0.00),
                .init(color: Color.white.opacity(0.09), location: 0.35),
                .init(color: Color.white.opacity(0.05), location: 1.00),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var hairlineColor: Color {
        if isIdleBar { return Color.white.opacity(isHovering ? 0.16 : 0.06) }
        return Color.white.opacity(0.16)
    }

    private var shadowOpacity: Double {
        // Wide and faint rather than tight and dark — a contact shadow under a thin sheet.
        // A dense shadow is most of what made the pill look like a solid block.
        if isIdleBar { return isHovering ? 0.16 : 0.06 }
        return (isHovering || isExpanded) ? 0.55 : 0.34
    }

    /// Bottom padding that pins the island flush against the bottom of the panel envelope.
    private var bottomSlack: CGFloat { IslandContentSizer.bottomSlack(screen: screen) }
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            hintLabel
            islandBody
            Color.clear.frame(height: bottomSlack)
        }
        // Atoll's key trick: barrier stops any morphKey spring from propagating to the
        // VStack frame, so the panel never jitters on state change.
        .animation(nil, value: morphKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .sensoryFeedback(.alignment, trigger: coordinator.hapticToken)
    }

    // MARK: - Hint label (floats above the pill, outside its clip)

    /// Names the launcher glyph under the pointer.
    ///
    /// Lives in the root VStack rather than inside `islandBody` because the body is clipped
    /// to its capsule — a label drawn in there would be sliced off. The band is a constant
    /// height whether or not a hint is showing, so revealing one eats into the Spacer above
    /// instead of shoving the bar down.
    private var hintLabel: some View {
        ZStack {
            if let hint = coordinator.launcherHint, isIdleBar, isHovering {
                IslandLauncherHintLabel(title: hint.title)
                    .offset(x: hint.anchor - envelopeWidth / 2)
                    .transition(
                        .opacity.combined(with: .offset(y: 4)).combined(with: .scale(scale: 0.94))
                    )
                    .id(hint.title)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.hintBandHeight)
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.18), value: coordinator.launcherHint)
    }

    /// Chip height (23) + the gap that keeps it clear of the pill.
    private static let hintBandHeight: CGFloat = 31

    private var envelopeWidth: CGFloat {
        IslandGeometryProvider().panelEnvelope(for: screen).width
    }

    // MARK: - Island body (inner, springs)

    private var islandBody: some View {
        IslandLayout(
            coordinator: coordinator,
            levelBridge: level,
            clock: clock,
            metrics: rowMetrics
        )
        .frame(width: targetSize.width, height: targetSize.height, alignment: .center)
        .background(surface)
        .overlay {
            if isIdleBar {
                // Sub-pixel on Retina — a hairline edge, not a drawn border.
                pillShape.strokeBorder(idleRim, lineWidth: 0.5)
            } else {
                pillShape.strokeBorder(hairlineColor, lineWidth: 0.75)
            }
        }
        .clipShape(pillShape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(shadowOpacity),
            radius: isIdleBar ? 14 : 18,
            x: 0,
            y: isIdleBar ? 2 : 8
        )
        // Springs live HERE — never on the root.
        .animation(activeSpring, value: morphKey)
        .animation(hoverAnim, value: isHovering)
        .animation(.smooth, value: coordinator.gestureProgress)
        // The idle launcher is invisible until the pointer arrives. NSTrackingArea hover
        // detection runs at the NSView level and is unaffected by SwiftUI opacity, so the
        // mouse-enter event still fires and the reveal plays. Any non-idle capture state is
        // always fully opaque.
        .opacity(isIdleHidden ? 0 : 1)
        .scaleEffect(isIdleHidden ? 0.94 : 1, anchor: .bottom)
        .offset(y: isIdleHidden ? 5 : 0)
        .allowsHitTesting(!isIdleHidden)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(pillShape)
        .onTapGesture { handleTap() }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { updateHitBox(proxy) }
                .onChange(of: targetSize) { updateHitBox(proxy) }
                .onChange(of: bottomSlack) { updateHitBox(proxy) }
        })
    }

    // MARK: - Tap

    private func handleTap() {
        switch vm.capture {
        case .idle:
            // Tapping the nub opens the launcher row. Taps on the open row are ignored —
            // the four action buttons own it, and a stray background click must not launch
            // anything.
            if vm.presentation == .peek {
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

        let originY: CGFloat  // top-left Y of the pill in the panel's SwiftUI coordinate space
        let centerX: CGFloat

        if let proxy {
            let frame = proxy.frame(in: .global)
            originY = frame.minY
            centerX = frame.midX
        } else {
            // Fallback before first layout: place pill at panel bottom minus bottomSlack.
            let envH = IslandGeometryProvider().panelEnvelope(for: screen).height
            originY  = envH - bottomSlack - size.height
            centerX  = IslandGeometryProvider().panelEnvelope(for: screen).width / 2
        }

        let pillX = centerX - size.width / 2

        hitBox.rect = NSRect(x: pillX, y: originY, width: size.width, height: size.height)

        // Hover rect. The recording nub (10 pt tall) and the idle launcher (invisible until
        // hovered) both need a generous catch area — you cannot aim at something you cannot
        // see. An open recording row is visible, so the standard ±12/±3 is fine there.
        let generousCatch = isPeek || isIdleBar
        let hPad: CGFloat = generousCatch ? 40 : 12
        let vPadUp: CGFloat = generousCatch ? 22 : 3
        let vPadDown: CGFloat = generousCatch ? 12 : 3
        hitBox.hoverRect = NSRect(
            x:      pillX  - hPad,
            y:      originY - vPadUp,
            width:  size.width + hPad * 2,
            height: size.height + vPadUp + vPadDown
        )

        // Screen-space span, used by the bottom-edge hover-retention test.
        let envelope = IslandGeometryProvider().panelEnvelope(for: screen)
        // Convert from SwiftUI top-left space to AppKit bottom-left:
        // AppKit Y = envelope.height - (swiftUI_originY + height)
        let appKitY = envelope.origin.y + (envelope.height - (originY + size.height))
        coordinator.hoverRectOnScreen = NSRect(
            x:      envelope.origin.x + pillX - hPad,
            y:      appKitY - vPadDown,
            width:  size.width + hPad * 2,
            height: size.height + vPadUp + vPadDown
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

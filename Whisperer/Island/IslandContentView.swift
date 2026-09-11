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

    /// The resting launcher: near-invisible until the pointer arrives.
    private var isIdleNub: Bool { isPeek && vm.capture == .idle }
    /// The opened launcher bar. Still an idle surface — it must not read as heavy as a
    /// live recording row, which is genuinely demanding attention.
    private var isIdleBar: Bool { !isPeek && vm.capture == .idle }

    @ViewBuilder
    private var surface: some View {
        if isIdleNub {
            // Almost transparent — a hint of the pill, not a black slab on the wallpaper.
            Color.black.opacity(isHovering ? 0.38 : 0.14)
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

    /// How dark the scrim over the blur is. The launcher bar keeps the wallpaper visible
    /// through it; a recording row does not, because its content has to stay readable.
    private var scrimOpacity: Double {
        if isIdleBar { return 0.42 }
        return isPeek ? 0.62 : 0.78
    }

    private var hairlineColor: Color {
        if isIdleNub { return Color.white.opacity(isHovering ? 0.22 : 0.10) }
        return Color.white.opacity(isIdleBar ? 0.12 : 0.16)
    }

    private var shadowOpacity: Double {
        if isIdleNub { return isHovering ? 0.28 : 0.10 }
        if isIdleBar { return 0.22 }
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
            islandBody
            Color.clear.frame(height: bottomSlack)
        }
        // Atoll's key trick: barrier stops any morphKey spring from propagating to the
        // VStack frame, so the panel never jitters on state change.
        .animation(nil, value: morphKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .sensoryFeedback(.alignment, trigger: coordinator.hapticToken)
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
        .overlay(pillShape.strokeBorder(hairlineColor, lineWidth: 0.75))
        .clipShape(pillShape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(shadowOpacity),
            radius: isIdleNub ? 6 : (isIdleBar ? 10 : 18),
            x: 0,
            y: isIdleNub ? 2 : (isIdleBar ? 4 : 8)
        )
        // Springs live HERE — never on the root.
        .animation(activeSpring, value: morphKey)
        .animation(hoverAnim, value: isHovering)
        .animation(.smooth, value: coordinator.gestureProgress)
        // Idle nub is fully invisible until the pointer arrives. The NSTrackingArea hover
        // detection runs at the NSView level and is unaffected by SwiftUI opacity, so the
        // mouse-enter event still fires and the reveal animation plays. During any capture
        // state other than idle the island is always fully opaque.
        .opacity(isIdleNub && !isHovering ? 0 : 1)
        .allowsHitTesting(!(isIdleNub && !isHovering))
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

        // Hover rect: for the nub, pad generously upward (the target is only 10 pt tall).
        // For compact/expanded the standard ±12/±3 is fine.
        let hPad: CGFloat = isPeek ? 40 : 12
        let vPadUp: CGFloat = isPeek ? 22 : 3
        let vPadDown: CGFloat = 3
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

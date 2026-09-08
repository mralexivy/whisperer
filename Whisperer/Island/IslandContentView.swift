//
//  IslandContentView.swift
//  Whisperer
//
//  Island UI — built on Atoll's animation architecture.
//
//  Key Atoll techniques reproduced here:
//   1. Animation split: outer root frame carries .animation(nil) so the panel VStack
//      never animates; the inner island body carries the springs so only its own
//      frame springs to the target size. This is the entire "growing" illusion.
//   2. Distinct open/close springs: .spring(response:0.42,damping:1.0) open,
//      .spring(response:0.45,damping:1.0) close, .bouncy.speed(1.2) hover lift.
//   3. Animatable uneven corners — square on top when the island absorbs the hardware
//      notch, rounded pill when it floats. The radii interpolate during the morph.
//   4. Content-driven size: IslandContentSizer returns the target CGSize per capture
//      state; narrow "Starting…" → wide recording pill → narrow "Finishing…".
//   5. The island REPLACES the hardware notch on notched Macs: its top edge is flush
//      with screen.frame.maxY, it is at least as tall as safeAreaInsets.top, and its
//      content flanks the camera housing (IslandContentSizer.notchGap).
//   6. Hover-to-open with dwell (180 ms), debounced exit (100 ms), and top-edge retention.
//   7. Scroll gesture: down → rubber-band stretch → expand; up → collapse.
//   8. Haptic feedback (.alignment) rate-limited to 300 ms.
//
//  NOTE — no NSViewRepresentable inside the island body. SwiftUI's `.clipShape` cannot
//  clip a hosted AppKit NSView (it is a real sibling view, not a drawn layer), so the old
//  CALayer waveform escaped the pill and painted over the expanded control row. The
//  waveform is pure SwiftUI (see IslandLayout.swift).
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
    private var isHovering: Bool           { coordinator.isHovering }

    // MARK: - Animation constants (from Atoll's measured values)

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

    /// Closed notch + wings (Atoll's `hudWidth`/`hudHeight`), so the housing is always covered.
    private var targetSize: CGSize {
        IslandContentSizer.targetSize(
            capture: vm.capture,
            presentation: vm.presentation,
            screen: screen,
            isHovering: coordinator.isHovering,
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

    private var topSlack: CGFloat { IslandContentSizer.topSlack(screen: screen) }
    private var rowMetrics: IslandRowMetrics {
        IslandContentSizer.rowMetrics(screen: screen,
                                      isHovering: coordinator.isHovering,
                                      gestureProgress: coordinator.gestureProgress)
    }
    private var drawShadow: Bool  { IslandGeometryProvider().shouldDrawShadow(for: screen) }

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
                // Deterministic teardown — .onDisappear is unreliable for borderless panels.
                coordinator.teardownHook = { [weak coordinator] in
                    coordinator?.cancelHoverTask()
                }
                updateHitBox()
            }
    }

    // MARK: - Root (outer, never animates)

    private var rootBodyView: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topSlack)
            islandBody
            Spacer(minLength: 0)
        }
        // ← Atoll's key trick: barrier stops any morphKey spring from propagating to the
        //   VStack frame, so the panel never jitters on state change.
        .animation(nil, value: morphKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .frame(width: targetSize.width, height: targetSize.height, alignment: .top)
        .background(Color.black)
        .clipShape(pillShape)
        .compositingGroup()
        .shadow(
            color: drawShadow
                ? .black.opacity((isHovering || isExpanded) ? 0.6 : 0.22)
                : .clear,
            radius: 12, x: 0, y: 4
        )
        // Springs live HERE — never on the root.
        .animation(activeSpring, value: morphKey)
        .animation(hoverAnim, value: coordinator.isHovering)
        .animation(.smooth, value: coordinator.gestureProgress)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(pillShape)
        .onTapGesture { handleTap() }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { updateHitBox(proxy) }
                .onChange(of: targetSize) { updateHitBox(proxy) }
                .onChange(of: topSlack)   { updateHitBox(proxy) }
        })
    }

    // MARK: - Tap

    private func handleTap() {
        switch vm.capture {
        case .recording, .paused:
            coordinator.send(isExpanded ? .collapse : .expand)
        default:
            break
        }
    }

    // MARK: - Hit box

    /// Publishes two rects in the hosting view's TOP-LEFT origin space:
    ///  - `rect`      the exact pill — the click-through boundary
    ///  - `hoverRect` 24 pt wider / 6 pt taller, so hover is forgiving while clicks stay tight
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

        let originY: CGFloat
        let centerX: CGFloat
        if let proxy {
            let frame = proxy.frame(in: .global)
            originY = frame.minY
            centerX = frame.midX
        } else {
            originY = topSlack
            centerX = IslandGeometryProvider().panelEnvelope(for: screen).width / 2
        }

        let pillX = centerX - size.width / 2
        hitBox.rect = NSRect(x: pillX, y: originY, width: size.width, height: size.height)
        hitBox.hoverRect = NSRect(x: pillX - 12, y: originY - 3,
                                  width: size.width + 24, height: size.height + 6)

        // Screen-space span, used by the top-edge hover-retention test.
        let envelope = IslandGeometryProvider().panelEnvelope(for: screen)
        coordinator.hoverRectOnScreen = NSRect(
            x: envelope.minX + pillX - 12,
            y: envelope.maxY - originY - size.height - 3,
            width: size.width + 24,
            height: size.height + 6
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

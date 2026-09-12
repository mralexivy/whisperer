//
//  IslandLayout.swift
//  Whisperer
//
//  The live-activity chain — three-tier layout for the bottom-anchored Island.
//
//  Tier routing by vm.presentation:
//   .peek     → peekBody  (pulsing dot + level glow, ~120×10 pt)
//   .compact  → compactBody (state-branching recording/status rows)
//   .expanded → compactBody + secondaryRow
//
//  Compact recording row (always visible while recording):
//    [● pulse] [~~~waveform~~~] [0:06] [⏸ pause] [■ stop]
//
//  Expanded secondary row (added by tap / hover dwell / scroll):
//    [🎤 Mic] [🔈 Speaker] [↗ Open]
//
//  There is no camera-housing dead zone — the Island is bottom-anchored with no notch.
//

import SwiftUI

// MARK: - Root layout view

struct IslandLayout: View {

    @ObservedObject var coordinator: IslandCoordinator
    @ObservedObject var levelBridge: IslandLevelBridge
    @ObservedObject var clock: IslandElapsedTimer

    /// Row metrics for the compact strip.
    var metrics: IslandRowMetrics

    private var vm: IslandViewModel { coordinator.currentViewModel }
    private var isExpanded: Bool    { vm.presentation == .expanded }
    private var isPeek: Bool        { vm.presentation == .peek }

    // Swap transition between capture states
    private var swapTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.965, anchor: .center))
                .animation(.spring(response: 0.34, dampingFraction: 0.88)),
            removal:   .opacity.combined(with: .scale(scale: 0.92, anchor: .center))
                .animation(.smooth(duration: 0.22))
        )
    }

    var body: some View {
        if isPeek {
            peekBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                compactBody
                    .frame(height: IslandContentSizer.compactHeight(for: vm.capture))

                if isExpanded {
                    secondaryRow
                        .frame(maxWidth: .infinity)
                        .frame(height: IslandContentSizer.expandedExtraHeight)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(IC.secondary.opacity(0.16))
                                .frame(height: 1)
                                .padding(.horizontal, 18)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }

    // MARK: - Peek body (recording only — idle always shows the compact launcher bar)

    private var peekBody: some View { recordingNubBody }

    private var recordingNubBody: some View {
        HStack(spacing: 8) {
            RecordingDot(isPaused: vm.isPaused)

            PeekLevelMeter(level: levelBridge.peekLevel,
                           isPaused: vm.isPaused || vm.isMicMuted)
                .frame(maxWidth: .infinity)

            Text(clock.displayText)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(IC.primary.opacity(0.82))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.3), value: clock.displayText)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compact body (state-branching)

    @ViewBuilder
    private var compactBody: some View {
        switch vm.capture {
        case .recording:
            recordingRow(isPaused: false).transition(swapTransition)
        case .paused:
            recordingRow(isPaused: true).transition(swapTransition)
        case .starting:
            statusRow(IslandProgressRule(tint: IC.accent,
                                         label: vm.statusLabel.isEmpty ? "Starting…" : vm.statusLabel,
                                         fraction: vm.preparationProgress))
                .transition(swapTransition)
        case .permissionRequired:
            statusRow(permissionRow).transition(swapTransition)
        case .finalizing:
            statusRow(IslandProgressRule(tint: IC.accent, label: "Finishing…", fraction: nil))
                .transition(swapTransition)
        case .failed(let msg):
            statusRow(failedRow(msg)).transition(swapTransition)
        case .idle:
            idleLauncherRow.transition(swapTransition)
        }
    }

    // MARK: - Idle launcher row

    /// Four bare glyphs, grouped: the two that *start* a capture, a hairline, then the two
    /// that *open* a surface. No captions and no filled chips — the whole point of the bar
    /// is that it stays out of the way. What each glyph does is named by the hint label the
    /// root view floats above the bar on hover, not by a caption baked into the row.
    private var idleLauncherRow: some View {
        HStack(spacing: 2) {
            launcherItem(
                icon: "mic.fill",
                title: "Dictate",
                help: "Start dictation — click the stop button in the recording bar to finish"
            ) {
                coordinator.send(.dictateRequested)
            }

            launcherItem(
                icon: "person.2.fill",
                title: "Meeting",
                help: "Start a meeting recording"
            ) {
                coordinator.send(.startMeetingRequested)
            }

            launcherDivider

            launcherItem(
                icon: "list.clipboard.fill",
                title: "Paste Bin",
                help: "Open recent transcriptions"
            ) {
                coordinator.send(.openPasteBinRequested)
            }

            launcherItem(
                icon: "square.grid.2x2.fill",
                title: "Workspace",
                help: "Open the Whisperer workspace"
            ) {
                coordinator.send(.openWorkspaceRequested)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func launcherItem(
        icon: String,
        title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        LauncherItem(
            coordinator: coordinator,
            icon: icon,
            title: title,
            help: help,
            action: action
        )
    }

    private var launcherDivider: some View {
        Rectangle()
            .fill(IC.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 5)
            .accessibilityHidden(true)
    }

    /// Simplified strip without the notch dead zone — content spans the full width.
    private func strip<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(width: metrics.rowHeight, height: metrics.rowHeight)
                .padding(.leading, 10)

            trailing()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: metrics.rowHeight)
                .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusRow<Content: View>(_ content: Content) -> some View {
        strip(leading: { Color.clear }, trailing: { content })
    }

    // MARK: - Recording / Paused row

    private func recordingRow(isPaused: Bool) -> some View {
        strip {
            RecordingDot(isPaused: isPaused)
        } trailing: {
            HStack(spacing: 8) {
                IslandWaveform(levelBridge: levelBridge,
                               isPaused: isPaused || vm.isMicMuted)
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

    // MARK: - Inline stop button

    private var inlineStopButton: some View {
        Button {
            coordinator.send(.stopRequested(sessionID: vm.sessionID))
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        Color.white.opacity(vm.capture == .finalizing ? 0.5 : 0.95),
                        lineWidth: 1.6
                    )

                RoundedRectangle(cornerRadius: max(3, metrics.controlSize * 0.1),
                                 style: .continuous)
                    .fill(IC.error)
                    .frame(width: metrics.controlSize * 0.38,
                           height: metrics.controlSize * 0.38)
                    .scaleEffect(vm.capture == .finalizing ? 0.84 : 1.0)
            }
            .frame(width: metrics.controlSize, height: metrics.controlSize)
            .contentShape(Circle())
        }
        .buttonStyle(IslandInlineStopStyle())
        .disabled(vm.capture == .finalizing)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }

    // MARK: - Permission row

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(IC.attention)

            Text("Microphone access needed")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(IC.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Failed row

    private func failedRow(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(IC.error)

            Text(msg.isEmpty ? "Recording failed" : msg)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(IC.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 6)

            IslandHoverButton(icon: "xmark", iconColor: IC.secondary) {
                coordinator.send(.dismissFailure)
            }
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
    }

    // MARK: - Secondary (expanded) row

    private var secondaryRow: some View {
        HStack(spacing: 24) {
            IslandHoverButton(
                icon: vm.isMicMuted ? "mic.slash.fill" : "mic.fill",
                label: vm.isMicMuted ? "Unmute" : "Mic",
                scale: .large,
                iconColor: vm.isMicMuted ? IC.attention : IC.primary
            ) {
                coordinator.send(.micMuteRequested(sessionID: vm.sessionID))
            }
            .help(vm.isMicMuted ? "Unmute microphone" : "Mute microphone")

            IslandHoverButton(
                icon: vm.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: vm.isOutputMuted ? "Muted" : "Speaker",
                scale: .large,
                iconColor: vm.isOutputMuted ? IC.attention : IC.primary
            ) {
                coordinator.send(.outputMuteRequested(sessionID: vm.sessionID))
            }
            .help(vm.isOutputMuted ? "Capture system audio" : "Mute system audio")

            IslandHoverButton(
                icon: "rectangle.on.rectangle",
                label: "Open",
                scale: .large,
                iconColor: IC.primary
            ) {
                coordinator.send(.openWindowRequested)
            }
            .help("Open the meeting window")
        }
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Launcher item

/// One glyph in the idle launcher bar, wired to the floating hint label.
///
/// The glyph tracks its own centre in panel coordinates so the label can sit directly over
/// it rather than over the middle of the bar. `.help` is deliberately not used: the system
/// tooltip would fade in a second later on top of the hint and say the same thing twice.
private struct LauncherItem: View {
    @ObservedObject var coordinator: IslandCoordinator
    let icon: String
    let title: String
    let help: String
    let action: () -> Void

    @State private var anchorX: CGFloat = 0

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
                Color.clear
                    .onAppear { anchorX = geo.frame(in: .global).midX }
                    .onChange(of: geo.frame(in: .global).midX) { _, newX in anchorX = newX }
            }
        )
        .onHover { hovering in
            if hovering {
                coordinator.setLauncherHint(title, anchorX: anchorX)
            } else {
                coordinator.clearLauncherHint(ifTitleIs: title)
            }
        }
        .accessibilityLabel(help)
    }
}

// MARK: - Launcher hint label

/// The floating name of the hovered glyph. Deliberately tiny: a hairline-bordered glass
/// chip with one word in it, so it reads as a caption for the bar rather than as a second
/// piece of chrome competing with it.
struct IslandLauncherHintLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(IC.primary.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Capsule().fill(Color.black.opacity(0.18))
                }
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
            .allowsHitTesting(false)
    }
}

// MARK: - Peek level meter

/// Five bars driven by the 12 Hz `peekLevel` — the nub's cheap stand-in for the 20-bar,
/// 60 Hz waveform that only runs once the compact row is open.
private struct PeekLevelMeter: View {
    var level: Float
    var isPaused: Bool

    private static let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(IC.primary.opacity(isPaused ? 0.22 : 0.78))
                    .frame(width: 2.5,
                           height: max(3, CGFloat(level) * 14 * weight + 3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.easeOut(duration: 0.2), value: isPaused)
    }
}

// MARK: - Waveform

private struct IslandWaveform: View {
    @ObservedObject var levelBridge: IslandLevelBridge
    var isPaused: Bool

    var body: some View {
        WaveformView(waveformState: levelBridge.waveform)
            .opacity(isPaused ? 0.35 : 1)
            .animation(.easeOut(duration: 0.2), value: isPaused)
    }
}

// MARK: - Color palette

enum IC {
    static let surface   = Color.black
    static let raised    = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let primary   = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let secondary = Color(red: 0.631, green: 0.631, blue: 0.671)
    static let accent    = Color(red: 0.357, green: 0.424, blue: 0.969)
    static let error     = Color(red: 1, green: 0.502, blue: 0.478)
    /// The launcher bar only exists on screen while the pointer is over it, so its glyphs
    /// are legible from the moment they appear; the per-button hover state is what picks
    /// one out of the row, not a rest-vs-active brightness jump for the whole bar.
    ///
    /// All four glyphs share one colour on purpose. Tinting Dictate blue to mark it as the
    /// default action just made one icon look mismatched against the glass — the divider
    /// already carries the grouping, so the row reads better as a single neutral set.
    static let glyph            = Color(red: 0.961, green: 0.961, blue: 0.969).opacity(0.72)
    static let glyphHover       = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let attention = Color(red: 0.941, green: 0.745, blue: 0.384)
}

// MARK: - Stop button style

private struct IslandInlineStopStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

// MARK: - Pulsing dot

struct PulsingModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.3 : 0.8)
            .opacity(pulsing ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

struct RecordingDot: View {
    var isPaused: Bool
    var body: some View {
        if isPaused {
            Circle().fill(Color.red.opacity(0.6)).frame(width: 8, height: 8)
        } else {
            Circle().fill(Color.red).frame(width: 8, height: 8).modifier(PulsingModifier())
        }
    }
}

// MARK: - Progress rule

struct IslandProgressRule: View {
    var tint: Color
    var label: String
    /// nil = indeterminate sweep; 0–1 = determinate fill
    var fraction: Double?

    private let ruleHeight: CGFloat = 3

    var body: some View {
        HStack(spacing: 10) {
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.18)).frame(height: ruleHeight)
                        Capsule()
                            .fill(tint)
                            .frame(width: geo.size.width * min(max(fraction, 0), 1),
                                   height: ruleHeight)
                            .animation(.smooth(duration: 0.4), value: fraction)
                    }
                    .frame(height: geo.size.height, alignment: .center)
                }
                .frame(height: ruleHeight)
            } else {
                rule(fadingTowards: .leading)
            }

            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()

            if fraction == nil {
                rule(fadingTowards: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private func rule(fadingTowards edge: UnitPoint) -> some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.5), tint.opacity(0.12)],
                    startPoint: edge == .leading ? .trailing : .leading,
                    endPoint: edge
                )
            )
            .frame(height: ruleHeight)
    }
}

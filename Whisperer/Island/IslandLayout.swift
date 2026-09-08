//
//  IslandLayout.swift
//  Whisperer
//
//  The live-activity chain — Atoll's NotchLayout() equivalent.
//  One prioritized switch on vm.capture picks the compact body; expanded controls
//  drop below when vm.presentation == .expanded.
//
//  Compact recording row (always visible, no tap required):
//    [● pulse] [~~~waveform~~~]  ⟨notch gap⟩  [0:06] [⏸ pause] [■ stop]
//
//  Expanded secondary row (added by tap / hover dwell / scroll down):
//    [🎤 Mic] [🔈 Speaker] [↗ Open]
//
//  On a notched Mac the island REPLACES the camera housing, so every row reserves a
//  centred dead zone `notchGap` wide. Anything laid out there is invisible — this is the
//  bug that made the old compact row look like it had a giant unexplained hole in it.
//

import SwiftUI

// MARK: - Root layout view

struct IslandLayout: View {

    @ObservedObject var coordinator: IslandCoordinator
    @ObservedObject var levelBridge: IslandLevelBridge
    @ObservedObject var clock: IslandElapsedTimer

    /// Zone widths for the compact strip — see `IslandContentSizer.rowMetrics`.
    var metrics: IslandRowMetrics

    private var vm: IslandViewModel { coordinator.currentViewModel }
    private var isExpanded: Bool { vm.presentation == .expanded }

    // Swap transition between capture states — Atoll's closedLiveActivitySwapTransition
    private var swapTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.965, anchor: .center))
                .animation(.spring(response: 0.34, dampingFraction: 0.88)),
            removal:   .opacity.combined(with: .scale(scale: 0.92, anchor: .center))
                .animation(.smooth(duration: 0.22))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            compactBody
                .frame(height: metrics.compactHeight)

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
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
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
            EmptyView()
        }
    }

    /// Every compact body uses Atoll's three-zone strip: a fixed-width leading badge, the
    /// camera-housing dead zone, and a trailing zone that absorbs all remaining width.
    ///
    /// The zones are deliberately asymmetric. Giving leading and trailing an equal
    /// `maxWidth: .infinity` share — as this file used to — strands dead space in the middle of
    /// the pill and caps the waveform at half the width, which is the "cut" waveform.
    private func strip<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(width: metrics.leadingWidth, height: metrics.rowHeight)
                .padding(.leading, 10)

            if metrics.centerWidth > 0 {
                // The housing. Must stay empty — anything drawn here is simply not visible.
                Color.clear.frame(width: metrics.centerWidth, height: metrics.rowHeight)
            }

            trailing()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: metrics.rowHeight)
                .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A single-line status body: glyph or rule in the leading badge, message trailing.
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
                    // Reserve room for h:mm:ss so the digits never clip mid-recording.
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

    // MARK: - Inline stop button (Atoll RecordingLiveActivity style)

    private var inlineStopButton: some View {
        Button {
            coordinator.send(.stopRequested(sessionID: vm.sessionID))
        } label: {
            // Atoll `stopButton(size:lineWidth:)` — the square is 38 % of the circle, and the
            // circle is sized to the strip rather than fixed, so it fits a 32 pt notch.
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
        .environment(\.layoutDirection, .leftToRight) // always LTR regardless of locale
    }
}

// MARK: - Waveform

/// The Island renders the HUD's own `WaveformView` — same 60 Hz scroll, same perceptual curve,
/// same bar geometry and accent. The Island's earlier bespoke 30 fps version read as sluggish
/// next to it; two visualizers for one signal was the bug.
///
/// Deliberately NOT an NSViewRepresentable: SwiftUI's `.clipShape` does not clip hosted
/// AppKit views, so a CALayer waveform escapes the pill and paints over whatever is below it.
private struct IslandWaveform: View {
    @ObservedObject var levelBridge: IslandLevelBridge
    var isPaused: Bool

    var body: some View {
        WaveformView(waveformState: levelBridge.waveform)
            .opacity(isPaused ? 0.35 : 1)
            .animation(.easeOut(duration: 0.2), value: isPaused)
    }
}

// MARK: - Color palette (local mirror — same values as the Island design tokens)

enum IC {
    static let surface   = Color.black
    static let raised    = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let primary   = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let secondary = Color(red: 0.631, green: 0.631, blue: 0.671)
    static let accent    = Color(red: 0.357, green: 0.424, blue: 0.969)
    static let error     = Color(red: 1, green: 0.502, blue: 0.478)
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

private struct RecordingDot: View {
    var isPaused: Bool
    var body: some View {
        if isPaused {
            Circle().fill(Color.red.opacity(0.6)).frame(width: 8, height: 8)
        } else {
            Circle().fill(Color.red).frame(width: 8, height: 8).modifier(PulsingModifier())
        }
    }
}

// MARK: - Progress rule (Atoll LiveStreamProgressIndicator equivalent)

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

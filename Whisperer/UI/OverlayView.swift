//
//  OverlayView.swift
//  Whisperer
//
//  Overlay bar — dark navy theme matching workspace & onboarding
//

import SwiftUI

// MARK: - Premium Hover Tooltip with Arrow

struct HoverTooltip: ViewModifier {
    let text: String
    let position: TooltipPosition
    @Binding var isVisible: Bool
    var scale: CGFloat = 1.0

    enum TooltipPosition {
        case above
        case below
    }

    private let tooltipBackground = Color(red: 0.08, green: 0.08, blue: 0.16)  // Slightly lighter for visibility
    private let tooltipBorder = Color.white.opacity(0.12)
    private let arrowSize: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .overlay(alignment: position == .above ? .top : .bottom) {
                tooltipWithArrow
                    .fixedSize()
                    .offset(y: position == .above ? -(38 * scale) : (38 * scale))
                    .opacity(isVisible ? 1 : 0)
                    .scaleEffect(isVisible ? 1 : 0.9, anchor: position == .above ? .bottom : .top)
                    .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isVisible)
                    .allowsHitTesting(false)
            }
    }

    private var tooltipWithArrow: some View {
        VStack(spacing: 0) {
            if position == .below {
                // Arrow pointing up
                TooltipArrow(direction: .up, color: tooltipBackground, borderColor: tooltipBorder)
                    .frame(width: arrowSize * 2 * scale, height: arrowSize * scale)
            }

            // Tooltip body
            Text(text)
                .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 6 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 8 * scale)
                        .fill(tooltipBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8 * scale)
                                .stroke(tooltipBorder, lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                )

            if position == .above {
                // Arrow pointing down
                TooltipArrow(direction: .down, color: tooltipBackground, borderColor: tooltipBorder)
                    .frame(width: arrowSize * 2 * scale, height: arrowSize * scale)
            }
        }
    }
}

// MARK: - Tooltip Arrow Shape

struct TooltipArrow: View {
    enum Direction {
        case up
        case down
    }

    let direction: Direction
    let color: Color
    let borderColor: Color

    var body: some View {
        ZStack {
            // Fill
            ArrowTriangle(direction: direction)
                .fill(color)

            // Border on edges only
            ArrowTriangleBorder(direction: direction)
                .stroke(borderColor, lineWidth: 0.5)
        }
    }
}

struct ArrowTriangle: Shape {
    let direction: TooltipArrow.Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if direction == .down {
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

struct ArrowTriangleBorder: Shape {
    let direction: TooltipArrow.Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if direction == .down {
            // Only diagonal edges, not top
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            // Only diagonal edges, not bottom
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return path
    }
}

extension View {
    func hoverTooltip(_ text: String, position: HoverTooltip.TooltipPosition = .above, isVisible: Binding<Bool>, scale: CGFloat = 1.0) -> some View {
        modifier(HoverTooltip(text: text, position: position, isVisible: isVisible, scale: scale))
    }
}

struct OverlayView: View {
    @ObservedObject var appState = AppState.shared
    @AppStorage("overlaySize") private var overlaySizeRaw: String = OverlaySize.medium.rawValue
    @State private var isCloseHovered = false

    private var scale: CGFloat {
        (OverlaySize(rawValue: overlaySizeRaw) ?? .medium).scale
    }

    // Dark navy palette — always dark, matches workspace & onboarding
    private let hudBackground = Color(red: 0.078, green: 0.078, blue: 0.169)      // #14142B
    private let hudBorder = Color.white.opacity(0.06)
    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)          // #5B6CF7
    private let purpleAccent = Color(red: 0.545, green: 0.361, blue: 0.965)        // #8B5CF6

    #if APP_STORE
    private var accentColor: Color { blueAccent }
    #else
    private var accentColor: Color {
        appState.activeMode == .rewrite ? purpleAccent : blueAccent
    }
    #endif

    // Scaled dimensions
    private var circleSize: CGFloat { 44 * scale }
    private var buttonSize: CGFloat { 36 * scale }
    private var waveformWidth: CGFloat { 100 * scale }
    private var waveformHeight: CGFloat { 28 * scale }
    private var appIconSize: CGFloat { 20 * scale }
    private var hPadding: CGFloat { 16 * scale }
    private var vPadding: CGFloat { 10 * scale }
    private var spacing: CGFloat { 12 * scale }

    var body: some View {
        VStack(spacing: 8 * scale) {
            if appState.showClipboardToast {
                ClipboardToastIndicator(scale: scale)
            } else if appState.showModelLoadingToast {
                ModelLoadingIndicator(scale: scale)
            } else if appState.state != .idle {
                // Live transcription card (shown during recording)
                if appState.liveTranscriptionEnabled && appState.state.isRecording {
                    LiveTranscriptionCard(appState: appState)
                }

                // Processing indicator (shown during final pass or rewrite)
                if case .stopping = appState.state {
                    if let aiModeName = appState.activeAIModeName {
                        AnimatedStatusCapsule(
                            text: aiModeName,
                            borderColor: purpleAccent,
                            scale: scale
                        )
                    } else {
                        ProcessingIndicator(scale: scale)
                    }
                } else if case .rewriting = appState.state {
                    AnimatedStatusCapsule(
                        text: appState.activeAIModeName ?? "Rewriting",
                        borderColor: purpleAccent,
                        scale: scale
                    )
                }

                // Download indicator (shown during model download)
                if case .downloadingModel = appState.state {
                    DownloadingIndicator(scale: scale)
                }

                // Main control bar — crossfades to hands-free toast when activated
                ZStack {
                    // Normal recording controls
                    HStack(spacing: spacing) {
                        // Left indicator: Download indicator OR Pause/Resume button
                        if case .downloadingModel = appState.state {
                            DownloadingLeftIndicator(scale: scale)
                        } else {
                            PauseResumeButton(
                                isPaused: $appState.isPaused,
                                isRecording: appState.state.isRecording,
                                scale: scale
                            ) {
                                appState.togglePause()
                            }
                        }

                        if let icon = appState.targetAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: appIconSize, height: appIconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
                        }

                        WaveformView(amplitudes: appState.waveformAmplitudes)
                            .frame(width: waveformWidth, height: waveformHeight)

                        if case .transcribing = appState.state {
                            TranscribingIndicator(scale: scale)
                        } else if case .rewriting = appState.state {
                            TranscribingIndicator(scale: scale)
                        } else if case .downloadingModel(let progress) = appState.state {
                            DownloadIndicator(progress: progress, scale: scale)
                        } else {
                            OutputAudioButton(
                                isOutputMuted: $appState.isOutputAudioMuted,
                                scale: scale
                            ) {
                                appState.toggleOutputAudioMute()
                            }
                        }

                        // Right button: Cancel download OR Stop recording
                        if case .downloadingModel = appState.state {
                            CancelDownloadButton(scale: scale) {
                                appState.cancelModelDownload()
                            }
                        } else {
                            CloseButton(scale: scale, isHovered: $isCloseHovered) {
                                appState.stopRecording()
                            }
                        }
                    }
                    .opacity(appState.showHandsFreeToast ? 0 : 1)

                    // Hands-free toast (replaces controls for 3s)
                    if appState.showHandsFreeToast {
                        HandsFreeToastContent(scale: scale)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .background(
                    Capsule()
                        .fill(hudBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(appState.showHandsFreeToast ? blueAccent.opacity(0.2) : hudBorder, lineWidth: 1)
                )
                .shadow(color: appState.showHandsFreeToast ? blueAccent.opacity(0.1) : .clear, radius: 8, y: 2)
                .animation(.easeInOut(duration: 0.3), value: appState.showHandsFreeToast)
            }
        }
        .padding(.top, 35 * scale)  // Space for expand/collapse tooltip
        .environment(\.overlayScale, scale)
        .background(Color.clear)
    }
}

// MARK: - Pause/Resume Button

struct PauseResumeButton: View {
    @Binding var isPaused: Bool
    let isRecording: Bool
    var scale: CGFloat = 1.0
    var onTap: () -> Void
    @State private var isHovered = false
    @State private var dotPulsing = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7
    private let amberAccent = Color.orange  // Paused state

    private var accentColor: Color {
        isPaused ? amberAccent : blueAccent
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Main circle with hover fill change
                Circle()
                    .fill(accentColor.opacity(isHovered ? 0.25 : 0.15))
                    .frame(width: 44 * scale, height: 44 * scale)

                // Icon with smooth transition
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 18 * scale, weight: .medium))
                    .foregroundColor(accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.2), value: isPaused)

                // Status dot — pulsing when recording, static when paused
                Circle()
                    .fill(accentColor)
                    .frame(width: 10 * scale, height: 10 * scale)
                    .scaleEffect(isPaused ? 1.0 : (dotPulsing ? 1.2 : 0.9))
                    .opacity(isPaused ? 0.8 : (dotPulsing ? 1.0 : 0.55))
                    .offset(x: 14 * scale, y: 14 * scale)
                    .animation(
                        isPaused ? .easeOut(duration: 0.2) : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: dotPulsing
                    )
                    .animation(.easeInOut(duration: 0.3), value: isPaused)
            }
            .frame(width: 44 * scale, height: 44 * scale)  // Fixed frame prevents layout jump
            .background(
                // Outer glow ring on hover (as background, doesn't affect layout)
                Circle()
                    .stroke(accentColor.opacity(isHovered ? 0.3 : 0), lineWidth: 2 * scale)
                    .frame(width: 50 * scale, height: 50 * scale)
                    .blur(radius: 2)
            )
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .shadow(color: isHovered ? accentColor.opacity(0.2) : .clear, radius: 8, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onChange(of: isRecording) { recording in
            dotPulsing = recording && !isPaused
        }
        .onChange(of: isPaused) { paused in
            withAnimation {
                dotPulsing = isRecording && !paused
            }
        }
        .onAppear {
            if isRecording && !isPaused {
                dotPulsing = true
            }
        }
        .hoverTooltip(isPaused ? "Resume recording" : "Pause recording", position: .above, isVisible: $isHovered, scale: scale)
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }
}

// MARK: - Output Audio Button

struct OutputAudioButton: View {
    @Binding var isOutputMuted: Bool
    var scale: CGFloat = 1.0
    var onTap: () -> Void
    @State private var isHovered = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7
    private let warningOrange = Color.orange

    private var accentColor: Color {
        isOutputMuted ? blueAccent : warningOrange
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Main circle with hover fill change
                Circle()
                    .fill(accentColor.opacity(isHovered ? 0.3 : 0.15))
                    .frame(width: 36 * scale, height: 36 * scale)

                // Icon with smooth transition
                Image(systemName: isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14 * scale, weight: .medium))
                    .foregroundColor(accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.2), value: isOutputMuted)
            }
            .frame(width: 36 * scale, height: 36 * scale)  // Fixed frame prevents layout jump
            .background(
                // Outer glow ring on hover (as background, doesn't affect layout)
                Circle()
                    .stroke(accentColor.opacity(isHovered ? 0.3 : 0), lineWidth: 1.5 * scale)
                    .frame(width: 42 * scale, height: 42 * scale)
                    .blur(radius: 2)
            )
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .shadow(color: isHovered ? accentColor.opacity(0.2) : .clear, radius: 6, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .hoverTooltip(isOutputMuted ? "Capture output audio" : "Mute output audio", position: .above, isVisible: $isHovered, scale: scale)
        .accessibilityLabel(isOutputMuted ? "Unmute system audio" : "Mute system audio")
    }
}

// MARK: - Downloading Left Indicator (non-interactive)

struct DownloadingLeftIndicator: View {
    var scale: CGFloat = 1.0
    @State private var isAnimating = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .fill(blueAccent.opacity(0.15))
                .frame(width: 44 * scale, height: 44 * scale)

            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20 * scale, weight: .medium))
                .foregroundColor(blueAccent)
                .scaleEffect(isAnimating ? 1.1 : 0.95)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
        }
        .frame(width: 44 * scale, height: 44 * scale)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Cancel Download Button

struct CancelDownloadButton: View {
    var scale: CGFloat = 1.0
    var onTap: () -> Void
    @State private var isHovered = false

    private let buttonSize: CGFloat = 36

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(isHovered ? 0.25 : 0.1))
                    .frame(width: buttonSize * scale, height: buttonSize * scale)

                Image(systemName: "xmark")
                    .font(.system(size: 14 * scale, weight: .bold))
                    .foregroundColor(isHovered ? .red.opacity(1) : .red.opacity(0.7))
            }
            .frame(width: buttonSize * scale, height: buttonSize * scale)
            .background(
                // Outer glow ring on hover
                Circle()
                    .stroke(Color.red.opacity(isHovered ? 0.3 : 0), lineWidth: 1.5 * scale)
                    .frame(width: 42 * scale, height: 42 * scale)
                    .blur(radius: 2)
            )
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .shadow(color: isHovered ? Color.red.opacity(0.2) : .clear, radius: 6, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .hoverTooltip("Cancel download", position: .above, isVisible: $isHovered, scale: scale)
        .accessibilityLabel("Cancel model download")
    }
}

// MARK: - Close Button (Stop Recording)

struct CloseButton: View {
    var scale: CGFloat = 1.0
    @Binding var isHovered: Bool
    var onTap: () -> Void

    private let buttonSize: CGFloat = 36

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(isHovered ? 0.25 : 0.1))
                    .frame(width: buttonSize * scale, height: buttonSize * scale)

                Image(systemName: "xmark")
                    .font(.system(size: 14 * scale, weight: .bold))
                    .foregroundColor(isHovered ? .red.opacity(1) : .red.opacity(0.7))
            }
            .frame(width: buttonSize * scale, height: buttonSize * scale)
            .background(
                // Outer glow ring on hover
                Circle()
                    .stroke(Color.red.opacity(isHovered ? 0.3 : 0), lineWidth: 1.5 * scale)
                    .frame(width: 42 * scale, height: 42 * scale)
                    .blur(radius: 2)
            )
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .shadow(color: isHovered ? Color.red.opacity(0.2) : .clear, radius: 6, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .hoverTooltip("Stop recording", position: .above, isVisible: $isHovered, scale: scale)
        .accessibilityLabel("Stop recording and close")
    }
}

// MARK: - Transcribing Indicator

struct TranscribingIndicator: View {
    var scale: CGFloat = 1.0
    @State private var isAnimating = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .fill(blueAccent.opacity(0.15))
                .frame(width: 36 * scale, height: 36 * scale)

            HStack(spacing: 3 * scale) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(blueAccent)
                        .frame(width: 5 * scale, height: 5 * scale)
                        .scaleEffect(isAnimating ? 1.0 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(index) * 0.15),
                            value: isAnimating
                        )
                }
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Animated Status Capsule (shared by Processing, Downloading, Loading)

private struct AnimatedStatusCapsule: View {
    let text: String
    let borderColor: Color
    var scale: CGFloat = 1.0
    @State private var isAnimating = false

    private let hudBackground = Color(red: 0.078, green: 0.078, blue: 0.169)
    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)
    private let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        HStack(spacing: 8 * scale) {
            HStack(spacing: 3 * scale) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5 * scale)
                        .fill(
                            LinearGradient(
                                colors: [accentBlue, accentPurple],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3 * scale, height: isAnimating ? barHeight(for: index) : 4 * scale)
                        .animation(
                            .easeInOut(duration: duration(for: index))
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                            value: isAnimating
                        )
                }
            }
            .frame(height: 14 * scale)

            Text(text)
                .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 8 * scale)
        .background(
            Capsule()
                .fill(hudBackground)
                .overlay(
                    Capsule()
                        .stroke(borderColor.opacity(0.15), lineWidth: 1)
                )
        )
        .onAppear {
            isAnimating = false
            DispatchQueue.main.async {
                isAnimating = true
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [10, 14, 8, 12]
        return heights[index % heights.count] * scale
    }

    private func duration(for index: Int) -> Double {
        [0.5, 0.4, 0.6, 0.45][index % 4]
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    var scale: CGFloat = 1.0
    private let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        AnimatedStatusCapsule(text: "Processing", borderColor: accentPurple, scale: scale)
    }
}

// MARK: - Download Indicator (top bar — animated like ProcessingIndicator)

struct DownloadingIndicator: View {
    var scale: CGFloat = 1.0
    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)

    var body: some View {
        AnimatedStatusCapsule(text: "Downloading...", borderColor: accentBlue, scale: scale)
    }
}

// MARK: - Download Indicator (inline, for HUD bar)

struct DownloadIndicator: View {
    let progress: Double
    var scale: CGFloat = 1.0

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 3 * scale)
                .frame(width: 36 * scale, height: 36 * scale)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(blueAccent, style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round))
                .frame(width: 36 * scale, height: 36 * scale)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)

            Text("\(Int(progress * 100))")
                .font(.system(size: 10 * scale, weight: .bold))
                .foregroundColor(.white)
                .monospacedDigit()
        }
    }
}

// MARK: - Model Loading Toast

struct ModelLoadingIndicator: View {
    var scale: CGFloat = 1.0
    private let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        AnimatedStatusCapsule(text: "Loading model...", borderColor: accentPurple, scale: scale)
    }
}

// MARK: - Clipboard Toast Indicator

struct ClipboardToastIndicator: View {
    var scale: CGFloat = 1.0
    @State private var checkmarkScale: CGFloat = 0.0
    @State private var checkmarkOpacity: Double = 0.0
    @State private var textOpacity: Double = 0.0
    @State private var ringProgress: CGFloat = 0.0

    private let hudBackground = Color(red: 0.078, green: 0.078, blue: 0.169)
    private let accentGreen = Color(red: 0.286, green: 0.824, blue: 0.506)   // #49D281
    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)    // #5B6CF7

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Animated checkmark circle
            ZStack {
                // Background ring
                Circle()
                    .stroke(accentGreen.opacity(0.15), lineWidth: 2 * scale)
                    .frame(width: 30 * scale, height: 30 * scale)

                // Animated progress ring
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(accentGreen, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .frame(width: 30 * scale, height: 30 * scale)
                    .rotationEffect(.degrees(-90))

                // Checkmark icon
                Image(systemName: "checkmark")
                    .font(.system(size: 13 * scale, weight: .bold))
                    .foregroundColor(accentGreen)
                    .scaleEffect(checkmarkScale)
                    .opacity(checkmarkOpacity)
            }

            // Text content
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("Copied to Clipboard")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                HStack(spacing: 4 * scale) {
                    Text("Press")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))

                    // Key cap style ⌘V
                    HStack(spacing: 2 * scale) {
                        Text("⌘")
                            .font(.system(size: 11 * scale, weight: .semibold))
                        Text("V")
                            .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * scale)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4 * scale)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )

                    Text("to paste")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .opacity(textOpacity)
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 10 * scale)
        .background(
            Capsule()
                .fill(hudBackground)
                .overlay(
                    Capsule()
                        .stroke(accentGreen.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: accentGreen.opacity(0.1), radius: 8, y: 2)
        )
        .onAppear {
            // Ring draws in
            withAnimation(.easeOut(duration: 0.4)) {
                ringProgress = 1.0
            }
            // Checkmark pops in after ring completes
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.3)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
            // Text fades in
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) {
                textOpacity = 1.0
            }
        }
    }
}

// MARK: - Hands-Free Toast Content (displayed inside the HUD capsule)

struct HandsFreeToastContent: View {
    var scale: CGFloat = 1.0
    @State private var iconScale: CGFloat = 0.0
    @State private var iconOpacity: Double = 0.0
    @State private var textOpacity: Double = 0.0
    @State private var ringProgress: CGFloat = 0.0

    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)      // #5B6CF7

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Animated icon circle
            ZStack {
                Circle()
                    .stroke(accentBlue.opacity(0.15), lineWidth: 2 * scale)
                    .frame(width: 30 * scale, height: 30 * scale)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(accentBlue, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .frame(width: 30 * scale, height: 30 * scale)
                    .rotationEffect(.degrees(-90))

                Image(systemName: "mic.fill")
                    .font(.system(size: 13 * scale, weight: .bold))
                    .foregroundColor(accentBlue)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }

            // Text content
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("Hands-Free Mode")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                HStack(spacing: 4 * scale) {
                    Text("Press")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))

                    Text("Fn")
                        .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 5 * scale)
                        .padding(.vertical, 2 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: 4 * scale)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4 * scale)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )

                    Text("to stop")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .opacity(textOpacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                ringProgress = 1.0
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.3)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) {
                textOpacity = 1.0
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        OverlayView()
        ClipboardToastIndicator()
        HandsFreeToastContent()
    }
    .padding(40)
    .background(Color.black)
}

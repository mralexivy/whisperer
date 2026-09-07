//
//  MeetingProcessingBanner.swift
//  Whisperer
//
//  Post-recording progress strip: shows what the AI pass is doing between
//  "stopped" and "overview ready".
//

import SwiftUI

struct MeetingProcessingBanner: View {
    let phase: MeetingProcessingPhase
    /// 0…1 when the phase knows how much is left, nil when it doesn't. Only the polish pass
    /// does: it counts batches. The LLM phases stay indeterminate — on-device latency varies
    /// far too much for a percentage to be anything but a lie.
    var progress: Double? = nil
    /// Optional short notice shown below the phase label. Non-nil when a stage was skipped
    /// or a condition worth surfacing to the user applies (e.g. "Cleanup skipped — model not
    /// downloaded"). Nil = no row rendered.
    var notice: String? = nil

    @State private var slide = false
    @State private var breathe = false

    private let accent = Color(hex: "5B6CF7")
    private let purple = Color(hex: "8B5CF6")

    /// Display order — also the source of the step-dot progress.
    private let allPhases: [MeetingProcessingPhase] = [.finalizing, .fineTuning, .naming, .summarizing]

    private var stepIndex: Int {
        allPhases.firstIndex(of: phase) ?? 0
    }

    var body: some View {
        HStack(spacing: 13) {
            orb

            VStack(alignment: .leading, spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    // Variant 1: full label fits — prefer it.
                    Text(phase.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .contentTransition(.opacity)
                        .lineLimit(1)
                        .fixedSize()

                    // Variant 2: short label fits without truncation.
                    Text(phase.shortLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .contentTransition(.opacity)
                        .lineLimit(1)
                        .fixedSize()

                    // Variant 3: short label with ellipsis — always fits.
                    Text(phase.shortLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .contentTransition(.opacity)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let notice {
                    Text(notice)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                track
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            stepDots
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .help(phase.label)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.10), purple.opacity(0.05), Color(hex: "0C0C1A")],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                slide = true
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    // MARK: - Orb

    private var orb: some View {
        ZStack {
            // Halo — breathes rather than spins so it reads as "thinking", not "loading".
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.35), .clear],
                        center: .center, startRadius: 2, endRadius: 22
                    )
                )
                .frame(width: 44, height: 44)
                .scaleEffect(breathe ? 1.15 : 0.85)
                .opacity(breathe ? 0.9 : 0.45)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent, purple],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 26, height: 26)
                .shadow(color: accent.opacity(0.45), radius: 8, y: 2)

            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: 30, height: 30)
    }

    // MARK: - Track

    private var track: some View {
        let maxRailWidth: CGFloat = 168
        let segmentWidth: CGFloat = 58

        return GeometryReader { geo in
            let railW = geo.size.width
            Capsule()
                .fill(Color.white.opacity(0.07))
                .overlay(alignment: .leading) {
                    if let progress {
                        // Determinate: batch count is genuinely known during the polish pass.
                        // A minimum width keeps the fill visible at 0% so the bar never looks dead.
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [accent, purple],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: max(6, railW * min(max(progress, 0), 1)), height: 3)
                            .animation(.easeInOut(duration: 0.35), value: progress)
                    } else {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0), accent, purple, purple.opacity(0)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: segmentWidth, height: 3)
                            .offset(x: slide ? railW : -segmentWidth)
                    }
                }
                .clipShape(Capsule())
        }
        .frame(maxWidth: maxRailWidth, minHeight: 3, maxHeight: 3)
    }

    // MARK: - Step dots

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(allPhases.enumerated()), id: \.offset) { index, _ in
                Circle()
                    .fill(index <= stepIndex ? accent : Color.white.opacity(0.14))
                    .frame(width: 5, height: 5)
                    .scaleEffect(index == stepIndex && breathe ? 1.5 : 1.0)
            }
        }
    }
}

// MARK: - Compact chip for the detail header line

/// Inline processing indicator that lives in the existing header metadata line so that
/// nothing below ever shifts when a phase starts or ends.
///
/// Uses `ViewThatFits` to degrade gracefully at narrow widths:
///   full chip → orb + label only → orb only
struct MeetingProcessingChip: View {
    let phase: MeetingProcessingPhase
    /// 0…1 when progress is known (polish pass), nil otherwise.
    var progress: Double? = nil

    @State private var breathe = false
    @State private var slide = false

    private let accent = Color(hex: "5B6CF7")
    private let purple = Color(hex: "8B5CF6")

    private let railWidth: CGFloat = 52
    private let segmentWidth: CGFloat = 20

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullChip
            labelChip
            orbOnly
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                slide = true
            }
        }
        .help(phase.label)
    }

    // All three variants — ViewThatFits tries them in order.

    private var fullChip: some View {
        HStack(spacing: 5) {
            dot
            Text(phase.shortLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
                .contentTransition(.opacity)
                .fixedSize()
            miniTrack
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.10)))
        .overlay(Capsule().stroke(accent.opacity(0.20), lineWidth: 0.5))
    }

    private var labelChip: some View {
        HStack(spacing: 5) {
            dot
            Text(phase.shortLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
                .contentTransition(.opacity)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.10)))
        .overlay(Capsule().stroke(accent.opacity(0.20), lineWidth: 0.5))
    }

    private var orbOnly: some View {
        dot
            .padding(4)
            .background(Circle().fill(accent.opacity(0.10)))
    }

    private var dot: some View {
        Circle()
            .fill(LinearGradient(colors: [accent, purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 6, height: 6)
            .scaleEffect(breathe ? 1.3 : 0.8)
            .opacity(breathe ? 1.0 : 0.5)
    }

    private var miniTrack: some View {
        Capsule()
            .fill(Color.white.opacity(0.07))
            .frame(width: railWidth, height: 2)
            .overlay(alignment: .leading) {
                if let progress {
                    Capsule()
                        .fill(LinearGradient(colors: [accent, purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, railWidth * min(max(progress, 0), 1)), height: 2)
                        .animation(.easeInOut(duration: 0.35), value: progress)
                } else {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [accent.opacity(0), accent, purple.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: segmentWidth, height: 2)
                        .offset(x: slide ? railWidth : -segmentWidth)
                }
            }
            .clipShape(Capsule())
    }
}

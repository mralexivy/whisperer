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

    @State private var slide = false
    @State private var breathe = false

    private let accent = Color(hex: "5B6CF7")
    private let purple = Color(hex: "8B5CF6")

    /// Display order — also the source of the step-dot progress.
    private let allPhases: [MeetingProcessingPhase] = [.finalizing, .naming, .summarizing]

    private var stepIndex: Int {
        allPhases.firstIndex(of: phase) ?? 0
    }

    var body: some View {
        HStack(spacing: 13) {
            orb

            VStack(alignment: .leading, spacing: 7) {
                Text(phase.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .contentTransition(.opacity)

                track
            }

            Spacer(minLength: 12)

            stepDots
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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

    // MARK: - Indeterminate track

    /// A gradient segment sweeping a fixed-width rail. Indeterminate on purpose — on-device
    /// LLM latency varies far too much for a percentage to be anything but a lie.
    private var track: some View {
        let railWidth: CGFloat = 168
        let segmentWidth: CGFloat = 58

        return Capsule()
            .fill(Color.white.opacity(0.07))
            .frame(width: railWidth, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0), accent, purple, purple.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: segmentWidth, height: 3)
                    .offset(x: slide ? railWidth : -segmentWidth)
            }
            .clipShape(Capsule())
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

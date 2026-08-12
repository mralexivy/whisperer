//
//  MeetingPrepView.swift
//  Whisperer
//
//  Full-window engine preparation screen shown when MeetingEngines.needsPreparation is true.
//  Displays download/warm progress for all four meeting engines and gives the user an escape hatch.
//

#if canImport(FluidAudio)
import SwiftUI

struct MeetingPrepView: View {
    @Binding var continueAnyway: Bool
    @ObservedObject private var engines = MeetingEngines.shared

    @State private var pulse = false
    @State private var breathe = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent = Color(hex: "5B6CF7")
    private let purple = Color(hex: "8B5CF6")

    // MARK: - Derived state

    private var speechReady: Bool {
        if case .ready = engines.readiness[.speech] ?? .needsDownload("") { return true }
        return false
    }

    private var speakersReady: Bool {
        if case .ready = engines.readiness[.speakers] ?? .needsDownload("") { return true }
        return false
    }

    private var coreReady: Bool { speechReady && speakersReady }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack {
                VStack(spacing: 32) {
                    sonarHero
                        .padding(.top, 8)

                    headlines

                    engineRows

                    progressSection

                    footer

                    ctaSection
                        .padding(.bottom, 16)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 48)
                .frame(maxWidth: 540)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0C0C1A"))
        .onAppear {
            if !reduceMotion {
                pulse = true
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            engines.prefetch()
        }
    }

    // MARK: - Sonar hero

    private var sonarHero: some View {
        ZStack {
            if reduceMotion {
                // Static gradient disc — no animation
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.25), purple.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
            } else {
                // Three expanding sonar rings
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.55),
                                    purple.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .frame(width: 86, height: 86)
                        .scaleEffect(pulse ? 3.0 : 1.0)
                        .opacity(pulse ? 0 : 0.75)
                        .animation(
                            .easeOut(duration: 2.5)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.82),
                            value: pulse
                        )
                }
            }

            // Center gradient circle with sparkles icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent, purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 74, height: 74)
                    .shadow(color: accent.opacity(0.55), radius: 24, y: 6)

                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 230, height: 230)
    }

    // MARK: - Headlines

    private var headlines: some View {
        VStack(spacing: 10) {
            Text("Getting things ready for meetings")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text("Whisperer prepares everything on your Mac so meeting notes are ready the moment you stop recording. Nothing is uploaded.")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    // MARK: - Engine rows

    private var engineRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(MeetingEngine.allCases.enumerated()), id: \.offset) { index, engine in
                engineRow(engine)
                if index < MeetingEngine.allCases.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                }
            }
        }
        .background(Color(hex: "14142B"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func engineRow(_ engine: MeetingEngine) -> some View {
        let readiness = engines.readiness[engine] ?? .needsDownload("")
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.roleLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(engine.roleDescription)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }

            Spacer(minLength: 12)

            stateIndicator(for: readiness, engine: engine)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private func stateIndicator(for readiness: EngineReadiness, engine: MeetingEngine) -> some View {
        switch readiness {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(accent)

        case .downloading(let progress):
            HStack(spacing: 6) {
                breathingOrb
                Text(downloadLabel(progress: progress, engine: engine))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }

        case .preparing:
            HStack(spacing: 6) {
                breathingOrb
                Text("Preparing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

        case .needsDownload, .unavailable:
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 8, height: 8)
        }
    }

    /// Breathing orb reused from MeetingProcessingBanner, scaled to 20 pt.
    private var breathingOrb: some View {
        ZStack {
            // Halo — breathes rather than spins so it reads as "thinking".
            // Skipped when reduceMotion is on (static disc instead).
            if !reduceMotion {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.35), .clear],
                            center: .center, startRadius: 2, endRadius: 14
                        )
                    )
                    .frame(width: 20, height: 20)
                    .scaleEffect(breathe ? 1.15 : 0.85)
                    .opacity(breathe ? 0.9 : 0.45)
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent, purple],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 12, height: 12)
                .shadow(color: accent.opacity(0.45), radius: 4, y: 1)
        }
        .frame(width: 20, height: 20)
    }

    private func downloadLabel(progress: Double, engine: MeetingEngine) -> String {
        let downloadedBytes = progress * engine.downloadBytes
        if downloadedBytes < 1_000_000_000 {
            return "\(Int(downloadedBytes / 1_000_000)) MB of \(engine.downloadSizeLabel)"
        } else {
            return String(format: "%.1f GB of %@", downloadedBytes / 1_000_000_000, engine.downloadSizeLabel)
        }
    }

    // MARK: - Progress rail

    private var progressSection: some View {
        let progress = engines.overallProgress
        let pct = Int(progress * 100)

        return VStack(alignment: .leading, spacing: 8) {
            Text("\(pct)% complete")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            GeometryReader { geo in
                let railWidth = geo.size.width
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [accent, purple],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(
                                width: max(6, railWidth * min(max(progress, 0), 1)),
                                height: 5
                            )
                            .animation(.easeInOut(duration: 0.35), value: progress)
                    }
                    .clipShape(Capsule())
            }
            .frame(height: 5)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let pendingBytes = MeetingEngine.allCases.reduce(0.0) { acc, engine in
            if case .ready = engines.readiness[engine] ?? .needsDownload("") { return acc }
            return acc + engine.downloadBytes
        }

        let sizeLabel: String
        if pendingBytes <= 0 {
            sizeLabel = ""
        } else if pendingBytes < 1_000_000_000 {
            sizeLabel = "\(Int(pendingBytes / 1_000_000)) MB"
        } else {
            sizeLabel = String(format: "%.1f GB", pendingBytes / 1_000_000_000)
        }

        return VStack(spacing: 5) {
            if !sizeLabel.isEmpty {
                Text("~\(sizeLabel) remaining to download")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
            Text("All processing happens on your Mac.")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    // MARK: - CTA section

    private var ctaSection: some View {
        VStack(spacing: 14) {
            // Primary CTA — enabled only when speech + speakers are ready.
            Button {
                continueAnyway = true
            } label: {
                Text("Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(coreReady ? .white : .white.opacity(0.35))
                    .padding(.horizontal, 36)
                    .padding(.vertical, 13)
                    .background(
                        Group {
                            if coreReady {
                                AnyView(
                                    LinearGradient(
                                        colors: [accent, purple],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                            } else {
                                AnyView(Color.white.opacity(0.07))
                            }
                        }
                    )
                    .clipShape(Capsule())
                    .shadow(
                        color: coreReady ? accent.opacity(0.35) : .clear,
                        radius: 14, y: 5
                    )
            }
            .buttonStyle(.plain)
            .disabled(!coreReady)

            // Escape hatch — always visible.
            Button {
                continueAnyway = true
            } label: {
                Text("Continue anyway")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }
}
#endif

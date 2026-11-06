//
//  TranscriptPolishBar.swift
//  Whisperer
//
//  Sits at the trailing end of the meeting's tab bar while the Transcript tab is open and
//  says, in one control, what the chosen AI can do with this transcript:
//   • no AI chosen   → "Polish with AI" (opens the LLM page)
//   • ready          → [icon] Polish
//   • running        → [icon] ChatGPT · Polishing… 2 of 5, with a moving sheen + cancel
//   • polished       → [icon] ChatGPT ✓ + Undo
//   • failed         → the reason + Try again
//

import SwiftUI

struct TranscriptPolishBar: View {
    let meetingID: UUID
    let segments: [MeetingSegment]
    var testScope: String = ""

    @ObservedObject private var store = ConnectedAIStore.shared
    @ObservedObject private var polish = TranscriptPolishController.shared
    @State private var sheen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var provider: AIProviderID? { store.activeProviderID }
    private var phase: TranscriptPolishController.Phase { polish.phase(for: meetingID) }
    private var polishedBy: MeetingAIProvenance? {
        segments.contains { $0.isPolished } ? polish.provenance(for: meetingID) : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .running(let done, let total):
                runningPill(done: done, total: total)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "EF4444").opacity(0.9))
                    .lineLimit(1)
                actionButton(title: "Try again", icon: "arrow.clockwise", prominent: false) { start() }
            default:
                if let polishedBy {
                    polishedPill(polishedBy)
                    actionButton(title: "Undo", icon: "arrow.uturn.backward", prominent: false) {
                        Task { await polish.undo(meetingID: meetingID, segments: segments) }
                    }
                    .uiTestFrame("polish.undo")
                } else {
                    actionButton(title: provider == nil ? "Polish with AI" : "Polish",
                                 icon: "sparkles", prominent: true) {
                        if provider == nil {
                            NotificationCenter.default.post(name: .switchToLLMTab, object: nil)
                        } else {
                            start()
                        }
                    }
                    .help(provider == nil
                          ? "Choose an AI on the LLM page to clean up this transcript"
                          : "Fix misheard words, punctuation and fillers with \(provider!.displayName). The original is kept.")
                    .uiTestFrame("polish.start")
                }
            }
        }
        .environment(\.uiTestScope, testScope)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: phase)
    }

    private func start() {
        let language = MeetingAIService.dominantLanguage(of: segments)
        polish.start(meetingID: meetingID, segments: segments,
                     languageName: language == .auto ? nil : language.displayName)
    }

    // MARK: Pieces

    private func runningPill(done: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            ProviderMark(provider: polish.providerID, size: 14)
            Text(polish.providerID?.badgeName ?? "AI")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("Polishing…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            if total > 1 {
                Text("\(done) of \(total)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .contentTransition(.numericText())
            }
            Button { polish.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Stop")
            .uiTestFrame("polish.cancel")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            Capsule().fill(Color(hex: "8B5CF6").opacity(0.14))
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.18), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.4)
                            .offset(x: sheen ? geo.size.width : -geo.size.width * 0.4)
                    }
                    .clipShape(Capsule())
                    .opacity(reduceMotion ? 0 : 1)
                )
        )
        .overlay(Capsule().stroke(Color(hex: "8B5CF6").opacity(0.35), lineWidth: 1))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sheen = true }
        }
        .onDisappear { sheen = false }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func polishedPill(_ p: MeetingAIProvenance) -> some View {
        HStack(spacing: 4) {
            ProviderBadge(provider: p.provider)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "10B981"))
        }
        .help(p.model.map { "Polished with \(p.displayName) (\($0)). The original text is kept." } ?? "The original text is kept.")
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func actionButton(title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if prominent, let provider {
                    ProviderMark(provider: provider, size: 14)
                } else {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(prominent ? .white : .white.opacity(0.75))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(prominent
                    ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.white.opacity(0.08)))
            )
            .shadow(color: prominent ? Color(hex: "8B5CF6").opacity(0.3) : .clear, radius: 5, y: 1)
        }
        .buttonStyle(.plain)
    }
}

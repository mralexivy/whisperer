//
//  LivePreviewNoticeBanner.swift
//  Whisperer
//
//  Says why live text is coming from the user's engine instead of Apple dictation, and shows
//  the missing language installing. Lives in every live-text surface — the HUD, the meeting live
//  window and the workspace meeting studio — so a missing language is never an unexplained gap.
//

import SwiftUI

struct LivePreviewNoticeBanner: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        if let language = appState.livePreviewNoticeLanguage {
            let status = appState.systemLanguageStatuses[language]
            HStack(spacing: 8) {
                Image(systemName: status == .ready ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(status == .ready ? .green : Color(hex: "5B6CF7"))
                Text(message(language, status))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                if case .downloading(let fraction) = status {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "5B6CF7"))
                        .frame(width: 60)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color(hex: "14142B"))
                    .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
            )
            .fixedSize()
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.2), value: status)
        }
    }

    private func message(_ language: TranscriptionLanguage, _ status: SystemLanguageStatus?) -> String {
        switch status {
        case .ready: return "\(language.displayName) live text is ready"
        case .downloading(let fraction): return "Installing \(language.displayName) live text… \(Int(fraction * 100))%"
        default: return "Installing \(language.displayName) live text — showing your engine's text meanwhile"
        }
    }
}

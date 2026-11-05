//
//  LiveLanguageOfferCard.swift
//  Whisperer
//
//  "Speaking Russian?" — offers live text for a language the user dictates in but has not
//  configured. One tap installs Apple's on-device dictation for it; the card then shows the
//  download and confirms, so the user sees it happen rather than wondering whether it did.
//

import SwiftUI

struct LiveLanguageOfferCard: View {
    let language: TranscriptionLanguage
    @ObservedObject private var appState = AppState.shared

    @State private var appeared = false
    @State private var accepted = false
    @State private var acceptHovering = false
    @State private var dismissHovering = false

    private let accentBlue = Color(hex: "5B6CF7")
    private let accentPurple = Color(hex: "8B5CF6")

    private var status: SystemLanguageStatus? { appState.systemLanguageStatuses[language] }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [accentBlue, accentPurple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                Image(systemName: accepted && status == .ready ? "checkmark" : "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if accepted, case .downloading(let fraction) = status {
                    HStack(spacing: 6) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(accentBlue)
                            .frame(width: 110)
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .monospacedDigit()
                    }
                } else {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer(minLength: 12)

            if !accepted {
                acceptButton
                dismissButton
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, accepted ? 14 : 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "0C0C1A"))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
        .fixedSize(horizontal: true, vertical: false)
        .scaleEffect(appeared ? 1.0 : 0.94)
        .offset(y: appeared ? 0 : 16)
        .opacity(appeared ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: status)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78).delay(0.03)) { appeared = true }
        }
    }

    private var title: String {
        guard accepted else { return "Speaking \(language.displayName)?" }
        switch status {
        case .ready: return "\(language.displayName) live text is on"
        case .downloading: return "Installing \(language.displayName)…"
        default: return "Turning on \(language.displayName)…"
        }
    }

    private var subtitle: String {
        accepted ? "On-device, from Apple" : "Turn on live text — on-device, one tap"
    }

    private var acceptButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { accepted = true }
            appState.acceptLiveLanguageOffer(language)
        } label: {
            Text("Turn on")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [accentBlue, accentPurple], startPoint: .leading, endPoint: .trailing))
                        .opacity(acceptHovering ? 1.0 : 0.9)
                )
        }
        .buttonStyle(.plain)
        .onHover { acceptHovering = $0 }
    }

    private var dismissButton: some View {
        Button {
            appState.dismissLiveLanguageOffer(language)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(dismissHovering ? 0.7 : 0.3))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { dismissHovering = $0 }
        .help("Not now")
    }
}

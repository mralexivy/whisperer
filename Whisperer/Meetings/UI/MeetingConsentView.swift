//
//  MeetingConsentView.swift
//  Whisperer
//
//  Meeting recording consent modal (Guideline 2.5.14).
//  Shown once before the first meeting recording ever starts.
//

import SwiftUI

struct MeetingConsentView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                Text("Meeting Recording")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            // Consent explanation
            VStack(alignment: .leading, spacing: 12) {
                Text("Before you start recording, please note:")
                    .font(.body)
                    .foregroundStyle(.secondary)

                bulletPoint(
                    icon: "mic.fill",
                    title: "What is recorded",
                    detail: "Your microphone only. Whisperer never records system audio or other participants' audio streams."
                )

                bulletPoint(
                    icon: "folder.fill",
                    title: "Where it is stored",
                    detail: "Locally on your Mac in ~/Library/Application Support/Whisperer/Sessions/. Nothing leaves your device."
                )

                bulletPoint(
                    icon: "hand.raised.fill",
                    title: "Your responsibility",
                    detail: "You are responsible for obtaining consent from other meeting participants where required by law."
                )

                bulletPoint(
                    icon: "lock.fill",
                    title: "Privacy",
                    detail: "All transcription happens on-device. No audio or transcripts are sent to external servers."
                )
            }
            .padding(.vertical, 8)

            // Actions
            HStack(spacing: 12) {
                Button("Decline") {
                    onDecline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("I Understand") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
    }

    private func bulletPoint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
        MeetingConsentView(
            onAccept: {},
            onDecline: {}
        )
    }
    .frame(width: 800, height: 600)
}

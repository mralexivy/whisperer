//
//  RecordingKindBadge.swift
//  Whisperer
//
//  The icon that says what a recording is, at a glance: a dictation, a meeting or call, an imported file. The
//  design system's tinted icon container (colour at 15 % behind a coloured symbol), one colour per kind — the same
//  blue, cyan and purple the old Transcriptions, Meeting Notes and File Transcription pages had.
//

import SwiftUI

extension RecordingKind {
    var tint: Color {
        switch self {
        case .dictation: return WhispererColors.accentBlue
        case .meeting: return Color(hex: "06B6D4")
        case .file: return WhispererColors.accentPurple
        }
    }

    /// Three silhouettes that cannot be mistaken for one another: a microphone, a camera, a document.
    var badgeSymbol: String {
        switch self {
        case .dictation: return "mic.fill"
        case .meeting: return "video.fill"
        case .file: return "doc.text.fill"
        }
    }

    var plural: String {
        switch self {
        case .dictation: return "Dictation"
        case .meeting: return "Meeting"
        case .file: return "File"
        }
    }
}

struct RecordingKindBadge: View {
    let kind: RecordingKind
    var size: CGFloat = 36
    var selected = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [kind.tint.opacity(selected ? 0.30 : 0.22), kind.tint.opacity(selected ? 0.16 : 0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .stroke(kind.tint.opacity(selected ? 0.5 : 0.28), lineWidth: 1)
            Image(systemName: kind.badgeSymbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(kind.tint)
        }
        .frame(width: size, height: size)
        .shadow(color: kind.tint.opacity(selected ? 0.25 : 0), radius: 6, y: 1)
        .accessibilityHidden(true)
    }
}

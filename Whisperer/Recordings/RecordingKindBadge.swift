//
//  RecordingKindBadge.swift
//  Whisperer
//
//  The icon that says what a recording is, at a glance: a dictation, a meeting or call, an imported file. A
//  lit glass tile with a white glyph, one colour per kind — the same blue, cyan and purple, and the same
//  symbols, the old Transcriptions, Meeting Notes and File Transcription pages had.
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

    /// The lighter and deeper ends of the tile's gradient.
    var tileColors: (top: Color, bottom: Color) {
        switch self {
        case .dictation: return (Color(hex: "7C8BFF"), Color(hex: "4553E0"))
        case .meeting: return (Color(hex: "3DD9EE"), Color(hex: "0A8FB0"))
        case .file: return (Color(hex: "A98BFF"), Color(hex: "6D3DE0"))
        }
    }

    /// The symbols the old Transcriptions, Meeting Notes and File Transcription pages used.
    var badgeSymbol: String {
        switch self {
        case .dictation: return "waveform.and.mic"
        case .meeting: return "person.2.wave.2.fill"
        case .file: return "doc.text.magnifyingglass"
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
        let colors = kind.tileColors
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom))
            // The light catching the top edge: what makes the tile read as glass rather than a flat colour.
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0)], startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            Image(systemName: kind.badgeSymbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: colors.bottom.opacity(0.55), radius: 1.2, y: 0.8)
        }
        .frame(width: size, height: size)
        .shadow(color: colors.bottom.opacity(selected ? 0.55 : 0.32), radius: selected ? 9 : 5, y: 2)
        .opacity(selected ? 1 : 0.94)
        .accessibilityHidden(true)
    }
}

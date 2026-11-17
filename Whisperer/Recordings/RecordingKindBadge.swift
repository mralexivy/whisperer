//
//  RecordingKindBadge.swift
//  Whisperer
//
//  The icon that says what a recording is, at a glance: a dictation, a meeting or call, an imported file. A tile
//  on the navy surface with a wash and hairline of its own colour and a glyph in that colour, one colour per kind, all three
//  from the design system's palette (DESIGN.md): the brand blue-to-purple for dictation (the app icon's waveform), success
//  green for meetings, warning amber for files.
//

import SwiftUI

extension RecordingKind {
    /// The kind's colour: used for the tile, and for the word in the list row.
    var tint: Color {
        switch self {
        case .dictation: return WhispererColors.accentBlue
        case .meeting: return Color(hex: "10B981")
        case .file: return Color(hex: "F59E0B")
        }
    }

    /// The brighter end of the glyph's gradient.
    var tintLight: Color {
        switch self {
        case .dictation: return WhispererColors.accentPurple
        case .meeting: return Color(hex: "34D399")
        case .file: return Color(hex: "FBBF24")
        }
    }

    /// A waveform (the app's own mark), two people, a document.
    var badgeSymbol: String {
        switch self {
        case .dictation: return "waveform"
        case .meeting: return "person.2.fill"
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
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(Color(hex: "14142B"))
            shape.fill(LinearGradient(colors: [kind.tint.opacity(selected ? 0.30 : 0.22), kind.tint.opacity(0.05)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.stroke(LinearGradient(colors: [kind.tint.opacity(selected ? 0.75 : 0.45), kind.tint.opacity(0.12)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            Image(systemName: kind.badgeSymbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [kind.tintLight, kind.tint], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .frame(width: size, height: size)
        .shadow(color: kind.tint.opacity(selected ? 0.28 : 0), radius: 7, y: 1)
        .accessibilityHidden(true)
    }
}

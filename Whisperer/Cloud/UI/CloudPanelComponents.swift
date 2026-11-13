//
//  CloudPanelComponents.swift
//  Whisperer
//
//  Small pieces of the Cloud panel in the house style (DESIGN.md): one gradient primary button, secondary
//  buttons on the elevated surface, tinted icon tiles, status pills, the Apple-style usage bar. Every
//  button carries a `.uiTestFrame` id so click tests send real mouse events.
//

import SwiftUI

enum CloudTone {
    case neutral, good, warning, bad, accent

    var color: Color {
        switch self {
        case .neutral: return Color.white.opacity(0.55)
        case .good: return Color(hex: "10B981")
        case .warning: return Color(hex: "F59E0B")
        case .bad: return Color(hex: "EF4444")
        case .accent: return WhispererColors.accentBlue
        }
    }
}

/// Dot + text in a tinted capsule.
struct CloudPill: View {
    let text: String
    var tone: CloudTone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundColor(tone.color)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(tone.color.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

struct CloudIconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15)).frame(width: size, height: size)
            Image(systemName: icon).font(.system(size: size * 0.43, weight: .semibold)).foregroundColor(color)
        }
        .accessibilityHidden(true)
    }
}

/// An elevated, rounded container (the house "row" surface) with the resting shadow.
struct CloudBlock<Content: View>: View {
    let colorScheme: ColorScheme
    var padding: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
            .shadow(color: Color.black.opacity(0.05), radius: 4, y: 1)
    }
}

struct CloudSectionLabel: View {
    let text: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundColor(Color.white.opacity(0.5))
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Buttons

/// The one gradient button of a screen.
struct CloudPrimaryButton: View {
    let title: String
    var icon: String?
    let id: String
    var enabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(WhispererColors.accentGradient).opacity(enabled ? 1 : 0.4))
            .shadow(color: WhispererColors.accentPurple.opacity(enabled ? (hovered ? 0.45 : 0.2) : 0), radius: hovered ? 8 : 4, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnHover().disabled(!enabled)
        .onHover { hovered = $0 }
        .uiTestFrame(id)
        .accessibilityIdentifier(id)
    }
}

struct CloudSecondaryButton: View {
    let colorScheme: ColorScheme
    let title: String
    var icon: String?
    let id: String
    var enabled = true
    var tint: Color?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(tint ?? .white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(WhispererColors.elevatedBackground(colorScheme).opacity(hovered && enabled ? 1 : 0.8)))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnHover().disabled(!enabled)
        .onHover { hovered = $0 }
        .uiTestFrame(id)
        .accessibilityIdentifier(id)
    }
}

/// A text-only action in the accent colour.
struct CloudLinkButton: View {
    let title: String
    let id: String
    var enabled = true
    var tone: CloudTone = .accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(tone.color)
                .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerOnHover().disabled(!enabled).opacity(enabled ? 1 : 0.45)
        .uiTestFrame(id)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Messages

struct CloudNotice: View {
    let text: String
    var tone: CloudTone = .neutral
    var icon: String?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon ?? defaultIcon).font(.system(size: 12, weight: .semibold)).foregroundColor(tone.color)
                .padding(.top, 1).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tone.color.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }

    private var defaultIcon: String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .bad: return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }
}

// MARK: - Usage bar

/// The capsule bar of System Settings' storage view (StorageUsageSection), for one value against its limit.
struct CloudUsageBar: View {
    let fraction: Double
    var tone: CloudTone = .accent
    var height: CGFloat = 14
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var colors: [Color] {
        switch tone {
        case .warning: return [Color(hex: "F59E0B"), Color(hex: "F59E0B").opacity(0.8)]
        case .bad: return [Color(hex: "EF4444"), Color(hex: "EF4444").opacity(0.8)]
        default: return [WhispererColors.accentBlue, WhispererColors.accentPurple]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(fraction > 0 ? height : 0, proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: drawn ? width : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.84), value: drawn)
            }
        }
        .frame(height: height)
        .onAppear { drawn = true }
        .accessibilityHidden(true)
    }
}

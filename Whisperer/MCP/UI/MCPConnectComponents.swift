//
//  MCPConnectComponents.swift
//  Whisperer
//
//  Small building blocks of the MCP Connect page: client icons, the morphing copy button,
//  code blocks, the pulsing status dot, the drawn-in success check, icon tiles and buttons.
//  Every animation here checks Reduce Motion.
//

import SwiftUI

// MARK: - Palette

enum MCPPalette {
    static let success = Color(hex: "34D399")
    static let warning = Color(hex: "F59E0B")
    static let danger  = Color(hex: "F87171")
}

extension MCPClient {
    /// Per-client icon tint (colorful icons per DESIGN.md).
    var tint: Color {
        switch self {
        case .claudeCode, .claudeDesktop: return Color(hex: "DA7756")
        case .codex:       return Color(hex: "34D399")
        case .cursor:      return Color(hex: "A5B4FC")
        case .vscode:      return Color(hex: "3B9EFF")
        case .windsurf:    return Color(hex: "2DD4BF")
        case .antigravity: return Color(hex: "F59E0B")
        case .chatgpt:     return Color(hex: "10A37F")
        case .other:       return WhispererColors.accentPurple
        }
    }

    /// Short line under the name on a picker tile.
    var tileSubtitle: String {
        switch self {
        case .claudeCode:    return "Terminal & IDE"
        case .claudeDesktop: return "Desktop app"
        case .codex:         return "CLI, IDE & app"
        case .cursor:        return "AI code editor"
        case .vscode:        return "Copilot agent mode"
        case .windsurf:      return "Cascade"
        case .antigravity:   return "Agent IDE"
        case .chatgpt:       return "Custom connector"
        case .other:         return "Any MCP client"
        }
    }
}

// MARK: - Client icon

struct MCPClientIcon: View {
    let client: MCPClient
    var size: CGFloat = 36
    var glowing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [client.tint.opacity(0.26), client.tint.opacity(0.1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .stroke(client.tint.opacity(0.18), lineWidth: 1))
                .frame(width: size, height: size)
                .shadow(color: client.tint.opacity(glowing ? 0.35 : 0.08), radius: glowing ? 10 : 3, y: 1)
            Image(systemName: client.iconName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(client.tint)
        }
    }
}

// MARK: - Icon tile

struct MCPIconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(color.opacity(0.15))
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.08), radius: 3, y: 1)
            Image(systemName: icon)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundColor(color)
        }
    }
}

// MARK: - Labels and chips

struct MCPSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundColor(Color.white.opacity(0.35))
    }
}

struct MCPChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Pulsing status dot

struct MCPPulsingDot: View {
    let color: Color
    let active: Bool
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.45))
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 0.9)
                    .onAppear {
                        pulse = false
                        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
                    }
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(active ? 0.6 : 0), radius: 4)
        }
        .frame(width: size * 2.6, height: size * 2.6)
    }
}

// MARK: - Success check (drawn in)

private struct MCPCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.53))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.69))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.35))
        return p
    }
}

struct MCPSuccessCheck: View {
    var size: CGFloat = 30
    var color: Color = MCPPalette.success

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0
    @State private var tick: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.14))
            Circle()
                .trim(from: 0, to: ring)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            MCPCheckShape()
                .trim(from: 0, to: tick)
                .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.35), radius: 6)
        .onAppear {
            if reduceMotion {
                ring = 1; tick = 1
            } else {
                withAnimation(.easeOut(duration: 0.4)) { ring = 1 }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.25)) { tick = 1 }
            }
        }
    }
}

// MARK: - Copy button (morphs to "Copied")

struct MCPCopyButton: View {
    let text: String
    let copy: @MainActor (String) -> Void
    var label: String = "Copy"
    var testID: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var hovered = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            copy(text)
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied" : label)
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.opacity)
            }
            .foregroundColor(copied ? MCPPalette.success : WhispererColors.accentBlue)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill((copied ? MCPPalette.success : WhispererColors.accentBlue)
                .opacity(copied ? 0.16 : (hovered ? 0.18 : 0.1))))
            .scaleEffect(copied && !reduceMotion ? 1.04 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovered = h } }
        .help("Copy to clipboard")
        .modifier(OptionalTestFrame(id: testID))
        .onDisappear { resetTask?.cancel() }
    }
}

struct OptionalTestFrame: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.uiTestFrame(id) } else { content }
    }
}

// MARK: - Code block

struct MCPCodeBlock: View {
    let title: String
    let code: String
    let copy: @MainActor (String) -> Void
    var copyTestID: String? = nil
    var textTestID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MCPSectionLabel(text: title)
                Spacer()
                MCPCopyButton(text: code, copy: { copy($0) }, testID: copyTestID)
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
            .background(Color.white.opacity(0.03))

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.88))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .modifier(OptionalTestFrame(id: textTestID))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WhispererColors.background(.dark))
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.07), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 4, y: 1)
    }
}

// MARK: - Buttons

/// Gradient CTA — the one primary action of a section.
struct MCPPrimaryButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        MCPPrimaryButtonBody(configuration: configuration, large: large)
    }
}

private struct MCPPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let large: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, large ? 18 : 12)
            .padding(.vertical, large ? 9 : 6)
            .background(
                RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
                    .fill(WhispererColors.accentGradient)
                    .overlay(RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
                        .fill(Color.white.opacity(hovered ? 0.08 : 0)))
            )
            .shadow(color: WhispererColors.accentBlue.opacity(hovered ? 0.4 : 0.22),
                    radius: hovered ? 10 : 5, y: hovered ? 3 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : (hovered ? 1.015 : 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hovered = h && isEnabled } }
            .pointerOnHover()
    }
}

struct MCPSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MCPSecondaryButtonBody(configuration: configuration)
    }
}

private struct MCPSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color.white.opacity(hovered ? 0.95 : 0.8))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.12 : (hovered ? 0.09 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(hovered ? 0.12 : 0.07), lineWidth: 1)))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovered = h && isEnabled } }
    }
}

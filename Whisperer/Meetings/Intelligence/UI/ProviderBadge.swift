//
//  ProviderBadge.swift
//  Whisperer
//
//  One recognisable mark per AI, everywhere a meeting says which AI did something: the
//  overview, Ask AI, transcript polish, the meeting list and the LLM page.
//
//  The mark is the AI's real icon, taken from the app the user already has installed —
//  ChatGPT.app (ChatGPT, OpenAI API, and its bundled Codex icon), Claude.app (Claude Code,
//  Anthropic API), Antigravity.app / Gemini.app (Antigravity, Gemini API). Nothing is bundled;
//  when the app isn't installed the badge falls back to a vendor-colored glyph.
//
//  Labels are only the name ("ChatGPT"), never "by …" / "Answers by …" / "Powered by …":
//  the icon and name say it, the tooltip explains it.
//

import AppKit
import SwiftUI

extension AIProviderID {
    /// Vendor color: Anthropic orange, OpenAI green, Google blue.
    var brandColor: Color {
        switch self {
        case .claudeCode, .anthropicKey:   return Color(hex: "D97757")
        case .codex, .chatGPT, .openAIKey: return Color(hex: "10A37F")
        case .antigravity, .geminiKey:     return Color(hex: "4285F4")
        }
    }

    /// The name shown next to the icon.
    var badgeName: String {
        switch self {
        case .claudeCode:   return "Claude Code"
        case .anthropicKey: return "Claude"
        case .codex:        return "Codex"
        case .chatGPT, .openAIKey: return "ChatGPT"
        case .antigravity:  return "Antigravity"
        case .geminiKey:    return "Gemini"
        }
    }

    /// Fallback glyph when the vendor's app isn't installed.
    var badgeGlyph: String {
        switch self {
        case .claudeCode, .anthropicKey:   return "asterisk"
        case .codex:                       return "chevron.left.forwardslash.chevron.right"
        case .chatGPT, .openAIKey:         return "circle.hexagongrid.fill"
        case .antigravity, .geminiKey:     return "sparkle"
        }
    }

    /// Where the real icon comes from, in preference order: image files first, then apps.
    var iconSources: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func apps(_ names: [String]) -> [String] {
            names.flatMap { ["/Applications/\($0).app", "\(home)/Applications/\($0).app"] }
        }
        switch self {
        case .codex:
            return ["/Applications/ChatGPT.app/Contents/Resources/icon-codex-dark-color.png"]
                + apps(["Codex", "ChatGPT"])
        case .chatGPT, .openAIKey:
            return ["/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.icns"] + apps(["ChatGPT"])
        case .claudeCode, .anthropicKey:
            return apps(["Claude"])
        case .antigravity:
            return apps(["Antigravity", "Gemini"])
        case .geminiKey:
            return apps(["Gemini", "Antigravity"])
        }
    }
}

/// Real vendor icons, loaded once from the user's installed apps.
@MainActor
enum ProviderIcons {
    private static var cache: [AIProviderID: NSImage?] = [:]

    static func image(for provider: AIProviderID) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let fm = FileManager.default
        var found: NSImage?
        for path in provider.iconSources where fm.fileExists(atPath: path) {
            if path.hasSuffix(".app") {
                found = NSWorkspace.shared.icon(forFile: path)
            } else {
                found = NSImage(contentsOfFile: path)
            }
            if found != nil { break }
        }
        cache[provider] = found
        return found
    }

    /// For tests: forget what was loaded.
    static func reset() { cache.removeAll() }
}

/// The AI's icon. `nil` provider means this Mac.
struct ProviderMark: View {
    let provider: AIProviderID?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let provider, let image = ProviderIcons.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(LinearGradient(colors: [color, color.opacity(0.75)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: provider?.badgeGlyph ?? "desktopcomputer")
                        .font(.system(size: size * 0.52, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.3), radius: size * 0.12, y: 1)
        .accessibilityLabel(provider?.badgeName ?? "This Mac")
    }

    private var color: Color { provider?.brandColor ?? Color(hex: "06B6D4") }
}

/// Icon + name in a capsule: [icon] ChatGPT. The tooltip says what the AI did.
struct ProviderBadge: View {
    let provider: AIProviderID?
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            ProviderMark(provider: provider, size: compact ? 14 : 16)
            Text(provider?.badgeName ?? "This Mac")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .background(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
    }

    private var color: Color { provider?.brandColor ?? Color(hex: "06B6D4") }
}

//
//  IslandHoverButton.swift
//  Whisperer
//
//  Atoll-HoverButton equivalent. A 30 or 40 pt button that:
//    • Shows a hover capsule fill (.white.opacity(0.14)) on mouse-over
//    • Scales 0.92 on press (.easeOut 70 ms)
//    • Swaps SF Symbol glyphs with .contentTransition(.symbolEffect(.replace))
//    • Shows an optional text label below the glyph
//
//  Usage:
//    IslandHoverButton(icon: "pause.fill", label: "Pause", scale: .small) {
//        coordinator.send(...)
//    }
//

import SwiftUI

struct IslandHoverButton: View {
    var icon: String
    var label: String? = nil
    var scale: Scale = .small
    /// Overrides `scale`. Inline controls inside the compact strip must be sized to the notch
    /// height (Atoll `inlineStopButtonSize`), which is 32 pt on a 14" MacBook — a fixed 30 pt
    /// button plus padding does not fit.
    var diameter: CGFloat? = nil
    var iconColor: Color = IslandHoverButton.defaultColor
    /// Colour the glyph animates to under the pointer. Set this when `iconColor` is
    /// deliberately faint at rest, so the button still confirms it is live on hover.
    var hoverIconColor: Color? = nil
    /// Hover capsule fill. The default translucent white reads correctly over the frosted
    /// recording strip, but on the launcher's solid black it greys out into a haze — pass a
    /// solid graphite there so the button still looks carved from the same black.
    var hoverFill: Color = Color.white.opacity(0.14)
    /// Renders the button the way `OverlayView` renders its HUD controls: a circle tinted with
    /// the glyph's own colour (0.15 at rest, 0.25 under the pointer), plus a matching ring and
    /// glow on hover. Without this the glyph floats bare and the colour reads as an accident
    /// rather than as a deliberate per-control identity.
    var tinted: Bool = false
    var action: () -> Void

    enum Scale { case small, large }

    static let defaultColor = Color(red: 0.961, green: 0.961, blue: 0.969) // #F5F5F7

    @State private var isHovering = false

    private var size: CGFloat { diameter ?? (scale == .large ? 40 : 30) }
    private var iconSize: CGFloat { max(size * 0.5, 11) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    if tinted {
                        // Nothing at rest — the glyph sits directly on the Island's own surface.
                        // The tinted disc is purely a hover response.
                        Circle()
                            .fill(iconColor.opacity(isHovering ? 0.25 : 0))
                            .frame(width: size, height: size)
                        Circle()
                            .strokeBorder(iconColor.opacity(isHovering ? 0.30 : 0),
                                          lineWidth: 1.5)
                            .frame(width: size, height: size)
                    } else {
                        Capsule()
                            .fill(isHovering ? hoverFill : Color.clear)
                            .frame(width: size, height: size)
                    }

                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundColor(isHovering ? (hoverIconColor ?? iconColor) : iconColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: size, height: size)
                .shadow(color: tinted && isHovering ? iconColor.opacity(0.20) : .clear,
                        radius: 6, y: 2)

                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(red: 0.631, green: 0.631, blue: 0.671)) // #A1A1AA
                }
            }
            // Explicit hit shape — the hover capsule is transparent at rest, and a label
            // narrower than the glyph would otherwise shrink the tappable area.
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandHoverButtonStyle())
        .onHover { hovering in
            withAnimation(.bouncy.speed(1.2)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(label ?? icon)
    }
}

// MARK: - Press style

private struct IslandHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

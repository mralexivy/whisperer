---
name: design-colors
description: Use when working with colors, theming, dark mode, or color-related styling in Whisperer UI. Covers WhispererColors palette, dark mode philosophy, gradient patterns, accent usage per surface, and the Color(hex:) extension.
---

# Whisperer Color System

## Core Principle

Every UI surface uses `WhispererColors` — never system semantic colors (`NSColor.windowBackgroundColor`, `.controlBackgroundColor`, `.foregroundStyle(.secondary)`). The one exception is the menu bar panel (see Menu Bar Panel section).

## WhispererColors Struct

Defined in `HistoryWindowView.swift`:

```swift
struct WhispererColors {
    // Brand accent — vibrant green
    static let accent = Color(hex: "22C55E")
    static let accentDark = Color(hex: "16A34A")

    // Backgrounds (adapt to color scheme)
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "111111") : Color(hex: "F8FAFC")
    }
    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "181818") : Color.white
    }
    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "0D0D0D") : Color(hex: "FFFFFF")
    }
    static func elevatedBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "1F1F1F") : Color(hex: "F1F5F9")
    }

    // Text
    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color(hex: "0F172A")
    }
    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "B3B3B3") : Color(hex: "64748B")
    }

    // Borders
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.06)
    }
}
```

## Green Accent Variants

Different surfaces use slightly different green values:

| Surface | Green Value | Usage |
|---------|-------------|-------|
| WhispererColors | `Color(hex: "22C55E")` | Workspace window, sidebar, cards |
| OverlayView / MicButton / RecordingIndicator | `Color(red: 0.2, green: 0.78, blue: 0.35)` | HUD overlay bar |
| LiveTranscriptionCard / KeywordHighlighter | `Color(red: 0.0, green: 0.82, blue: 0.42)` (#00D26A) | Live text, keyword highlights |
| WaveformView | `Color(red: 0.2, green: 0.8, blue: 0.4)` | Waveform bars |

## Gradient vs Flat Accent Rule

- **Flat `WhispererColors.accent`** — Solid accent buttons: play button, selected filter tab, selected edit/save capsule, selected nav item background
- **Gradient `[accent, accentDark]`** — Icon containers (brand, section labels, settings headers, avatar), day label text, edit button when active, decorative separators
- **NEVER** use gradient on filter tabs or play button — these use the single flat `WhispererColors.accent`

## Dark Mode Philosophy — Spotify-Inspired

### Core Principles

1. **Deep blacks, not gray** — Backgrounds are #0D0D0D sidebar, #111111 main, #181818 cards. Immersive, not "gray dark mode."
2. **Borders are nearly invisible** — `white.opacity(0.04)`. Separation via background layering, not visible borders.
3. **Shadows are whisper-quiet** — 50-60% lower opacity than light mode. Depth comes from color layering.
4. **Secondary text is warm neutral** — `#B3B3B3` (not blue-tinted). Warm gray against deep black feels premium.
5. **Green accent pops naturally** — Keep accent opacities restrained so green feels electric, not washed out.
6. **Background layering** — sidebar (#0D0D0D) → main (#111111) → cards (#181818) → elevated (#1F1F1F). ~7 hex values apart.

### Dark Mode Shadow Values

| Context | Dark Opacity | Light Opacity |
|---------|-------------|---------------|
| Card/row rest | `0.06` | `0.03` |
| Card/row hover | `0.12` | `0.06` |
| Text field | `0.04` | `0.025` |
| Button hover | `0.08` | `0.06` |
| Selected accent glow | `0.06` | `0.08` |
| Dropdown panel | `0.35` | `0.15` |

### What NOT to Do (Dark Mode)

- DO NOT use shadow opacity above `0.15` for `Color.black` — creates gray halos
- DO NOT use same opacity for dark and light — dark needs ~50% less
- DO NOT rely on borders for separation — use background layering
- DO NOT use blue-tinted grays for secondary text — use warm #B3B3B3
- DO NOT increase accent opacities to compensate — accent pops naturally

## Color Hex Extension

Defined at the bottom of `HistoryWindowView.swift`. Supports 3, 6, and 8 character hex strings:

```swift
Color(hex: "22C55E")     // 6-char
Color(hex: "FF22C55E")   // 8-char with alpha
```

## Menu Bar Panel — Exception

The menu bar panel (`MenuBarView` in `WhispererApp.swift`) is the ONE surface that uses some system colors:

- Background: `Color(nsColor: .windowBackgroundColor)` — inherits system menu bar appearance
- Accent: `Color.accentColor` (system accent, not WhispererColors.accent)
- Info/tab backgrounds: `Color.secondary.opacity(0.05)`
- Settings cards: `Color.secondary.opacity(0.04)` with `Color.secondary.opacity(0.08)` border

The workspace window uses `WhispererColors` everywhere.

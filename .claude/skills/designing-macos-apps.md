---
name: designing-macos-apps
description: Use when designing or modifying any UI in the Whisperer macOS app. This documents the app's existing design system — colors, typography, layout patterns, and component conventions. Follow these patterns exactly to maintain visual consistency across all surfaces (workspace window, menu bar panel, overlay HUD).
---

# Whisperer Design System

## Overview

Whisperer uses a **custom design system** with its own color palette, typography scale, and component patterns. The design is purpose-built for a premium voice transcription tool — dark-themed with a vibrant green accent, explicit hex colors that adapt via `@Environment(\.colorScheme)`, and handcrafted components throughout.

**Core principle:** Every UI surface in the app shares the same visual language. The menu bar panel, workspace window, and overlay HUD all use `WhispererColors`, the same icon treatment, the same card patterns, and the same typography scale.

**Premium polish principle:** Depth is created through layered shadows, gradient fills on accent containers, and micro-interactions (hover scale + shadow lift). Every interactive element responds to hover with at least one visual change. Flat fills are reserved for solid accent buttons (play, filter selected); gradient fills are used for icon containers, brand elements, and decorative separators.

## When to Use

- Modifying any existing UI view in Whisperer
- Adding new views, cards, sections, or settings
- Creating new components or screens
- Changing colors, fonts, spacing, or layout

## WhispererColors — The Color System

All colors come from the `WhispererColors` struct defined in `HistoryWindowView.swift`. Never use system semantic colors (`NSColor.windowBackgroundColor`, `.controlBackgroundColor`, etc.) or SwiftUI `.foregroundStyle(.secondary)` — use the explicit `WhispererColors` functions instead.

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

### Green Accent Variants

Different surfaces use slightly different green values for their accent. Maintain these per-surface:

| Surface | Green Value | Usage |
|---------|-------------|-------|
| WhispererColors | `Color(hex: "22C55E")` | Workspace window, sidebar, cards |
| OverlayView / MicButton / RecordingIndicator | `Color(red: 0.2, green: 0.78, blue: 0.35)` | HUD overlay bar |
| LiveTranscriptionCard / KeywordHighlighter | `Color(red: 0.0, green: 0.82, blue: 0.42)` (#00D26A) | Live text, keyword highlights |
| WaveformView | `Color(red: 0.2, green: 0.8, blue: 0.4)` | Waveform bars |

### Gradient vs Flat Accent Rule

- **Flat `WhispererColors.accent`** — Solid accent buttons: play button, selected filter tab, selected edit/save capsule, selected nav item background
- **Gradient `[accent, accentDark]`** — Icon containers (brand, section labels, settings headers, avatar), day label text, edit button when active, decorative separators
- **NEVER** use gradient on filter tabs or play button — these use the single flat `WhispererColors.accent`

### Color Hex Extension

Colors use a custom `Color(hex:)` initializer defined at the bottom of `HistoryWindowView.swift`. It supports 3, 6, and 8 character hex strings.

## Dark Mode Philosophy — Spotify-Inspired

The dark theme is inspired by Spotify's immersive dark mode. Key principles:

### Core Dark Mode Principles

1. **Deep blacks, not gray** — Backgrounds are true deep black (#0D0D0D sidebar, #111111 main, #181818 cards). The UI should feel immersive and cinematic, not "gray dark mode."

2. **Borders are nearly invisible** — Dark mode border is `white.opacity(0.04)`. Separation comes from background color layering, not visible borders. The eye should see content, not rectangles.

3. **Shadows are whisper-quiet** — On deep black backgrounds, shadows add visual noise, not depth. Dark mode shadow opacities are 50-60% lower than light mode equivalents. Depth comes from color layering instead.

4. **Secondary text is warm neutral** — `#B3B3B3` (not blue-tinted). Warm gray reads more naturally against deep black and feels premium.

5. **Green accent pops dramatically** — Against deep black, the `#22C55E` accent needs no help. Keep accent opacities restrained in dark mode so the green feels electric, not washed out.

6. **Background layering creates depth** — The hierarchy is: sidebar (#0D0D0D, deepest) → main background (#111111) → cards (#181818) → elevated (#1F1F1F). Each step is subtle (~7 hex values apart).

### Dark Mode Shadow Values

All shadow opacities in dark mode should follow these reduced values:

| Context | Dark Mode Opacity | Light Mode Opacity | Notes |
|---------|------------------|-------------------|-------|
| Card/row rest | `0.06` | `0.03` | Nearly invisible in dark |
| Card/row hover | `0.12` | `0.06` | Subtle lift |
| Text field | `0.04` | `0.025` | Whisper-quiet |
| Button hover | `0.08` | `0.06` | Barely perceptible |
| Selected accent glow | `0.06` | `0.08` | Let accent color do the work |
| Dropdown panel | `0.35` | `0.15` | Needs some depth for overlay |

### What NOT to Do (Dark Mode)

- **DO NOT** use shadow opacities above `0.15` for `Color.black` in dark mode — it creates visible gray halos
- **DO NOT** use the same opacity values for dark and light mode shadows — dark mode needs ~50% less
- **DO NOT** rely on borders for separation — use background color layering instead
- **DO NOT** use blue-tinted grays for secondary text — use neutral warm grays (#B3B3B3)
- **DO NOT** increase accent opacities to compensate for dark backgrounds — the accent already pops naturally

## Premium Polish — Shadows & Depth

Every card and interactive element uses shadows for depth. Shadows adapt to color scheme — **subtle in light mode, whisper-quiet in dark mode** (see Dark Mode Philosophy above).

### Shadow Tiers

| Element | Shadow | Notes |
|---------|--------|-------|
| TranscriptionRow (rest) | `Color.black.opacity(dark: 0.06, light: 0.03), radius: 3, y: 1` | Subtle resting depth |
| TranscriptionRow (hover) | `Color.black.opacity(dark: 0.12, light: 0.06), radius: 6, y: 2` | Elevated on hover |
| TranscriptionRow (selected) | `accent.opacity(dark: 0.06, light: 0.08), radius: 8, y: 3` | Accent-tinted glow |
| Settings cards | `Color.black.opacity(dark: 0.06, light: 0.03), radius: 4, y: 1` | Consistent card depth |
| Audio/transcription/notes cards | `Color.black.opacity(dark: 0.06/0.04, light: 0.03/0.025), radius: 3-4, y: 1` | Subtle card depth |
| Sidebar stats card | `accent.opacity(dark: 0.08, light: 0.04), radius: 8, y: 2` | Accent-tinted |
| Search field | `Color.black.opacity(dark: 0.06, light: 0.03), radius: 3, y: 1` | Subtle depth |
| Selected filter tab | `accent.opacity(0.25), radius: 4, y: 1` | Accent glow |
| Play button (rest) | `accent.opacity(0.25), radius: 6, y: 2` | Accent glow |
| Play button (hover) | `accent.opacity(0.4), radius: 10, y: 3` | Intensified glow |
| Icon containers | `accent.opacity(0.06-0.15), radius: 2-6, y: 1-2` | Micro-shadows |
| DetailHeaderButton (hover) | `Color.black.opacity(dark: 0.08, light: 0.06), radius: 3, y: 1` | Subtle lift |
| Selected nav item | `accent.opacity(0.06), radius: 4, y: 1` | Subtle accent |

### Hover Micro-Interactions

| Element | Hover Effect |
|---------|-------------|
| TranscriptionRow | `scaleEffect(1.006)` + gradient background + deeper shadow + intensified border |
| RowActionButton | `scaleEffect(1.08)` + border ring + elevated background |
| DetailHeaderButton | `scaleEffect(1.06)` + shadow lift |
| DetailStatCard | `scaleEffect(1.02)` + shadow lift + border intensify |
| Play button | `scaleEffect(1.06)` + shadow intensify |
| SidebarNavItem | Text brightens to primaryText on hover |

## Typography — Jony Ive-Inspired Hierarchy

Whisperer uses **explicit font sizes** with `.system(size:weight:design:)`, not semantic text styles (`.body`, `.title`, etc.). The typography philosophy follows Jony Ive's Apple design principles: **lightness creates elegance, weight creates emphasis, and tracking creates breathing room.**

### Core Principles

1. **Weight contrast creates hierarchy** — Use `.light` or `.regular` for large display text (stat values, hero numbers) to feel airy and refined. Reserve `.bold` for smaller elements that need to punch through (section titles, nav items, brand name). The bigger the text, the lighter the weight.

2. **`.rounded` = warmth** — The SF Rounded variant is the app's signature. Use it for ALL titles, stat values, brand text, section headers, and any text that conveys personality. Default (non-rounded) is for functional text: body copy, form labels, metadata.

3. **Tracking = breathing room** — Uppercase labels MUST have tracking (0.5-1.2). Larger tracking values for smaller text. This prevents uppercase text from feeling cramped and adds a premium, editorial quality.

4. **Line spacing = readability** — Body text uses `.lineSpacing(4-6)` for comfortable reading. Dense metadata can use tighter spacing.

5. **Opacity for sub-hierarchy** — Within the same color (`secondaryText`), use `.opacity(0.7)` or `.opacity(0.5)` to create additional visual layers without introducing new colors.

### Weight Ladder

| Weight | Usage | Feel |
|--------|-------|------|
| `.light` | Large stat values (20pt+), hero numbers | Elegant, airy, premium |
| `.regular` | Body text, descriptions, placeholder text | Clean, readable |
| `.medium` | Nav items (unselected), form labels, metadata | Functional, clear |
| `.semibold` | Field titles, selected nav items, button text, filter tabs | Emphasized, interactive |
| `.bold` | Section titles, brand name, uppercase labels, date headers | Structural, anchoring |

### Standard Scale

| Usage | Font Specification | Notes |
|-------|-------------------|-------|
| Page/section title | `.system(size: 26, weight: .bold, design: .rounded)` | |
| Stat card value (detail) | `.system(size: 20, weight: .light, design: .rounded)` | Light weight = elegance at large sizes |
| Workspace name | `.system(size: 20, weight: .bold, design: .rounded)` | |
| Detail date header | `.system(size: 18, weight: .bold, design: .rounded)` | |
| Header stat value | `.system(size: 18, weight: .light, design: .rounded)` | Light weight for large numbers |
| Sidebar stat value | `.system(size: 16, weight: .light, design: .rounded)` | Light weight for stat numbers |
| Brand name (sidebar) | `.system(size: 15, weight: .bold, design: .rounded)` | |
| Section header | `.system(size: 15, weight: .bold, design: .rounded)` | |
| Setting label | `.system(size: 14, weight: .semibold)` | |
| Body text (transcription) | `.system(size: 14, weight: .regular)` with `.lineSpacing(5)` | Generous line spacing |
| Text preview (row) | `.system(size: 13.5, weight: .regular)` with `.lineSpacing(3)` | |
| Field title | `.system(size: 13, weight: .medium)` with `.tracking(0.3)` | Subtle tracking on form labels |
| Setting item title | `.system(size: 13, weight: .medium)` | |
| Search field | `.system(size: 13, weight: .regular)` | |
| Sidebar nav item | `.system(size: 13, weight: .medium/.semibold)` | Medium default, semibold selected |
| Row time | `.system(size: 12, weight: .bold, design: .rounded)` | |
| Row duration | `.system(size: 12, weight: .medium)` | |
| Filter tab | `.system(size: 12, weight: .semibold/.medium)` | Semibold selected, medium default |
| Subtitle / description | `.system(size: 12, weight: .regular)` | Under titles, helper text |
| Section label (detail view) | `.system(size: 11, weight: .bold, design: .rounded)` | `.tracking(0.8)`, `.uppercased()` |
| Metadata / secondary | `.system(size: 11, weight: .medium)` | |
| Date section header | `.system(size: 11, weight: .bold, design: .rounded)` | `.tracking(0.5)`, `.textCase(.uppercase)` |
| Sidebar stat label | `.system(size: 11, weight: .semibold)` | `.tracking(0.8)`, `.uppercased()` |
| Helper text (under fields) | `.system(size: 11, weight: .regular)` | `.opacity(0.7)` on secondaryText |
| Stat card label (detail) | `.system(size: 10, weight: .bold)` | `.tracking(1.0)`, `.uppercased()` |
| Category badge | `.system(size: 10, weight: .medium)` | `.tracking(0.3)` |
| Stat label / caption | `.system(size: 10, weight: .regular)` | |
| Header stat label | `.system(size: 9, weight: .semibold)` | `.tracking(0.8)` |

### Design Variants

- **`.rounded`** — Used for ALL titles, brand text, section headers, stat values, modal headers. This is the app's typographic signature — warm, approachable, premium.
- **`.monospaced`** — Used for dictionary entries (incorrect/correct forms), time format examples, keyboard shortcuts, and code-like data.
- **Default (no design)** — Used for body text, form labels, descriptions, metadata, helper text.

### Tracking Guide

| Text Size | Tracking | Usage |
|-----------|----------|-------|
| 9-10pt uppercase | `1.0-1.2` | Stat labels, tiny uppercase captions |
| 11pt uppercase | `0.5-0.8` | Section labels, date headers, sidebar labels |
| 12-13pt regular | `0.2-0.3` | Form field titles, category badges (optional) |
| 14pt+ | `0` | Body text, titles — no tracking needed at larger sizes |

### What NOT to Do (Typography)

- **DO NOT** use `.bold` for large display numbers (20pt+) — use `.light` or `.regular` for elegance
- **DO NOT** use uppercase text without tracking — it looks cramped and cheap
- **DO NOT** use `.title` / `.body` / `.caption` semantic styles — always use explicit sizes
- **DO NOT** use the same weight for everything — the weight ladder creates visual rhythm
- **DO NOT** skip `.lineSpacing()` on multi-line body text — default line spacing is too tight for premium feel
- **DO NOT** use `.rounded` for body text or metadata — reserve it for titles and stat values

## Layout Patterns

### Workspace Window (HistoryWindow + HistoryWindowView)

The workspace uses a custom `HStack(spacing: 0)` sidebar with a collapsible toggle:

```
┌──────────────────────────────────────────────────────────────┐
│ [≡]                                              (toolbar)   │
├─────────┬────────────────────────────────────────────────────┤
│ Sidebar │                                                    │
│ (220pt) │  Main Content Area                                 │
│ fixed   │  (TranscriptionsView / DictionaryView /            │
│         │   HistorySettingsView)                             │
│ Brand   │                                                    │
│ Header  │                                                    │
│         │                                                    │
│ Nav     │                                                    │
│ Items   │                                                    │
│         │                                                    │
│ Spacer  │                                                    │
│ Stats   │                                                    │
│ Card    │                                                    │
│ Shortcut│                                                    │
│ Hint    │                                                    │
└─────────┴────────────────────────────────────────────────────┘
```

- Custom `HStack(spacing: 0)` with `@State isSidebarCollapsed` toggle
- Sidebar width: **220pt** fixed (not resizable)
- 1pt `WhispererColors.border()` divider between sidebar and content
- Sidebar background: `WhispererColors.sidebarBackground()`
- Content background: `WhispererColors.background()`
- Window size: **1100x750** default, **700x700** minimum
- **NSToolbar** with `.unified` style, `titleVisibility = .hidden` — hosts the sidebar toggle button at the leading edge
- Toggle button: plain borderless `NSButton` with `sidebar.leading` icon, `isBordered = false`, targets `HistoryWindow.toggleSidebar(_:)` which posts `.toggleWorkspaceSidebar` notification
- SwiftUI view receives notification and toggles `isSidebarCollapsed` with `.spring(response: 0.3)` animation

### Header Alignment

All three panel headers (sidebar brand, main content, detail) MUST have the same fixed height:

```swift
.frame(height: 84, alignment: .center)
```

The TranscriptionsView uses a full-width background behind the header area to ensure the resizable divider gap is filled seamlessly:

```swift
.background(
    VStack(spacing: 0) {
        WhispererColors.cardBackground(colorScheme)
            .frame(height: 84)
            .overlay(alignment: .bottom) {
                Rectangle().fill(WhispererColors.border(colorScheme)).frame(height: 1)
            }
        WhispererColors.background(colorScheme)
    }
)
```

### Sidebar Structure

```swift
VStack(spacing: 0) {
    brandHeader          // Logo + "Whisperer" / "Workspace" — 84pt height
    VStack(spacing: 4) { // Nav items with 12pt horizontal padding
        ForEach(items) { SidebarNavItem(...) }
    }
    Spacer()
    sidebarStatsCard     // Stats card (recordings, words, avg WPM, days)
    shortcutHint         // "Fn + S to toggle" at bottom
}
```

**Brand Header** — Gradient icon container with shadow:
```swift
ZStack {
    RoundedRectangle(cornerRadius: 10)
        .fill(LinearGradient(
            colors: [accent.opacity(0.18), accentDark.opacity(0.08)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .frame(width: 36, height: 36)
        .shadow(color: accent.opacity(0.15), radius: 6, y: 2)
    Image(systemName: "waveform")
        .foregroundStyle(LinearGradient(
            colors: [accent, accentDark],
            startPoint: .top, endPoint: .bottom
        ))
}
```

**SidebarNavItem** — Custom component with:
- 12pt horizontal + 10pt vertical padding
- `RoundedRectangle(cornerRadius: 10)` background
- Selected: `WhispererColors.accent.opacity(0.15)` fill + `.accent.opacity(0.3)` stroke + subtle accent shadow
- Hovered: `WhispererColors.elevatedBackground()` fill, text brightens to `primaryText`
- Icon: 14pt medium weight, green when selected, secondary when not
- Text: 13pt semibold when selected, medium when not

**Sidebar Stats Card** — Diagonal gradient with gradient border and shadow:
```swift
VStack(spacing: 14) {
    sidebarStatRow(label: "RECORDINGS", value: "\(stats.totalRecordings)")
    sidebarStatRow(label: "WORDS", value: formatSidebarNumber(stats.totalWords))
    sidebarStatRow(label: "AVG WPM", value: "\(stats.averageWPM)", valueColor: WhispererColors.accent)
    sidebarStatRow(label: "DAYS", value: "\(stats.totalDays)")
}
.padding(16)
.background(
    RoundedRectangle(cornerRadius: 12)
        .fill(LinearGradient(
            colors: [
                accent.opacity(dark: 0.1, light: 0.06),
                accent.opacity(dark: 0.04, light: 0.02),
                cardBackground
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
)
.overlay(
    RoundedRectangle(cornerRadius: 12)
        .stroke(LinearGradient(
            colors: [accent.opacity(0.2), accent.opacity(0.08)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ), lineWidth: 1)
)
.shadow(color: accent.opacity(dark: 0.08, light: 0.04), radius: 8, y: 2)
// Each row: HStack { label (11pt semibold, tracking 0.8) | Spacer | value (16pt light rounded) }
```

### Transcriptions View (List + Detail)

```
┌────────────────────────────┬───┬─────────────────────┐
│  Header (welcome + stats)  │   │                     │
├────────────────────────────┤ R │  Detail Panel        │
│  Search bar                │ e │  (TranscriptionDe-   │
│  Filter capsules           │ s │   tailView)          │
├────────────────────────────┤ i │                      │
│  Grouped list              │ z │  Width: 420pt        │
│  (by date sections)        │ a │  (320-600pt range)   │
│                            │ b │                      │
│                            │ l │                      │
│                            │ e │                      │
└────────────────────────────┴───┴─────────────────────┘
```

- Left panel: min 400pt, stretches
- **ResizableDivider**: 12pt wide hit area, 1pt visible line, grip handle with 3 horizontal bars, green accent when active
- Right panel: 420pt default, 320-600pt range

### Main Content Header

The header includes a gradient separator line at the bottom:

```swift
VStack(spacing: 0) {
    HStack(spacing: 14) {
        // Avatar — gradient accent fill with shadow
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.15), accentDark.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 44, height: 44)
                .shadow(color: accent.opacity(0.1), radius: 6, y: 2)
            Text(initials)
                .foregroundStyle(LinearGradient(
                    colors: [accent, accentDark],
                    startPoint: .top, endPoint: .bottom
                ))
        }
        // Welcome text — name on top, greeting below
        VStack(alignment: .leading, spacing: 2) {
            Text(firstName)         // 20pt bold rounded, primary
            Text("Welcome back")   // 12pt, secondary
        }
        Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)

    // Gradient separator — fades at edges
    Rectangle()
        .fill(LinearGradient(
            colors: [border.opacity(0.6), border, border.opacity(0.6)],
            startPoint: .leading, endPoint: .trailing
        ))
        .frame(height: 1)
}
.background(WhispererColors.background(colorScheme))
```

No card background, no stats in header (stats are in sidebar only).

### Toolbar — Search + Filters (Two Rows)

The toolbar is a `VStack(spacing: 12)` with search on top and filters below:

```swift
VStack(spacing: 12) {
    // Row 1: Search field (full width) with shadow
    HStack(spacing: 8) { magnifyingglass + TextField + ⌘K badge }
        .background(RoundedRectangle(cornerRadius: 10).fill(elevatedBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
        .shadow(color: Color.black.opacity(dark: 0.06, light: 0.03), radius: 3, y: 1)

    // Row 2: Filter capsules (left-aligned)
    HStack(spacing: 6) {
        FilterTab(title: "All", ...)
        FilterTab(title: "Pinned", ...)
        FilterTab(title: "Flagged", ...)
        Spacer()
    }
}
.padding(.horizontal, 20)
.padding(.vertical, 14)
```

**FilterTab** — Capsule-shaped pill buttons:
- Selected: flat `WhispererColors.accent` fill (NOT gradient), white text, no border, accent glow shadow
- Unselected: transparent fill, `WhispererColors.border()` stroke, secondary text
- Hovered: `WhispererColors.elevatedBackground()` fill, text brightens to primary
- Padding: 14pt horizontal, 7pt vertical
- Font: 12pt semibold (selected) / medium (unselected)
- Shadow: `accent.opacity(0.25), radius: 4, y: 1` when selected

### TranscriptionRow

Three-line layout with full-height left accent bar, layered shadows, and hover elevation:

```swift
HStack(spacing: 0) {
    // Left accent bar — full height, no padding
    Rectangle()
        .fill(accentBarColor)    // green=selected, red=flagged, orange=pinned
        .frame(width: 3.5)
        .opacity(showAccentBar ? 1 : 0)

    // Content
    VStack(alignment: .leading, spacing: 8) {
        // Line 1: Time · Duration ... status icons + action buttons
        // Line 2: Text preview (13.5pt, 2 lines)
        // Line 3: Metadata (wpm · words · language)
    }
    .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 14)
}
```

- **Selected row background**: Subtle vertical `LinearGradient` (top-to-bottom) using `AnyShapeStyle`:
```swift
isSelected
    ? AnyShapeStyle(LinearGradient(
        colors: [accent.opacity(dark: 0.08, light: 0.05), accent.opacity(dark: 0.02, light: 0.01)],
        startPoint: .top, endPoint: .bottom
    ))
    : (isHovered
        ? AnyShapeStyle(LinearGradient(
            colors: [cardBackground, elevatedBackground.opacity(0.3)],
            startPoint: .top, endPoint: .bottom
        ))
        : AnyShapeStyle(cardBackground))
```
- Selected border: `accent.opacity(0.3)`, 1.5pt lineWidth
- Hovered border: `border.opacity(dark: 2.5, light: 1.2)` — slightly intensified
- Unselected border: `WhispererColors.border()`, 1pt lineWidth
- **Shadows**: 3-tier system (rest → hover → selected) — see Shadow Tiers table
- **Hover scale**: `scaleEffect(1.006)` when hovered and not selected
- Card clipped with `.clipShape(RoundedRectangle(cornerRadius: 12))`
- Action buttons: copy, flag, pin, more menu — 28pt circular with hover state + border ring + `scaleEffect(1.08)`

### Detail Panel (TranscriptionDetailView)

Header: date info + share/close buttons, gradient separator, background color.

**Header** includes a gradient separator with accent tint on leading edge:
```swift
VStack(spacing: 0) {
    HStack { dayLabel + dateString + buttons }
    Rectangle()
        .fill(LinearGradient(
            colors: [accent.opacity(0.2), border, border.opacity(0.3)],
            startPoint: .leading, endPoint: .trailing
        ))
        .frame(height: 1)
}
```

- Day label uses gradient foreground: `LinearGradient(colors: [accent, accentDark])`

**Panel background**: Subtle top-to-bottom accent gradient:
```swift
.background(
    LinearGradient(
        colors: [accent.opacity(dark: 0.04, light: 0.02), background],
        startPoint: .top, endPoint: .bottom
    )
)
```

Sections (24pt spacing):
1. **Audio Recording** — Section label INSIDE the card container (above waveform), plain card background, card shadow
2. **Transcription** — HighlightedText with edit toggle (capsule button). Non-editing: plain card background + shadow. Editing: accent gradient + accent border
3. **Details** — 2-column `LazyVGrid` of `DetailStatCard` with color-tinted gradients
4. **Notes** — TextEditor with placeholder, plain card background + shadow

**Important**: Content containers (audio player, transcription text, notes) use **plain card backgrounds with subtle shadows** — NOT accent gradients. Only the editing state and the overall panel background use accent tints.

**Edit/Save Button** — Capsule with accent fill when editing, elevated background when not:
```swift
// Editing: flat accent fill + accent glow shadow
.fill(isEditing ? accent : elevatedBackground)
.overlay(Capsule().stroke(isEditing ? .clear : border, lineWidth: 0.5))
.shadow(color: isEditing ? accent.opacity(0.25) : .clear, radius: 4, y: 1)
```

**DetailHeaderButton** — Circular with hover scale and shadow:
```swift
.scaleEffect(isHovered ? 1.06 : 1.0)
.shadow(color: isHovered ? Color.black.opacity(dark: 0.08, light: 0.06) : .clear, radius: 3, y: 1)
```

### DetailStatCard (2-Column Grid)

Each card uses its own `color` for gradient fill, shadow, and border — creating a color-tinted appearance:

```swift
VStack(alignment: .leading, spacing: 0) {
    // Icon in gradient circle — uses card's color
    ZStack {
        Circle()
            .fill(LinearGradient(
                colors: [color.opacity(0.12/0.12), color.opacity(0.05/0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: 36, height: 36)
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(color)
    }
    .padding(.bottom, 14)

    // Label
    Text(label)    // 10pt bold, tracking 1.0, 0.7 opacity secondary
        .padding(.bottom, 4)

    // Value
    Text(value)    // 20pt light rounded, primary
}
.padding(16)
// Color-tinted gradient background
.background(
    RoundedRectangle(cornerRadius: 14)
        .fill(LinearGradient(
            colors: [color.opacity(dark: 0.08, light: 0.04), cardBackground],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .shadow(
            color: dark ? Color.black.opacity(0.12) : color.opacity(0.08),
            radius: isHovered ? 10 : 4, y: isHovered ? 4 : 1
        )
)
// Color-tinted border
.overlay(
    RoundedRectangle(cornerRadius: 14)
        .stroke(
            isHovered ? color.opacity(dark: 0.2, light: 0.25) : color.opacity(dark: 0.08, light: 0.1),
            lineWidth: 1
        )
)
.scaleEffect(isHovered ? 1.02 : 1.0)
```

Colors per card: Duration=accent, Words=blue, WPM=purple, Language=orange, Model=cyan.

### Audio Section (AudioPlayerView)

The audio section places its section label **inside** the card container, above the waveform:

```swift
private func audioSection(url: URL) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        sectionLabel("Audio Recording", icon: "waveform")
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
        AudioPlayerView(audioURL: url, duration: transcription.duration)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
    }
    .background(RoundedRectangle(cornerRadius: 14).fill(cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(border, lineWidth: 1))
    .shadow(color: Color.black.opacity(dark: 0.06, light: 0.03), radius: 4, y: 1)
}
```

**Play button** — Flat accent fill (NOT gradient) with accent glow shadow and hover scale:
```swift
Circle()
    .fill(WhispererColors.accent)   // flat fill, NOT gradient
    .frame(width: 44, height: 44)
    .shadow(color: accent.opacity(isHovered ? 0.4 : 0.25), radius: isHovered ? 10 : 6, y: isHovered ? 3 : 2)
.scaleEffect(isHovered ? 1.06 : 1.0)
```

**Playhead** — Double shadow for luminous effect:
```swift
Circle()
    .fill(Color.white)
    .frame(width: 10, height: 10)
    .shadow(color: accent.opacity(0.5), radius: 4, y: 2)
    .shadow(color: Color.white.opacity(0.3), radius: 2, y: 0)
```

**Waveform bars** use flexible widths (no fixed `.frame(width:)`) to fill the available container:
- Sample count: 70
- Progress overlay uses `.mask()` for smooth fill
- Vertical fade mask at top/bottom edges

**Speed control** — Capsule with border:
```swift
.background(Capsule().fill(elevatedBackground))
.overlay(Capsule().stroke(border, lineWidth: 0.5))
```

### Editing State (Transcription Text)

When editing, the transcription text container uses an accent gradient + accent border to visually distinguish it:
```swift
// Editing state
.background(
    RoundedRectangle(cornerRadius: 12)
        .fill(LinearGradient(
            colors: [accent.opacity(dark: 0.06, light: 0.08), cardBackground],
            startPoint: .leading, endPoint: .trailing
        ))
)
.overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.4), lineWidth: 1.5))

// Non-editing state — plain card with subtle shadow
.background(RoundedRectangle(cornerRadius: 12).fill(cardBackground))
.overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
.shadow(color: Color.black.opacity(dark: 0.04, light: 0.025), radius: 3, y: 1)
```

### Menu Bar Panel (MenuBarView in WhispererApp.swift)

```
┌──────────────────────────┐
│  Header (gradient bg)    │
│  ┌ Icon + Status ─────┐ │
│  │ Model badge        │  │
│  └────────────────────┘  │
├──────────────────────────┤
│  Tab Bar (custom)        │
├──────────────────────────┤
│  Tab Content (scrollable)│
│                          │
│                          │
├──────────────────────────┤
│  Footer (gradient btns)  │
└──────────────────────────┘
```

- Frame: **360x580**
- Background: `Color(nsColor: .windowBackgroundColor)` — exception: this is the ONE place that uses a system color
- Header: `LinearGradient` from `Color.accentColor.opacity(0.1)` to `Color.clear`
- Tab bar: Custom `HStack` with `tabButton()` — selected tab gets `Color.accentColor.opacity(0.15)` pill background
- Tab bar background: `Color.secondary.opacity(0.05)`
- Footer: Two gradient buttons (indigo for Workspace, red for Quit) with `LinearGradient`, shadows, and keyboard shortcut badges
- **Workspace button** calls `HistoryWindowManager.shared.showWindowAndDismissMenu()` to dismiss the menu panel before opening workspace

### Overlay HUD (OverlayView + OverlayPanel)

- `NSPanel` with `[.borderless, .nonactivatingPanel]` style
- `hasShadow = false` — no window shadow
- Background: `Capsule()` with adaptive `backgroundColor` (dark: `Color(white: 0.15)`, light: `Color(white: 0.98)`)
- Stroke: `Color.gray.opacity(strokeOpacity)` (dark: 0.2, light: 0.1)
- Content pinned to bottom of panel via Auto Layout constraints
- Panel size: 420x220, positioned at bottom-center with 10pt margin

## Component Patterns

### Icon Containers

Whisperer uses **two icon container styles** depending on context. Both now use gradient fills with micro-shadows:

**Circles** — for stat card icons and header avatars:
```swift
// Stat card icon (36pt) — uses per-card color gradient
ZStack {
    Circle()
        .fill(LinearGradient(
            colors: [color.opacity(0.12/0.12), color.opacity(0.05/0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .frame(width: 36, height: 36)
    Image(systemName: icon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(color)
}

// Large icon container (44pt) — used in headers (avatar)
RoundedRectangle(cornerRadius: 12)
    .fill(LinearGradient(
        colors: [accent.opacity(0.15), accentDark.opacity(0.08)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    ))
    .frame(width: 44, height: 44)
    .shadow(color: accent.opacity(0.1), radius: 6, y: 2)
```

**Rounded squares** — for section labels and settings section headers:
```swift
// Section label icon (24pt) — detail view section labels
ZStack {
    RoundedRectangle(cornerRadius: 6)
        .fill(LinearGradient(
            colors: [accent.opacity(dark: 0.18, light: 0.12), accentDark.opacity(dark: 0.08, light: 0.05)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .frame(width: 24, height: 24)
        .shadow(color: accent.opacity(0.06), radius: 2, y: 1)
    Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(WhispererColors.accent)
}

// Settings section header icon (28pt)
ZStack {
    RoundedRectangle(cornerRadius: 7)
        .fill(LinearGradient(
            colors: [accent.opacity(dark: 0.18, light: 0.12), accentDark.opacity(dark: 0.08, light: 0.05)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .frame(width: 28, height: 28)
        .shadow(color: accent.opacity(0.08), radius: 3, y: 1)
    Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(WhispererColors.accent)
}

// Settings row icon container (36pt) — flat fill (no gradient)
RoundedRectangle(cornerRadius: 8)
    .fill(WhispererColors.accent.opacity(0.12))
    .frame(width: 36, height: 36)
```

### Cards

```swift
// Standard card container (workspace settings) — with shadow
content()
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(border, lineWidth: 1))
    .shadow(color: Color.black.opacity(dark: 0.06, light: 0.03), radius: 4, y: 1)
```

### Section Headers

```swift
// Settings section headers (SettingsSectionHeader) — gradient icon + bold title
HStack(spacing: 10) {
    ZStack {
        RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(
                colors: [accent.opacity(dark: 0.18, light: 0.12), accentDark.opacity(dark: 0.08, light: 0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: 28, height: 28)
            .shadow(color: accent.opacity(0.08), radius: 3, y: 1)
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(WhispererColors.accent)
    }
    Text(title)
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .foregroundColor(WhispererColors.primaryText(colorScheme))
}

// Date section headers (transcription list) — gradient fading line
HStack(spacing: 10) {
    Text(dateString)
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundColor(WhispererColors.secondaryText(colorScheme))
        .textCase(.uppercase)
        .tracking(0.5)
    Rectangle()
        .fill(LinearGradient(
            colors: [border, border.opacity(0.2)],
            startPoint: .leading, endPoint: .trailing
        ))
        .frame(height: 1)
}
```

### Action Buttons (Row-Level)

```swift
// Circular action button with hover state, border ring, and scale
Image(systemName: icon)
    .font(.system(size: 11, weight: .medium))
    .foregroundColor(isHovered ? primaryText : secondaryText)
    .frame(width: 28, height: 28)
    .background(Circle().fill(isHovered ? elevatedBackground : .clear))
    .overlay(Circle().stroke(isHovered ? border : .clear, lineWidth: 0.5))
    .scaleEffect(isHovered ? 1.08 : 1.0)
```

### Toggle Switches

```swift
Toggle("", isOn: $binding)
    .toggleStyle(.switch)
    .tint(WhispererColors.accent)
    .labelsHidden()
```

### Empty States

Custom empty state with icon circle — NOT `ContentUnavailableView`:

```swift
VStack(spacing: 20) {
    Spacer()
    ZStack {
        Circle()
            .fill(WhispererColors.accent.opacity(0.12))
            .frame(width: 72, height: 72)
        Image(systemName: "waveform.and.mic")
            .font(.system(size: 28))
            .foregroundColor(WhispererColors.accent)
    }
    VStack(spacing: 6) {
        Text("No Transcriptions Yet")
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundColor(WhispererColors.primaryText(colorScheme))
        Text("Hold Fn to record, then release to transcribe.")
            .font(.system(size: 13))
            .foregroundColor(WhispererColors.secondaryText(colorScheme))
    }
    Spacer()
}
```

### Search Fields

Custom search field — NOT `.searchable()`:

```swift
HStack(spacing: 8) {
    Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(WhispererColors.secondaryText(colorScheme))
    TextField("Search transcriptions...", text: $searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
    // Clear button or ⌘K badge on right
}
.padding(.horizontal, 12)
.padding(.vertical, 9)
.background(RoundedRectangle(cornerRadius: 10).fill(elevatedBackground))
.overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
.shadow(color: Color.black.opacity(dark: 0.06, light: 0.03), radius: 3, y: 1)
```

## Spacing Values

| Context | Value | Usage |
|---------|-------|-------|
| Card padding | 20pt | Settings cards, detail sections |
| Detail stat card padding | 16pt | DetailStatCard grid |
| Section spacing | 24pt | Detail view sections |
| Content margin | 20pt | Transcription list horizontal padding |
| Header horizontal padding | 20pt | All headers |
| Sidebar horizontal padding | 12pt | Nav items container |
| Sidebar stats card padding | 16pt | Stats card inner padding |
| Menu bar panel padding | 16pt | Horizontal content padding |
| Menu bar panel height | 580pt | Fixed |
| Card corner radius (large) | 14pt | Settings cards, detail stat cards, audio section |
| Card corner radius (medium) | 12pt | Transcription text, notes, sidebar stats card |
| Card corner radius (small) | 10pt | Search field, filter bg, nav items |
| Grid spacing | 12pt | DetailStatCard LazyVGrid |
| Row action button size | 28pt | Circular action buttons |
| Left accent bar width | 3.5pt | TranscriptionRow selected/pinned/flagged indicator |

## Animation Patterns

- **Spring animations**: `.spring(response: 0.3)` for selection, tab changes, filter toggles
- **Hover**: `.easeInOut(duration: 0.15)` for hover state transitions (rows, nav items)
- **Hover (fast)**: `.easeInOut(duration: 0.12)` for small elements (buttons, filter tabs)
- **Hover (play button)**: `.easeOut(duration: 0.15)` for play button
- **Hover (cards)**: `.easeOut(duration: 0.2)` for stat cards with scale effect
- **Spring with damping**: `.spring(response: 0.25, dampingFraction: 0.8)` for interactive elements (time format, retention)
- **Pulsing**: `.easeInOut(duration: 1.0).repeatForever(autoreverses: true)` for recording indicator
- **Transitions**: `.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: ...)` for detail panel
- **Copied feedback**: `.spring(response: 0.3, dampingFraction: 0.7)` in, `.easeOut(duration: 0.2)` out after 1.5s

## Window Management

### HistoryWindowManager

Singleton that manages workspace window lifecycle:
- `showWindow()` — creates window lazily, makes key
- `showWindowAndDismissMenu()` — dismisses MenuBarExtra panel first, then shows workspace
- `hideWindow()` / `toggleWindow()` — standard show/hide
- `dismissMenuBarWindow()` — finds the MenuBarExtra NSPanel by checking `window is NSPanel` while skipping known windows (HistoryWindow, OverlayPanel), uses `orderOut(nil)` not `close()`

### Both workspace buttons (footer + settings) call `showWindowAndDismissMenu()`

## What NOT to Do

These patterns break the app's design consistency:

- **DO NOT** use `.listStyle(.sidebar)` on a `List` inside the sidebar — the sidebar uses custom `SidebarNavItem` components, not system list rows
- **DO NOT** use `.background(.ultraThinMaterial)` or `.regularMaterial` — use `WhispererColors` backgrounds
- **DO NOT** use `.foregroundStyle(.primary/.secondary)` — use `WhispererColors.primaryText()` / `.secondaryText()`
- **DO NOT** use `Color(nsColor: .windowBackgroundColor)` in the workspace — use `WhispererColors.background()`
- **DO NOT** use `Color(nsColor: .separatorColor)` — use `WhispererColors.border()`
- **DO NOT** use `ContentUnavailableView` — use the custom empty state pattern
- **DO NOT** use `.searchable()` — use the custom search field
- **DO NOT** use `Picker(.segmented)` for tabs — use the custom tab bar pattern
- **DO NOT** use `.font(.body)` or `.font(.title)` semantic sizes — use explicit `.system(size:weight:design:)`
- **DO NOT** replace gradient footer buttons with `.borderless` buttons — the gradient style is intentional
- **DO NOT** use system `Color.green` — use the specific green values defined per surface
- **DO NOT** put filters on the same row as search — filters go on a separate line below
- **DO NOT** use flexible header height — all three panel headers must be exactly 84pt
- **DO NOT** use `NavigationSplitView` — the workspace uses custom `HStack(spacing: 0)` layout
- **DO NOT** add accent gradients to content containers (audio player, transcription text, notes) — these use plain `cardBackground` with subtle shadows. Only use accent gradients for: detail panel background (very subtle), editing state text containers, selected row backgrounds, and stat cards (color-tinted)
- **DO NOT** use fixed `.frame(width:)` on waveform bars — bars should be flexible to fill available space
- **DO NOT** use plain icons for section labels — always wrap in a gradient rounded-square background container with micro-shadow
- **DO NOT** use gradient fills on play button or selected filter tabs — these use flat `WhispererColors.accent`
- **DO NOT** create cards or interactive elements without shadows — every card needs subtle depth
- **DO NOT** create hover states without at least one visual change (color, scale, shadow, or border)

## Menu Bar Panel — Special Rules

The menu bar panel (`MenuBarView` in `WhispererApp.swift`) is the ONE surface that mixes some system colors:

- Background: `Color(nsColor: .windowBackgroundColor)` — because it's a system menu bar panel
- Info cards: `Color.secondary.opacity(0.05)` background (no explicit border)
- Tab bar background: `Color.secondary.opacity(0.05)`
- Settings cards: `Color.secondary.opacity(0.04)` with `Color.secondary.opacity(0.08)` border at 1pt
- Accent: `Color.accentColor` (system accent, not WhispererColors.accent)
- Icons: Per-category colors (blue for Model, green for Mic, purple for Shortcut, etc.)
- Footer buttons: `LinearGradient` with shadow — indigo for Workspace, red for Quit

The menu bar panel uses `Color.accentColor` and `Color.secondary` because it inherits the system menu bar appearance. The workspace window uses `WhispererColors` everywhere.

## File Locations

| File | Contents |
|------|----------|
| `HistoryWindowView.swift` | WhispererColors, HistoryWindowView, sidebar, TranscriptionsView, HistorySettingsView, all settings components, HeaderStatItem, FilterTab, ResizableDivider, Color(hex:) extension |
| `HistoryWindow.swift` | NSWindow subclass, window sizing, NSToolbar with sidebar toggle |
| `HistoryWindowManager.swift` | Singleton for show/hide/toggle window, menu bar dismissal |
| `TranscriptionDetailView.swift` | Detail panel, DetailStatCard, DetailHeaderButton, section labels |
| `TranscriptionRow.swift` | List row component, RowActionButton, accent bar, metadata display |
| `WhispererApp.swift` | MenuBarView, StatusTabView, ModelsTabView, SettingsTabView, all menu bar panel UI |
| `OverlayView.swift` | HUD overlay bar, RecordingIndicator, MicButton, TranscribingIndicator, DownloadIndicator |
| `LiveTranscriptionCard.swift` | Live transcription bubble, TypewriterAnimator, SpeechBubbleArrow |
| `OverlayPanel.swift` | NSPanel subclass for floating HUD |
| `WaveformView.swift` | Waveform visualization bars |
| `KeywordHighlighter.swift` | Number/currency/percentage highlighting in text |

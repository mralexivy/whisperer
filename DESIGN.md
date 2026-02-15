# Whisperer Design System

## Table of Contents

1. [Color System](#1-color-system) — WhispererColors, accent variants, dark mode, gradients
2. [Typography](#2-typography) — Font scale, weight ladder, tracking, design variants
3. [Layout Patterns](#3-layout-patterns) — Workspace window, sidebar, panels, overlay HUD
4. [Components](#4-components) — Cards, rows, buttons, filters, icons, search, animations
5. [Anti-Patterns](#5-anti-patterns) — Collected rules for what NOT to do

---

## 1. Color System

### Core Principle

Every UI surface uses `WhispererColors` — never system semantic colors (`NSColor.windowBackgroundColor`, `.controlBackgroundColor`, `.foregroundStyle(.secondary)`). The one exception is the menu bar panel (see Menu Bar Panel section in Layout).

### WhispererColors Struct

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

### Green Accent Variants

Different surfaces use slightly different green values:

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

### Dark Mode Philosophy — Spotify-Inspired

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

### Color Hex Extension

Defined at the bottom of `HistoryWindowView.swift`. Supports 3, 6, and 8 character hex strings:

```swift
Color(hex: "22C55E")     // 6-char
Color(hex: "FF22C55E")   // 8-char with alpha
```

---

## 2. Typography

Whisperer uses **explicit font sizes** with `.system(size:weight:design:)`, never semantic styles (`.body`, `.title`, `.caption`).

### Core Principles

1. **Weight contrast = hierarchy** — `.light` for large display text (stat values, hero numbers). `.bold` for smaller structural elements (section titles, nav items). The bigger the text, the lighter the weight.
2. **`.rounded` = warmth** — SF Rounded for ALL titles, stat values, brand text, section headers. Default (non-rounded) for body copy, form labels, metadata.
3. **Tracking = breathing room** — Uppercase labels MUST have tracking (0.5-1.2). Prevents cramped look, adds premium quality.
4. **Line spacing = readability** — Body text uses `.lineSpacing(4-6)`. Default line spacing is too tight for premium feel.
5. **Opacity for sub-hierarchy** — Within the same color, use `.opacity(0.7)` or `.opacity(0.5)` for additional layers without new colors.

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
| Stat card value (detail) | `.system(size: 20, weight: .light, design: .rounded)` | Light = elegance at large sizes |
| Workspace name | `.system(size: 20, weight: .bold, design: .rounded)` | |
| Detail date header | `.system(size: 18, weight: .bold, design: .rounded)` | |
| Header stat value | `.system(size: 18, weight: .light, design: .rounded)` | |
| Sidebar stat value | `.system(size: 16, weight: .light, design: .rounded)` | |
| Brand name (sidebar) | `.system(size: 15, weight: .bold, design: .rounded)` | |
| Section header | `.system(size: 15, weight: .bold, design: .rounded)` | |
| Setting label | `.system(size: 14, weight: .semibold)` | |
| Body text (transcription) | `.system(size: 14, weight: .regular)` + `.lineSpacing(5)` | |
| Text preview (row) | `.system(size: 13.5, weight: .regular)` + `.lineSpacing(3)` | |
| Field title | `.system(size: 13, weight: .medium)` + `.tracking(0.3)` | |
| Search field | `.system(size: 13, weight: .regular)` | |
| Sidebar nav item | `.system(size: 13, weight: .medium/.semibold)` | Medium default, semibold selected |
| Row time | `.system(size: 12, weight: .bold, design: .rounded)` | |
| Row duration | `.system(size: 12, weight: .medium)` | |
| Filter tab | `.system(size: 12, weight: .semibold/.medium)` | Semibold selected, medium default |
| Subtitle / description | `.system(size: 12, weight: .regular)` | |
| Section label (detail) | `.system(size: 11, weight: .bold, design: .rounded)` + `.tracking(0.8)` + `.uppercased()` | |
| Date section header | `.system(size: 11, weight: .bold, design: .rounded)` + `.tracking(0.5)` + `.textCase(.uppercase)` | |
| Sidebar stat label | `.system(size: 11, weight: .semibold)` + `.tracking(0.8)` + `.uppercased()` | |
| Helper text | `.system(size: 11, weight: .regular)` + `.opacity(0.7)` on secondaryText | |
| Stat card label (detail) | `.system(size: 10, weight: .bold)` + `.tracking(1.0)` + `.uppercased()` | |
| Category badge | `.system(size: 10, weight: .medium)` + `.tracking(0.3)` | |
| Header stat label | `.system(size: 9, weight: .semibold)` + `.tracking(0.8)` | |

### Design Variants

- **`.rounded`** — Titles, brand text, section headers, stat values, modal headers. The app's typographic signature.
- **`.monospaced`** — Dictionary entries, time formats, keyboard shortcuts, code-like data.
- **Default** — Body text, form labels, descriptions, metadata, helper text.

### Tracking Guide

| Text Size | Tracking | Usage |
|-----------|----------|-------|
| 9-10pt uppercase | `1.0-1.2` | Stat labels, tiny uppercase captions |
| 11pt uppercase | `0.5-0.8` | Section labels, date headers, sidebar labels |
| 12-13pt | `0.2-0.3` | Field titles, category badges (optional) |
| 14pt+ | `0` | Body text, titles — no tracking needed |

---

## 3. Layout Patterns

### Workspace Window (HistoryWindow + HistoryWindowView)

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
│ Nav     │                                                    │
│ Items   │                                                    │
│ Spacer  │                                                    │
│ Stats   │                                                    │
│ Shortcut│                                                    │
└─────────┴────────────────────────────────────────────────────┘
```

- Custom `HStack(spacing: 0)` with `@State isSidebarCollapsed` toggle
- Sidebar width: **220pt** fixed
- 1pt `WhispererColors.border()` divider between sidebar and content
- Sidebar background: `WhispererColors.sidebarBackground()`
- Content background: `WhispererColors.background()`
- Window size: **1100x750** default, **700x700** minimum
- **NSToolbar** `.unified` style, `titleVisibility = .hidden` — sidebar toggle button at leading edge
- Toggle: plain borderless `NSButton` with `sidebar.leading` icon, posts `.toggleWorkspaceSidebar` notification
- SwiftUI receives notification and toggles `isSidebarCollapsed` with `.spring(response: 0.3)`

### Header Alignment

All three panel headers (sidebar brand, main content, detail) MUST share the same fixed height:

```swift
.frame(height: 84, alignment: .center)
```

Full-width background behind header area fills ResizableDivider gap:
```swift
.background(
    VStack(spacing: 0) {
        WhispererColors.cardBackground(colorScheme).frame(height: 84)
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
    sidebarStatsCard     // Stats (recordings, words, avg WPM, days)
    shortcutHint         // "Fn + S to toggle" at bottom
}
```

**Brand Header** — Gradient icon container (36pt rounded rect) with shadow, waveform icon.

**SidebarNavItem** — 12pt horizontal + 10pt vertical padding, `RoundedRectangle(cornerRadius: 10)` background:
- Selected: `accent.opacity(0.15)` fill + `.accent.opacity(0.3)` stroke + accent shadow
- Hovered: `elevatedBackground` fill, text brightens to primaryText
- Icon: 14pt medium, green when selected
- Text: 13pt semibold selected, medium default

**Sidebar Stats Card** — Diagonal gradient with gradient border and accent shadow. Each row: HStack { label (11pt semibold, tracking 0.8) | Spacer | value (16pt light rounded) }

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

```swift
VStack(spacing: 0) {
    HStack(spacing: 14) {
        // Avatar — gradient accent fill, 44pt rounded rect with shadow
        // Welcome text — name 20pt bold rounded + greeting 12pt secondary
        Spacer()
    }
    .padding(.horizontal, 20).padding(.vertical, 16)
    // Gradient separator fading at edges
    Rectangle().fill(LinearGradient(
        colors: [border.opacity(0.6), border, border.opacity(0.6)],
        startPoint: .leading, endPoint: .trailing
    )).frame(height: 1)
}
```

No card background, no stats in header (stats are in sidebar only).

### Toolbar — Search + Filters (Two Rows)

```swift
VStack(spacing: 12) {
    // Row 1: Search field (full width) with shadow
    // Row 2: Filter capsules (left-aligned)
    HStack(spacing: 6) {
        FilterTab(title: "All", ...)
        FilterTab(title: "Pinned", ...)
        FilterTab(title: "Flagged", ...)
        Spacer()
    }
}
.padding(.horizontal, 20).padding(.vertical, 14)
```

DO NOT put filters on the same row as search.

### Detail Panel (TranscriptionDetailView)

Header with gradient separator (accent tint on leading edge):
```swift
Rectangle().fill(LinearGradient(
    colors: [accent.opacity(0.2), border, border.opacity(0.3)],
    startPoint: .leading, endPoint: .trailing
)).frame(height: 1)
```

Panel background: Subtle top-to-bottom accent gradient:
```swift
.background(LinearGradient(
    colors: [accent.opacity(dark: 0.04, light: 0.02), background],
    startPoint: .top, endPoint: .bottom
))
```

Sections (24pt spacing):
1. **Audio Recording** — Section label INSIDE card, plain card background + shadow
2. **Transcription** — HighlightedText with edit toggle. Non-editing: plain card + shadow. Editing: accent gradient + accent border
3. **Details** — 2-column `LazyVGrid` of `DetailStatCard` with color-tinted gradients
4. **Notes** — TextEditor with placeholder, plain card + shadow

**Important**: Content containers use plain card backgrounds — NOT accent gradients. Only editing state and panel background use accent tints.

### Menu Bar Panel (MenuBarView)

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
├──────────────────────────┤
│  Footer (gradient btns)  │
└──────────────────────────┘
```

- Frame: **360x580**
- Background: `Color(nsColor: .windowBackgroundColor)` — exception (system menu bar panel)
- Footer: Two gradient buttons (indigo=Workspace, red=Quit) with shadows and keyboard shortcut badges
- Workspace button calls `HistoryWindowManager.shared.showWindowAndDismissMenu()`

### Overlay HUD (OverlayView + OverlayPanel)

- `NSPanel` with `[.borderless, .nonactivatingPanel]`, `hasShadow = false`
- Background: `Capsule()` — dark: `Color(white: 0.15)`, light: `Color(white: 0.98)`
- Stroke: `Color.gray.opacity()` — dark: 0.2, light: 0.1
- Panel size: **420x220**, bottom-center with 10pt margin
- Content pinned to bottom via Auto Layout

### Window Management (HistoryWindowManager)

Singleton managing workspace window lifecycle:
- `showWindow()` — creates lazily, makes key
- `showWindowAndDismissMenu()` — dismisses MenuBarExtra panel first, then shows workspace
- `dismissMenuBarWindow()` — finds MenuBarExtra NSPanel by checking `window is NSPanel` (skipping known windows), uses `orderOut(nil)` not `close()`

---

## 4. Components

### Icon Containers

**Two styles** depending on context:

**Circles** — stat card icons (36pt) and header avatars (44pt):
```swift
Circle()
    .fill(LinearGradient(
        colors: [color.opacity(0.12), color.opacity(0.05)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    ))
    .frame(width: 36, height: 36)
```

**Rounded squares** — section labels (24pt, cornerRadius 6), settings headers (28pt, cornerRadius 7), settings rows (36pt, cornerRadius 8):
```swift
RoundedRectangle(cornerRadius: 7)
    .fill(LinearGradient(
        colors: [accent.opacity(dark: 0.18, light: 0.12), accentDark.opacity(dark: 0.08, light: 0.05)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    ))
    .shadow(color: accent.opacity(0.08), radius: 3, y: 1)
```

Settings row icon containers use **flat** fill (no gradient): `.fill(accent.opacity(0.12))`

### Cards

```swift
content()
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(border, lineWidth: 1))
    .shadow(color: Color.black.opacity(dark: 0.06, light: 0.03), radius: 4, y: 1)
```

### TranscriptionRow

Three-line layout with full-height accent bar, layered shadows, hover elevation:

```swift
HStack(spacing: 0) {
    // Left accent bar — full height, no padding
    Rectangle().fill(accentBarColor).frame(width: 3.5)
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

Selected row: vertical LinearGradient using AnyShapeStyle, accent border 1.5pt, accent shadow.
Hovered: subtle gradient, border intensified, `scaleEffect(1.006)`.
Card clipped with `.clipShape(RoundedRectangle(cornerRadius: 12))`.

### DetailStatCard (2-Column Grid)

Color-tinted gradient cards with per-card color (accent=Duration, blue=Words, purple=WPM, orange=Language, cyan=Model):

```swift
VStack(alignment: .leading, spacing: 0) {
    // Gradient circle icon (36pt) using card's color
    // Label: 10pt bold, tracking 1.0, uppercased, 0.7 opacity secondary
    // Value: 20pt light rounded, primary
}
.padding(16)
.background(RoundedRectangle(cornerRadius: 14)
    .fill(LinearGradient(
        colors: [color.opacity(dark: 0.08, light: 0.04), cardBackground],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )))
.overlay(RoundedRectangle(cornerRadius: 14)
    .stroke(isHovered ? color.opacity(0.2) : color.opacity(0.08), lineWidth: 1))
.scaleEffect(isHovered ? 1.02 : 1.0)
```

### Section Headers

**Settings section headers** (SettingsSectionHeader): gradient icon (28pt) + 15pt bold rounded title.

**Date section headers** (transcription list): 11pt bold rounded uppercase + `.tracking(0.5)` + gradient fading line:
```swift
HStack(spacing: 10) {
    Text(dateString).font(.system(size: 11, weight: .bold, design: .rounded))
        .textCase(.uppercase).tracking(0.5)
    Rectangle().fill(LinearGradient(colors: [border, border.opacity(0.2)], ...)).frame(height: 1)
}
```

### Action Buttons (Row-Level)

28pt circular with hover state, border ring, and scale:
```swift
Image(systemName: icon)
    .font(.system(size: 11, weight: .medium))
    .frame(width: 28, height: 28)
    .background(Circle().fill(isHovered ? elevatedBackground : .clear))
    .overlay(Circle().stroke(isHovered ? border : .clear, lineWidth: 0.5))
    .scaleEffect(isHovered ? 1.08 : 1.0)
```

### FilterTab

Capsule-shaped pills:
- Selected: flat `WhispererColors.accent` (NOT gradient), white text, accent glow shadow
- Unselected: transparent, border stroke, secondary text
- Hovered: elevatedBackground fill, text brightens
- Padding: 14pt horizontal, 7pt vertical
- Font: 12pt semibold (selected) / medium (unselected)

### Toggle Switches

```swift
Toggle("", isOn: $binding).toggleStyle(.switch).tint(WhispererColors.accent).labelsHidden()
```

### Empty States

Custom pattern — NOT `ContentUnavailableView`:
```swift
VStack(spacing: 20) {
    Spacer()
    ZStack {
        Circle().fill(accent.opacity(0.12)).frame(width: 72, height: 72)
        Image(systemName: "waveform.and.mic").font(.system(size: 28)).foregroundColor(accent)
    }
    VStack(spacing: 6) {
        Text("No Transcriptions Yet").font(.system(size: 18, weight: .bold, design: .rounded))
        Text("Hold Fn to record...").font(.system(size: 13)).foregroundColor(secondaryText)
    }
    Spacer()
}
```

### Search Fields

Custom HStack — NOT `.searchable()`:
```swift
HStack(spacing: 8) {
    Image(systemName: "magnifyingglass")
    TextField("Search transcriptions...", text: $searchText).textFieldStyle(.plain)
}
.padding(.horizontal, 12).padding(.vertical, 9)
.background(RoundedRectangle(cornerRadius: 10).fill(elevatedBackground))
.overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
.shadow(color: Color.black.opacity(dark: 0.06, light: 0.03), radius: 3, y: 1)
```

### Play Button (AudioPlayerView)

Flat accent fill (NOT gradient) with accent glow and hover scale:
```swift
Circle().fill(WhispererColors.accent).frame(width: 44, height: 44)
    .shadow(color: accent.opacity(isHovered ? 0.4 : 0.25), radius: isHovered ? 10 : 6, y: isHovered ? 3 : 2)
    .scaleEffect(isHovered ? 1.06 : 1.0)
```

Waveform bars use flexible widths (no fixed `.frame(width:)`), 70 samples, `.mask()` for progress.

### Shadow Tiers

| Element | Shadow |
|---------|--------|
| Row (rest) | `black.opacity(dark: 0.06, light: 0.03), radius: 3, y: 1` |
| Row (hover) | `black.opacity(dark: 0.12, light: 0.06), radius: 6, y: 2` |
| Row (selected) | `accent.opacity(dark: 0.06, light: 0.08), radius: 8, y: 3` |
| Settings cards | `black.opacity(dark: 0.06, light: 0.03), radius: 4, y: 1` |
| Search field | `black.opacity(dark: 0.06, light: 0.03), radius: 3, y: 1` |
| Selected filter | `accent.opacity(0.25), radius: 4, y: 1` |
| Play button (rest) | `accent.opacity(0.25), radius: 6, y: 2` |
| Play button (hover) | `accent.opacity(0.4), radius: 10, y: 3` |
| Icon containers | `accent.opacity(0.06-0.15), radius: 2-6, y: 1-2` |

### Hover Micro-Interactions

| Element | Effect |
|---------|--------|
| TranscriptionRow | `scaleEffect(1.006)` + gradient bg + deeper shadow |
| RowActionButton | `scaleEffect(1.08)` + border ring + elevated bg |
| DetailHeaderButton | `scaleEffect(1.06)` + shadow lift |
| DetailStatCard | `scaleEffect(1.02)` + shadow + border intensify |
| Play button | `scaleEffect(1.06)` + shadow intensify |
| SidebarNavItem | Text brightens to primaryText |

### Spacing Values

| Context | Value |
|---------|-------|
| Card padding | 20pt |
| Detail stat card padding | 16pt |
| Section spacing | 24pt |
| Content margin | 20pt |
| Card corner radius (large) | 14pt |
| Card corner radius (medium) | 12pt |
| Card corner radius (small) | 10pt |
| Grid spacing | 12pt |
| Row action button size | 28pt |
| Left accent bar width | 3.5pt |

### Animation Patterns

- **Spring**: `.spring(response: 0.3)` for selection, tab changes
- **Hover**: `.easeInOut(duration: 0.15)` for rows, nav items
- **Hover (fast)**: `.easeInOut(duration: 0.12)` for buttons, filters
- **Hover (play)**: `.easeOut(duration: 0.15)`
- **Hover (cards)**: `.easeOut(duration: 0.2)` for stat cards with scale
- **Spring with damping**: `.spring(response: 0.25, dampingFraction: 0.8)` for interactive
- **Pulsing**: `.easeInOut(duration: 1.0).repeatForever(autoreverses: true)` for recording
- **Transitions**: `.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), ...)`

### File Locations

| File | Contents |
|------|----------|
| `HistoryWindowView.swift` | WhispererColors, sidebar, TranscriptionsView, settings, FilterTab, ResizableDivider, Color(hex:) |
| `TranscriptionDetailView.swift` | Detail panel, DetailStatCard, DetailHeaderButton, section labels |
| `TranscriptionRow.swift` | List row, RowActionButton, accent bar, metadata |
| `WhispererApp.swift` | MenuBarView, StatusTab, ModelsTab, SettingsTab |
| `OverlayView.swift` | HUD overlay, RecordingIndicator, MicButton |
| `LiveTranscriptionCard.swift` | Live transcription bubble, TypewriterAnimator |
| `WaveformView.swift` | Waveform visualization bars |

---

## 5. Anti-Patterns

### Colors
- DO NOT use `.background(.ultraThinMaterial)` — use WhispererColors backgrounds
- DO NOT use `.foregroundStyle(.primary/.secondary)` — use WhispererColors text colors
- DO NOT use `Color(nsColor: .windowBackgroundColor)` in workspace — use WhispererColors.background()
- DO NOT use `Color(nsColor: .separatorColor)` — use WhispererColors.border()
- DO NOT use system `Color.green` — use per-surface green values
- DO NOT use shadow opacity above `0.15` for `Color.black` — creates gray halos
- DO NOT use same opacity for dark and light — dark needs ~50% less
- DO NOT rely on borders for separation — use background layering
- DO NOT use blue-tinted grays for secondary text — use warm #B3B3B3
- DO NOT increase accent opacities to compensate — accent pops naturally

### Typography
- DO NOT use `.bold` for large display numbers (20pt+) — use `.light` for elegance
- DO NOT use uppercase text without tracking — looks cramped and cheap
- DO NOT use `.title` / `.body` / `.caption` semantic styles — always explicit sizes
- DO NOT use the same weight for everything — weight ladder creates visual rhythm
- DO NOT skip `.lineSpacing()` on multi-line body text — default is too tight
- DO NOT use `.rounded` for body text or metadata — reserve for titles and stat values

### Layout
- DO NOT use `NavigationSplitView` — workspace uses custom `HStack(spacing: 0)`
- DO NOT use flexible header height — all three headers must be exactly 84pt
- DO NOT use `.listStyle(.sidebar)` — sidebar uses custom SidebarNavItem components
- DO NOT put filters on the same row as search

### Components
- DO NOT use `ContentUnavailableView` — use custom empty state
- DO NOT use `.searchable()` — use custom search field
- DO NOT use `Picker(.segmented)` for tabs — use custom tab pattern
- DO NOT replace gradient footer buttons with `.borderless` — gradient is intentional
- DO NOT use fixed `.frame(width:)` on waveform bars — flexible widths
- DO NOT use plain icons for section labels — wrap in gradient container with micro-shadow
- DO NOT use gradient on play button or filter tabs — use flat accent
- DO NOT create cards without shadows — every card needs subtle depth
- DO NOT create hover states without at least one visual change

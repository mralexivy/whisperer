---
name: designing-macos-apps
description: Use when designing or modifying any UI in the Whisperer macOS app. This documents the app's existing design system — colors, typography, layout patterns, and component conventions. Follow these patterns exactly to maintain visual consistency across all surfaces (workspace window, menu bar panel, overlay HUD).
---

# Whisperer Design System

## Overview

Whisperer uses a **custom design system** with its own color palette, typography scale, and component patterns. The design is purpose-built for a premium voice transcription tool — dark-themed with a vibrant green accent, explicit hex colors that adapt via `@Environment(\.colorScheme)`, and handcrafted components throughout.

**Core principle:** Every UI surface in the app shares the same visual language. The menu bar panel, workspace window, and overlay HUD all use `WhispererColors`, the same icon treatment, the same card patterns, and the same typography scale.

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
        scheme == .dark ? Color(hex: "0D0D0D") : Color(hex: "F8FAFC")
    }
    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "1A1A1A") : Color.white
    }
    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "141414") : Color(hex: "FFFFFF")
    }
    static func elevatedBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "262626") : Color(hex: "F1F5F9")
    }

    // Text
    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color(hex: "0F172A")
    }
    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "9CA3AF") : Color(hex: "64748B")
    }

    // Borders
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
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

### Color Hex Extension

Colors use a custom `Color(hex:)` initializer defined at the bottom of `HistoryWindowView.swift`. It supports 3, 6, and 8 character hex strings.

## Typography — Explicit Sizes

Whisperer uses **explicit font sizes** with `.system(size:weight:design:)`, not semantic text styles (`.body`, `.title`, etc.). This gives precise control over the visual hierarchy.

### Standard Scale

| Usage | Font Specification |
|-------|-------------------|
| Page/section title | `.system(size: 26, weight: .bold, design: .rounded)` |
| Stat card value (detail) | `.system(size: 20, weight: .bold, design: .rounded)` |
| Workspace name | `.system(size: 20, weight: .bold, design: .rounded)` |
| Detail date header | `.system(size: 18, weight: .bold, design: .rounded)` |
| Header stat value | `.system(size: 18, weight: .bold, design: .rounded)` |
| Sidebar stat value | `.system(size: 16, weight: .bold, design: .rounded)` |
| Brand name (sidebar) | `.system(size: 15, weight: .bold, design: .rounded)` |
| Section header | `.system(size: 15, weight: .bold, design: .rounded)` |
| Setting label | `.system(size: 14, weight: .semibold)` |
| Body text (transcription) | `.system(size: 14)` with `.lineSpacing(4)` |
| Text preview (row) | `.system(size: 13.5, weight: .regular)` |
| Setting item title | `.system(size: 13, weight: .medium)` |
| Search field | `.system(size: 13)` |
| Sidebar nav item | `.system(size: 13, weight: .medium/.semibold)` |
| Section label (detail view) | `.system(size: 11, weight: .bold, design: .rounded)` with `.tracking(0.8)` and `.uppercased()` |
| Row time | `.system(size: 12, weight: .bold, design: .rounded)` |
| Row duration | `.system(size: 12, weight: .medium)` |
| Filter tab | `.system(size: 12, weight: .semibold/.medium)` |
| Metadata / secondary | `.system(size: 11, weight: .medium)` |
| Date section header | `.system(size: 11, weight: .bold, design: .rounded)` with `.tracking(0.5)` and `.textCase(.uppercase)` |
| Sidebar stat label | `.system(size: 11, weight: .semibold)` with `.tracking(0.8)` |
| Stat card label (detail) | `.system(size: 10, weight: .bold)` with `.tracking(1.0)` |
| Stat label / caption | `.system(size: 10)` |
| Header stat label | `.system(size: 9, weight: .semibold)` with `.tracking(0.8)` |

### Design Variants

- **`.rounded`** — Used for titles, brand text, section headers, stat values. Gives the app its characteristic friendly look.
- **`.monospaced`** — Used for time format examples, keyboard shortcuts, and code-like data.
- **Default (no design)** — Used for body text, labels, metadata.

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

**SidebarNavItem** — Custom component with:
- 12pt horizontal + 10pt vertical padding
- `RoundedRectangle(cornerRadius: 10)` background
- Selected: `WhispererColors.accent.opacity(0.15)` fill + `.accent.opacity(0.3)` stroke
- Hovered: `WhispererColors.elevatedBackground()` fill
- Icon: 14pt medium weight, green when selected, secondary when not
- Text: 13pt semibold when selected, medium when not

**Sidebar Stats Card** — Text rows in an accent-gradient card:
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
                WhispererColors.accent.opacity(colorScheme == .dark ? 0.1 : 0.06),
                WhispererColors.cardBackground(colorScheme)
            ],
            startPoint: .leading, endPoint: .trailing
        ))
)
// Each row: HStack { label (11pt semibold, tracking 0.8) | Spacer | value (16pt bold rounded) }
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

```swift
HStack(spacing: 14) {
    // Avatar — rounded-square with accent tint
    ZStack {
        RoundedRectangle(cornerRadius: 12)
            .fill(WhispererColors.accent.opacity(0.12))
            .frame(width: 44, height: 44)
        Text(initials)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(WhispererColors.accent)
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
.background(WhispererColors.background(colorScheme))
```

No card background, no stats in header (stats are in sidebar only).

### Toolbar — Search + Filters (Two Rows)

The toolbar is a `VStack(spacing: 12)` with search on top and filters below:

```swift
VStack(spacing: 12) {
    // Row 1: Search field (full width)
    HStack(spacing: 8) { magnifyingglass + TextField + ⌘K badge }
        .background(RoundedRectangle(cornerRadius: 10).fill(elevatedBackground))

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
- Selected: `WhispererColors.accent` fill, white text, no border
- Unselected: transparent fill, `WhispererColors.border()` stroke, secondary text
- Hovered: `WhispererColors.elevatedBackground()` fill
- Padding: 14pt horizontal, 7pt vertical
- Font: 12pt semibold (selected) / medium (unselected)

### TranscriptionRow

Three-line layout with full-height left accent bar:

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
        HStack {
            Text(timeString)     // 12pt bold rounded, accent when selected
            Text(" · ")          // faded separator
            Text(durationString) // 12pt medium, secondary
            Spacer()
            // Status icons: pencil (edited), pin.fill (pinned), flag.fill (flagged)
            actionButtons        // visible on hover/selected only
        }

        // Line 2: Text preview
        Text(transcription.displayText)  // 13.5pt, 2 lines, primary

        // Line 3: Metadata
        HStack {
            Text("\(wpm) WPM · \(wordCount) words · \(language)")
        }  // 11pt medium, secondary
    }
    .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 14)
}
```

- **Selected row background**: Subtle vertical `LinearGradient` (top-to-bottom) using `AnyShapeStyle`:
```swift
isSelected
    ? AnyShapeStyle(LinearGradient(
        colors: [
            WhispererColors.accent.opacity(colorScheme == .dark ? 0.08 : 0.05),
            WhispererColors.accent.opacity(colorScheme == .dark ? 0.02 : 0.01)
        ],
        startPoint: .top, endPoint: .bottom
    ))
    : AnyShapeStyle(WhispererColors.cardBackground(colorScheme))
```
- Selected border: `accent.opacity(0.3)`, 1.5pt lineWidth
- Unselected border: `WhispererColors.border()`, 1pt lineWidth
- Card clipped with `.clipShape(RoundedRectangle(cornerRadius: 12))`
- Action buttons: copy, flag, pin, more menu — 28pt circular with hover state

### Detail Panel (TranscriptionDetailView)

Header: date info + share/close buttons, 84pt height, card background.

**Panel background**: Subtle top-to-bottom accent gradient:
```swift
.background(
    LinearGradient(
        colors: [
            WhispererColors.accent.opacity(colorScheme == .dark ? 0.04 : 0.02),
            WhispererColors.background(colorScheme)
        ],
        startPoint: .top, endPoint: .bottom
    )
)
```

Sections (24pt spacing):
1. **Audio Recording** — Section label INSIDE the card container (above waveform), plain card background
2. **Transcription** — HighlightedText with edit toggle (capsule button). Non-editing: plain card background. Editing: accent gradient + accent border
3. **Details** — 2-column `LazyVGrid` of `DetailStatCard` with color-tinted gradients
4. **Notes** — TextEditor with placeholder, plain card background

**Important**: Content containers (audio player, transcription text, notes) use **plain card backgrounds** — NOT accent gradients. Only the editing state and the overall panel background use accent tints.

### DetailStatCard (2-Column Grid)

Each card uses its own `color` for gradient fill, shadow, and border — creating a color-tinted appearance:

```swift
VStack(alignment: .leading, spacing: 0) {
    // Icon in gradient circle — uses card's color
    ZStack {
        Circle()
            .fill(LinearGradient(
                colors: [color.opacity(0.2/0.12), color.opacity(0.1/0.06)],
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
    Text(value)    // 20pt bold rounded, primary
}
.padding(16)
// Color-tinted gradient background
.background(
    RoundedRectangle(cornerRadius: 14)
        .fill(LinearGradient(
            colors: [
                color.opacity(colorScheme == .dark ? 0.08 : 0.04),
                WhispererColors.cardBackground(colorScheme)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.25) : color.opacity(0.08),
            radius: isHovered ? 10 : 4, y: isHovered ? 4 : 1
        )
)
// Color-tinted border
.overlay(
    RoundedRectangle(cornerRadius: 14)
        .stroke(
            isHovered
                ? color.opacity(colorScheme == .dark ? 0.35 : 0.25)
                : color.opacity(colorScheme == .dark ? 0.15 : 0.1),
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
    .background(RoundedRectangle(cornerRadius: 14).fill(WhispererColors.cardBackground(colorScheme)))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
}
```

**Waveform bars** use flexible widths (no fixed `.frame(width:)`) to fill the available container:
```swift
HStack(spacing: 2) {
    ForEach(0..<waveformData.count, id: \.self) { index in
        RoundedRectangle(cornerRadius: 2)
            .fill(...)
            .frame(height: max(4, CGFloat(waveformData[index]) * 56))
        // NO fixed width — bars flex to fill available space
    }
}
```
- Waveform padding: `.padding(.horizontal, 4)` on the waveformView
- Sample count: 70
- Progress overlay uses `.mask()` for smooth fill
- Playhead: white circle (10pt) with accent shadow

### Editing State (Transcription Text)

When editing, the transcription text container uses an accent gradient + accent border to visually distinguish it:
```swift
// Editing state
.background(
    RoundedRectangle(cornerRadius: 12)
        .fill(LinearGradient(
            colors: [
                WhispererColors.accent.opacity(colorScheme == .dark ? 0.12 : 0.08),
                WhispererColors.cardBackground(colorScheme)
            ],
            startPoint: .leading, endPoint: .trailing
        ))
)
.overlay(
    RoundedRectangle(cornerRadius: 12)
        .stroke(WhispererColors.accent.opacity(0.4), lineWidth: 1.5)
)

// Non-editing state — plain card, no gradient
.background(RoundedRectangle(cornerRadius: 12).fill(WhispererColors.cardBackground(colorScheme)))
.overlay(RoundedRectangle(cornerRadius: 12).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
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

Whisperer uses **two icon container styles** depending on context:

**Circles** — for stat card icons and header avatars:
```swift
// Stat card icon (36pt) — uses per-card color gradient
ZStack {
    Circle()
        .fill(LinearGradient(
            colors: [color.opacity(0.2/0.12), color.opacity(0.1/0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .frame(width: 36, height: 36)
    Image(systemName: icon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(color)
}

// Large icon container (44pt) — used in headers
Circle()
    .fill(LinearGradient(colors: [.accent, .accentDark], ...))
    .frame(width: 44, height: 44)
```

**Rounded squares** — for section labels and settings section headers:
```swift
// Section label icon (24pt) — detail view section labels
ZStack {
    RoundedRectangle(cornerRadius: 6)
        .fill(WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.1))
        .frame(width: 24, height: 24)
    Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(WhispererColors.accent)
}

// Settings section header icon (28pt)
ZStack {
    RoundedRectangle(cornerRadius: 7)
        .fill(WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.1))
        .frame(width: 28, height: 28)
    Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(WhispererColors.accent)
}

// Settings row icon container (36pt)
RoundedRectangle(cornerRadius: 8)
    .fill(WhispererColors.accent.opacity(0.12))
    .frame(width: 36, height: 36)
```

### Cards

```swift
// Standard card container (workspace settings)
content()
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(WhispererColors.cardBackground(colorScheme)))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
```

### Section Headers

```swift
// Settings section headers (SettingsSectionHeader) — rounded-square icon + bold title
HStack(spacing: 10) {
    ZStack {
        RoundedRectangle(cornerRadius: 7)
            .fill(WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.1))
            .frame(width: 28, height: 28)
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(WhispererColors.accent)
    }
    Text(title)
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .foregroundColor(WhispererColors.primaryText(colorScheme))
}

// Detail view section labels — rounded-square icon + uppercase tracking text
HStack(spacing: 8) {
    ZStack {
        RoundedRectangle(cornerRadius: 6)
            .fill(WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.1))
            .frame(width: 24, height: 24)
        Image(systemName: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(WhispererColors.accent)
    }
    Text(text.uppercased())
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundColor(WhispererColors.secondaryText(colorScheme))
        .tracking(0.8)
}

// Date section headers (transcription list)
Text(dateString)
    .font(.system(size: 11, weight: .bold, design: .rounded))
    .foregroundColor(WhispererColors.secondaryText(colorScheme))
    .textCase(.uppercase)
    .tracking(0.5)
```

### Action Buttons (Row-Level)

```swift
// Circular action button with hover state
Image(systemName: icon)
    .font(.system(size: 11, weight: .medium))
    .foregroundColor(isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))
    .frame(width: 28, height: 28)
    .background(Circle().fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
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
.background(RoundedRectangle(cornerRadius: 10).fill(WhispererColors.elevatedBackground(colorScheme)))
.overlay(RoundedRectangle(cornerRadius: 10).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
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
- **Hover**: `.easeInOut(duration: 0.15)` for hover state transitions
- **Hover (fast)**: `.easeInOut(duration: 0.12)` for small elements (buttons, filter tabs)
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
- **DO NOT** add accent gradients to content containers (audio player, transcription text, notes) — these use plain `cardBackground`. Only use accent gradients for: detail panel background (very subtle), editing state text containers, selected row backgrounds, and stat cards (color-tinted)
- **DO NOT** use fixed `.frame(width:)` on waveform bars — bars should be flexible to fill available space
- **DO NOT** use plain icons for section labels — always wrap in a rounded-square background container

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

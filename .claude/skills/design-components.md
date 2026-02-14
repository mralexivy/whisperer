---
name: design-components
description: Use when building or modifying UI components like cards, buttons, icons, shadows, toggles, search fields, rows, or stat cards in Whisperer. Covers component patterns, shadow tiers, hover micro-interactions, spacing values, animation patterns, and anti-patterns.
---

# Whisperer Component Patterns

## Icon Containers

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

## Cards

```swift
content()
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(cardBackground))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(border, lineWidth: 1))
    .shadow(color: Color.black.opacity(dark: 0.06, light: 0.03), radius: 4, y: 1)
```

## TranscriptionRow

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

## DetailStatCard (2-Column Grid)

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

## Section Headers

**Settings section headers** (SettingsSectionHeader): gradient icon (28pt) + 15pt bold rounded title.

**Date section headers** (transcription list): 11pt bold rounded uppercase + `.tracking(0.5)` + gradient fading line:
```swift
HStack(spacing: 10) {
    Text(dateString).font(.system(size: 11, weight: .bold, design: .rounded))
        .textCase(.uppercase).tracking(0.5)
    Rectangle().fill(LinearGradient(colors: [border, border.opacity(0.2)], ...)).frame(height: 1)
}
```

## Action Buttons (Row-Level)

28pt circular with hover state, border ring, and scale:
```swift
Image(systemName: icon)
    .font(.system(size: 11, weight: .medium))
    .frame(width: 28, height: 28)
    .background(Circle().fill(isHovered ? elevatedBackground : .clear))
    .overlay(Circle().stroke(isHovered ? border : .clear, lineWidth: 0.5))
    .scaleEffect(isHovered ? 1.08 : 1.0)
```

## FilterTab

Capsule-shaped pills:
- Selected: flat `WhispererColors.accent` (NOT gradient), white text, accent glow shadow
- Unselected: transparent, border stroke, secondary text
- Hovered: elevatedBackground fill, text brightens
- Padding: 14pt horizontal, 7pt vertical
- Font: 12pt semibold (selected) / medium (unselected)

## Toggle Switches

```swift
Toggle("", isOn: $binding).toggleStyle(.switch).tint(WhispererColors.accent).labelsHidden()
```

## Empty States

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

## Search Fields

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

## Play Button (AudioPlayerView)

Flat accent fill (NOT gradient) with accent glow and hover scale:
```swift
Circle().fill(WhispererColors.accent).frame(width: 44, height: 44)
    .shadow(color: accent.opacity(isHovered ? 0.4 : 0.25), radius: isHovered ? 10 : 6, y: isHovered ? 3 : 2)
    .scaleEffect(isHovered ? 1.06 : 1.0)
```

Waveform bars use flexible widths (no fixed `.frame(width:)`), 70 samples, `.mask()` for progress.

## Shadow Tiers

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

## Hover Micro-Interactions

| Element | Effect |
|---------|--------|
| TranscriptionRow | `scaleEffect(1.006)` + gradient bg + deeper shadow |
| RowActionButton | `scaleEffect(1.08)` + border ring + elevated bg |
| DetailHeaderButton | `scaleEffect(1.06)` + shadow lift |
| DetailStatCard | `scaleEffect(1.02)` + shadow + border intensify |
| Play button | `scaleEffect(1.06)` + shadow intensify |
| SidebarNavItem | Text brightens to primaryText |

## Spacing Values

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

## Animation Patterns

- **Spring**: `.spring(response: 0.3)` for selection, tab changes
- **Hover**: `.easeInOut(duration: 0.15)` for rows, nav items
- **Hover (fast)**: `.easeInOut(duration: 0.12)` for buttons, filters
- **Hover (play)**: `.easeOut(duration: 0.15)`
- **Hover (cards)**: `.easeOut(duration: 0.2)` for stat cards with scale
- **Spring with damping**: `.spring(response: 0.25, dampingFraction: 0.8)` for interactive
- **Pulsing**: `.easeInOut(duration: 1.0).repeatForever(autoreverses: true)` for recording
- **Transitions**: `.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), ...)`

## What NOT to Do

- DO NOT use `.background(.ultraThinMaterial)` — use WhispererColors backgrounds
- DO NOT use `.foregroundStyle(.primary/.secondary)` — use WhispererColors text colors
- DO NOT use `Color(nsColor: .windowBackgroundColor)` in workspace — use WhispererColors.background()
- DO NOT use `Color(nsColor: .separatorColor)` — use WhispererColors.border()
- DO NOT use `ContentUnavailableView` — use custom empty state
- DO NOT use `.searchable()` — use custom search field
- DO NOT use `Picker(.segmented)` for tabs — use custom tab pattern
- DO NOT replace gradient footer buttons with `.borderless` — gradient is intentional
- DO NOT use system `Color.green` — use per-surface green values
- DO NOT use fixed `.frame(width:)` on waveform bars — flexible widths
- DO NOT use plain icons for section labels — wrap in gradient container with micro-shadow
- DO NOT use gradient on play button or filter tabs — use flat accent
- DO NOT create cards without shadows — every card needs subtle depth
- DO NOT create hover states without at least one visual change

## File Locations

| File | Contents |
|------|----------|
| `HistoryWindowView.swift` | WhispererColors, sidebar, TranscriptionsView, settings, FilterTab, ResizableDivider, Color(hex:) |
| `TranscriptionDetailView.swift` | Detail panel, DetailStatCard, DetailHeaderButton, section labels |
| `TranscriptionRow.swift` | List row, RowActionButton, accent bar, metadata |
| `WhispererApp.swift` | MenuBarView, StatusTab, ModelsTab, SettingsTab |
| `OverlayView.swift` | HUD overlay, RecordingIndicator, MicButton |
| `LiveTranscriptionCard.swift` | Live transcription bubble, TypewriterAnimator |
| `WaveformView.swift` | Waveform visualization bars |

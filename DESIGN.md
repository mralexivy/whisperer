# Whisperer Design System

## Table of Contents

1. [Color System](#1-color-system) — Unified dark navy palette, blue-purple accents, per-element colorful icons
2. [Typography](#2-typography) — Font scale, weight ladder, tracking, design variants
3. [Layout Patterns](#3-layout-patterns) — Workspace window, sidebar, panels, overlay HUD, onboarding
4. [Components](#4-components) — Cards, rows, buttons, filters, icons, search, animations
5. [Anti-Patterns](#5-anti-patterns) — Collected rules for what NOT to do

---

## 1. Color System

### Core Principle

The entire app uses a **unified dark navy theme** across all windows — workspace, menu bar, overlay HUD, and onboarding. Every UI surface uses the dark navy palette with blue-purple accents. Three color structs exist (`WhispererColors`, `MBColors`, `OnboardingColors`) sharing identical base values for their respective scopes:

| Struct | Scope | Defined in |
|--------|-------|-----------|
| `WhispererColors` | Workspace/history window | `HistoryWindowView.swift` |
| `MBColors` | Menu bar panel | `WhispererApp.swift` (private enum) |
| `OnboardingColors` | Onboarding window | `OnboardingView.swift` (private enum) |

### Unified Dark Navy Palette

All three color structs share these core values:

| Token | Value | Usage |
|-------|-------|-------|
| Background | `#0C0C1A` (rgb 0.047, 0.047, 0.102) | Window/page background |
| Card surface | `#14142B` (rgb 0.078, 0.078, 0.169) | Cards, panels, HUD |
| Sidebar bg | `#0A0A18` (rgb 0.039, 0.039, 0.094) | Sidebar (workspace only) |
| Elevated | `#1C1C3A` (rgb 0.110, 0.110, 0.227) | Elevated surfaces, inputs |
| Accent blue | `#5B6CF7` (rgb 0.357, 0.424, 0.969) | Primary accent — selections, toggles, indicators |
| Accent dark | `#4C5DE8` (rgb 0.298, 0.365, 0.910) | Darker accent variant for gradient endpoints |
| Accent purple | `#8B5CF6` (rgb 0.545, 0.361, 0.965) | Gradient endpoint for CTAs |
| Text primary | `Color.white` | Headings, body text |
| Text secondary | `white.opacity(0.5)` | Descriptions, labels |
| Text tertiary | `white.opacity(0.35)` | Hints, fine print |
| Border | `white.opacity(0.06)` | Card borders, dividers |
| Pill background | `white.opacity(0.08)` | Badges, key caps, pills |

### Scope-Specific Tokens

`OnboardingColors` has additional tokens not shared by other structs:

| Token | Value | Usage |
|-------|-------|-------|
| Right panel | `#12122A` (rgb 0.071, 0.071, 0.165) | Decorative right column background |
| Dot inactive | `white.opacity(0.2)` | Page indicator inactive dots |

`WhispererColors` background colors are functions taking `ColorScheme` (always returning the dark value). `MBColors` and `OnboardingColors` use static properties.

### Accent Gradient

Blue-to-purple gradient used on primary CTA buttons (Save, Add Entry, Unlock Pro Pack, Workspace button):

```swift
LinearGradient(colors: [accentBlue, accentPurple], startPoint: .leading, endPoint: .trailing)
```

### Flat Accent vs Gradient Rule

- **Flat `accent` (#5B6CF7)** — Toggles (`.tint()`), selected filter tabs, selected rows, radio buttons, checkmarks, model badges, links
- **Gradient `[accentBlue, accentPurple]`** — Primary CTA buttons (Save, Add, Purchase), header app icon, Workspace footer button
- **NEVER** use gradient on toggles, filter tabs, or radio buttons — these use flat accent

### Per-Element Colorful Icons

Section headers and feature cards use unique colors per element (not all blue). Each icon sits inside a tinted rounded rectangle:

```swift
ZStack {
    RoundedRectangle(cornerRadius: 6)
        .fill(color.opacity(0.15))
        .frame(width: 26, height: 26)
    Image(systemName: icon)
        .foregroundColor(color)
        .font(.system(size: 12, weight: .medium))
}
```

Examples of per-element colors (workspace settings):
- System-Wide Dictation: `.blue` (globe icon)
- Microphone: `.green` (mic.fill icon)
- Audio Recording: `.red` (waveform icon)
- Keyboard Shortcut: `.red` (keyboard icon)
- About: `.blue` (info.circle icon)

Menu bar settings card icons:
- System-Wide Dictation: `.blue` (globe)
- Audio: `.orange` (speaker.wave.2.fill)
- Launch at Login: `.cyan` (arrow.right.to.line)
- Language: `.blue` (globe)
- Microphone: `.green` (mic.fill)
- Shortcut: `.red` (keyboard)
- Workspace: `.indigo` (square.grid.2x2.fill)
- Permissions: `.red` (lock.shield.fill)
- Diagnostics: `.gray` (ladybug.fill)
- Pro Pack: `.indigo` (wand.and.stars)
- About: `.blue` (info.circle.fill)

Model category icons:
- Recommended: `accent` (#5B6CF7, sparkles)
- Turbo & Optimized: `.orange` (bolt.fill)
- Standard: `.blue` (cube.fill)
- Distilled: `.red` (wand.and.stars)

Menu bar tab icons:
- Status: `accent` #5B6CF7 (waveform)
- Models: `.orange` (cpu)
- Settings: `.red` (gear)

Sidebar nav items:
- Transcriptions: `accentBlue` #5B6CF7 (waveform.and.mic)
- Dictionary: `.red` (book.closed)
- Settings: `.orange` (gearshape)

Filter tabs (TranscriptionsView):
- All: `accentBlue` #5B6CF7
- Pinned: `.orange`
- Flagged: `.red`

### Metadata Pills (TranscriptionRow)

Colorful capsule-shaped pills for row metadata:

```swift
HStack(spacing: 4) {
    Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundColor(color)
    Text(text).font(.system(size: 10.5, weight: .medium)).foregroundColor(color)
}
.padding(.horizontal, 7).padding(.vertical, 3)
.background(Capsule().fill(color.opacity(colorScheme == .dark ? 0.12 : 0.08)))
```

- WPM: `.orange` + speedometer icon
- Words: `accentBlue` + text.word.spacing icon
- Language: `.red` + globe icon

### Window Chrome

Most windows use flat dark appearance with no visible system border:

```swift
// NSWindow configuration (HistoryWindow, MenuBarWindowConfigurator)
window.appearance = NSAppearance(named: .darkAqua)
window.titlebarAppearsTransparent = true
window.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)
window.hasShadow = false

// Content view layer (removes system border)
contentView.wantsLayer = true
contentView.layer?.backgroundColor = navyColor.cgColor
contentView.layer?.cornerRadius = 10
contentView.layer?.masksToBounds = true
contentView.layer?.borderWidth = 0
contentView.layer?.borderColor = NSColor.clear.cgColor
```

**OnboardingWindow exception**: Borderless floating window with `hasShadow = true`, `cornerRadius = 20`, `level = .floating`. Uses shadow because it's a standalone floating window without system chrome to anchor it visually.

### App Icon

Dark navy rounded rectangle background (`#0C0C1A`) with blue-to-purple gradient waveform bars (`#5B6CF7` → `#8B5CF6`). Subtle radial glow behind the waveform. Generated programmatically at all macOS icon sizes (16px through 1024px).

### Dark Mode Philosophy — Always Dark

1. **Always dark** — All windows force dark appearance. No light mode support. Deep navy backgrounds, not gray.
2. **Background layering** — sidebar (`#0A0A18`) → main (`#0C0C1A`) → cards (`#14142B`) → elevated (`#1C1C3A`). Separation via layering, not borders.
3. **Borders are nearly invisible** — `white.opacity(0.06)`. Present for subtle definition, not separation.
4. **Shadows are minimal** — 50-60% lower than typical. Depth comes from color layering.
5. **White text with opacity** — Primary (100%), secondary (50%), tertiary (35%). No gray hex values.
6. **Blue-purple accent pops naturally** — Keep accent opacities restrained so colors feel electric, not washed out.

### Color Hex Extension

Defined at the bottom of `HistoryWindowView.swift`. Supports 3, 6, and 8 character hex strings:

```swift
Color(hex: "22C55E")     // 6-char
Color(hex: "FF22C55E")   // 8-char with alpha
```

---

## 2. Typography

Whisperer uses **explicit font sizes** with `.system(size:weight:design:)` in workspace and onboarding windows. The menu bar panel uses `.caption` / `.caption2` for compact secondary text (info card labels, model size/speed, badge text, permission descriptions) where the smaller semantic sizes fit the dense layout.

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

| Usage | Font Specification |
|-------|-------------------|
| Page/section title | `.system(size: 26, weight: .bold, design: .rounded)` |
| Onboarding title | `.system(size: 24, weight: .bold, design: .rounded)` |
| Stat card value (detail) | `.system(size: 20, weight: .light, design: .rounded)` |
| Workspace name | `.system(size: 20, weight: .bold, design: .rounded)` |
| Detail date header | `.system(size: 18, weight: .bold, design: .rounded)` |
| Header stat value | `.system(size: 18, weight: .light, design: .rounded)` |
| Sidebar stat value | `.system(size: 16, weight: .light, design: .rounded)` |
| Menu bar app name | `.system(size: 16, weight: .bold)` |
| Brand name (sidebar) | `.system(size: 15, weight: .bold, design: .rounded)` |
| Section header | `.system(size: 15, weight: .bold, design: .rounded)` |
| Setting label | `.system(size: 14, weight: .semibold)` |
| Body text (transcription) | `.system(size: 14, weight: .regular)` + `.lineSpacing(5)` |
| Text preview (row) | `.system(size: 13.5, weight: .regular)` + `.lineSpacing(3)` |
| Menu bar section title | `.system(size: 13, weight: .semibold)` |
| Field title | `.system(size: 13, weight: .medium)` + `.tracking(0.3)` |
| Sidebar nav item | `.system(size: 13, weight: .medium/.semibold)` |
| Row time | `.system(size: 12, weight: .bold, design: .rounded)` |
| Filter tab | `.system(size: 12, weight: .semibold/.medium)` |
| Menu bar body text | `.system(size: 12, weight: .regular)` |
| Section label (detail) | `.system(size: 11, weight: .bold, design: .rounded)` + `.tracking(0.8)` |
| Date section header | `.system(size: 11, weight: .bold, design: .rounded)` + `.tracking(0.5)` |
| Metadata pill text | `.system(size: 10.5, weight: .medium)` |
| Stat card label | `.system(size: 10, weight: .bold)` + `.tracking(1.0)` |
| Header stat label | `.system(size: 9, weight: .semibold)` + `.tracking(0.8)` |
| Live transcription text | `.system(size: 16, weight: .regular, design: .rounded)` + `.lineSpacing(5)` |
| Live transcription header | `.system(size: 11, weight: .bold, design: .rounded)` + `.tracking(1.2)` |
| Menu bar info card label | `.caption` (compact secondary) |
| Menu bar model size/speed | `.caption2` (compact tertiary) |
| Menu bar badge text | `.caption2` (compact) |
| Onboarding hero title | `.system(size: 40, weight: .bold)` + gradient |
| Onboarding page title | `.system(size: 34, weight: .bold)` |
| Onboarding feature pill | `.system(size: 12, weight: .medium)` |

### Design Variants

- **`.rounded`** — Titles, brand text, section headers, stat values, modal headers
- **`.monospaced`** — Dictionary entries, time formats, keyboard shortcuts, code-like data
- **Default** — Body text, form labels, descriptions, metadata, helper text

---

## 3. Layout Patterns

### Workspace Window (HistoryWindow + HistoryWindowView)

- Custom `HStack(spacing: 0)` with collapsible sidebar (220pt)
- Window: 1100x750 default, 700x700 min
- Dark chrome: transparent titlebar, navy background, no shadow, no border
- NSToolbar `.unified` with sidebar toggle

### Onboarding Window (OnboardingWindow + OnboardingView)

- Frame: 860x540, borderless NSWindow, `level = .floating`, `hasShadow = true`, corner radius 20
- Four pages: Welcome (full-width splash), Permissions (microphone), System-Wide Dictation, Features
- Pages 1-3 use two-column layout: left content + right decorative panel (340pt)
- Welcome page: Full-width centered with app icon (120x120), hero title (40pt gradient), feature pills
- Right panels: Decorative with concentric circles, radial gradients (280x280), and large icons
- Page indicator dots: Active = accentBlue capsule (24x8), Inactive = white.opacity(0.2) circle (8x8)
- Shown on first launch (`hasCompletedOnboarding` UserDefaults)
- Launches permissions and system-wide dictation setup during onboarding

### Menu Bar Panel (MenuBarView)

- Frame: 360x580
- `MBColors` enum, `.environment(\.colorScheme, .dark)`
- `MenuBarWindowConfigurator` NSViewRepresentable for flat window
- 3-tab layout with colorful per-tab icons
- Footer: gradient Workspace + red Quit buttons

### Overlay HUD (OverlayView + OverlayPanel)

- `NSPanel` borderless, non-activating, no shadow, `canJoinAllSpaces`
- Navy capsule background (`#14142B`) with blue accent elements and `white.opacity(0.06)` border
- Panel: 420x220, bottom-center with 10pt bottom margin
- Recording indicator: Blue circle (44x44) with pulsing dot (10x10)
- Mic button: Blue circle (36x36) with accent opacity 0.15 background
- Transcribing state: 3 animated dots in blue circle (36x36)
- Processing state: 4 animated gradient bars (blue → purple)
- Close button: Red circle (36x36) with red.opacity(0.1) background

---

## 4. Components

### Icon Containers (Colorful Tinted Style)

```swift
ZStack {
    RoundedRectangle(cornerRadius: 6)
        .fill(color.opacity(0.15))
        .frame(width: 26, height: 26)
    Image(systemName: icon)
        .foregroundColor(color)
        .font(.system(size: 12, weight: .medium))
}
```

Size variants (frame size / corner radius / icon size):
- 24pt / 6 / 11 — detail view section labels
- 26pt / 6 / 12 — menu bar settings cards, model section headers
- 34pt / 8 / 15 — onboarding feature grid cards
- 36pt / 8 / 16 — menu bar info cards, in-app transcription card
- 40pt / 10 / 17 — onboarding privacy/step cards

### Toggle Switches

```swift
Toggle("", isOn: $binding).toggleStyle(.switch).tint(accent).labelsHidden()
```

Uses `#5B6CF7` blue accent tint across all windows.

### Model Selection Radio Buttons

Blue accent (#5B6CF7) circle stroke + fill. Downloaded checkmark also blue accent.

### Metadata Pills (TranscriptionRow)

Colorful capsules: WPM (orange), Words (blue), Language (red).

### Search Fields — custom HStack, NOT `.searchable()`

### Empty States — custom pattern, NOT `ContentUnavailableView`

### Filter Tabs — flat accent when selected, NOT gradient

Selected: flat `color` fill, white text, `.semibold`, shadow `color.opacity(0.25)`. Unselected: clear background, 1px border, `.medium`, secondary text. Shape: Capsule. Padding: horizontal 14, vertical 7.

### LiveTranscriptionCard

Speech bubble card shown during streaming transcription:
- Width: 380pt, card surface background (`#14142B`), border `accentPurple.opacity(0.15)` 1px
- Header: "LIVE TRANSCRIPTION" — 11pt bold rounded, tracking 1.2, gradient text (blue → purple)
- Pulsing gradient dot (8x8) with glow ring (16x16)
- Text: 16pt regular rounded, white.opacity(0.9), lineSpacing 5, 72pt frame height
- Divider: gradient `[accentBlue.opacity(0.3), accentPurple.opacity(0.3), clear]`, 0.5pt
- Speech bubble arrow: Triangle pointing down, 20x10

### Sidebar Stat Card

Gradient card in sidebar showing recording stats:
- Gradient background: `accent.opacity(0.1)` → `accent.opacity(0.04)` → `cardBackground`, topLeading → bottomTrailing
- Border: 1px gradient stroke
- Shadow: `accent.opacity(0.08)`, radius 8, y 2
- Corner radius: 12, padding: 16
- Stat labels: 11pt semibold, tracking 0.8, secondary text
- Stat values: 16pt light rounded, per-stat colors (accentBlue, red, orange, cyan)

### File Locations

| File | Contents |
|------|----------|
| `HistoryWindowView.swift` | WhispererColors, Color hex extension, sidebar, TranscriptionsView, FilterTab, settings |
| `TranscriptionDetailView.swift` | Detail panel, DetailStatCard, section labels |
| `TranscriptionRow.swift` | List row, RowActionButton, colorful metadata pills |
| `WhispererApp.swift` | MBColors, MenuBarView, MenuBarWindowConfigurator, all menu bar tabs |
| `OnboardingView.swift` | OnboardingColors, four onboarding pages, feature grid |
| `OnboardingWindow.swift` | Borderless floating NSWindow for onboarding |
| `OverlayView.swift` | HUD overlay, RecordingIndicator, MicButton, processing states |
| `OverlayPanel.swift` | NSPanel subclass, positioning, visibility |
| `LiveTranscriptionCard.swift` | Live transcription bubble, TypewriterAnimator, speech bubble |
| `WaveformView.swift` | Waveform visualization bars (blue, 20 bars) |
| `ShortcutRecorderView.swift` | Shortcut recorder, key caps, mode buttons |
| `PurchaseView.swift` | Pro Pack purchase UI, gradient CTA, feature list |
| `HistoryWindow.swift` | NSWindow subclass, dark chrome, toolbar |
| `DictionaryView.swift` | Dictionary entries list, workspace dictionary tab |
| `DictionaryPacksView.swift` | Dictionary pack management UI |
| `AddDictionaryEntryView.swift` | Add/edit dictionary entry form |
| `AudioPlayerView.swift` | Audio playback controls for recordings |
| `KeywordHighlighter.swift` | Gradient text highlighting for keywords |
| `HighlightedText.swift` | Highlighted text rendering helper |

---

## 5. Anti-Patterns

### Colors
- DO NOT use `.background(.ultraThinMaterial)` — use dark navy backgrounds
- DO NOT use `.foregroundStyle(.primary/.secondary)` — use explicit white / white.opacity()
- DO NOT use `Color(nsColor: .windowBackgroundColor)` — use navy background
- DO NOT use `Color.green` for accents — use `#5B6CF7` blue or per-element colors
- DO NOT use shadow opacity above `0.15` for `Color.black`
- DO NOT rely on borders for separation — use background layering
- DO NOT use system blue for toggles — use `.tint(accent)` (#5B6CF7)
- DO NOT use `window.hasShadow = true` — use flat appearance (exception: OnboardingWindow uses shadow as a borderless floating window)

### Typography
- DO NOT use `.bold` for large display numbers (20pt+) — use `.light`
- DO NOT use uppercase text without tracking
- DO NOT use `.title` / `.body` / `.headline` / `.subheadline` semantic styles — use explicit `.system(size:weight:)`. Exception: `.caption` / `.caption2` are permitted in menu bar for compact secondary text (info labels, badge text, model specs)
- DO NOT use `.rounded` for body text — reserve for titles and stat values

### Layout
- DO NOT use `NavigationSplitView` — custom `HStack(spacing: 0)`
- DO NOT use `.listStyle(.sidebar)` — custom SidebarNavItem
- DO NOT put filters on same row as search

### Components
- DO NOT use `ContentUnavailableView` — custom empty state
- DO NOT use `.searchable()` — custom search field
- DO NOT use plain bare icons for section labels — wrap in colorful tinted container
- DO NOT use gradient on filter tabs or toggles — flat accent only
- DO NOT create cards without shadows

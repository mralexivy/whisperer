---
name: design-layout
description: Use when building or modifying window layouts, panels, sidebars, headers, or multi-column views in Whisperer. Covers workspace window structure, overlay HUD, menu bar panel, detail panel, resizable dividers, and window management.
---

# Whisperer Layout Patterns

## Workspace Window (HistoryWindow + HistoryWindowView)

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

## Transcriptions View (List + Detail)

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

## Detail Panel (TranscriptionDetailView)

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

## Menu Bar Panel (MenuBarView)

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

## Overlay HUD (OverlayView + OverlayPanel)

- `NSPanel` with `[.borderless, .nonactivatingPanel]`, `hasShadow = false`
- Background: `Capsule()` — dark: `Color(white: 0.15)`, light: `Color(white: 0.98)`
- Stroke: `Color.gray.opacity()` — dark: 0.2, light: 0.1
- Panel size: **420x220**, bottom-center with 10pt margin
- Content pinned to bottom via Auto Layout

## Window Management (HistoryWindowManager)

Singleton managing workspace window lifecycle:
- `showWindow()` — creates lazily, makes key
- `showWindowAndDismissMenu()` — dismisses MenuBarExtra panel first, then shows workspace
- `dismissMenuBarWindow()` — finds MenuBarExtra NSPanel by checking `window is NSPanel` (skipping known windows), uses `orderOut(nil)` not `close()`

## What NOT to Do

- DO NOT use `NavigationSplitView` — workspace uses custom `HStack(spacing: 0)`
- DO NOT use flexible header height — all three headers must be exactly 84pt
- DO NOT use `.listStyle(.sidebar)` — sidebar uses custom SidebarNavItem components

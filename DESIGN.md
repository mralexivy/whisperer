---
version: alpha
name: Whisperer
description: >
  Native macOS dark-navy design system for Whisperer — workspace window, menu bar, overlay
  HUD and onboarding. Follows the DESIGN.md format (github.com/google-labs-code/design.md):
  tokens here, the reasoning below. SwiftUI sources of truth: `WhispererColors`
  (Whisperer/History/HistoryWindowView.swift), `MBColors`, `OnboardingColors`.
colors:
  background: "#0C0C1A"
  surface: "#14142B"
  sidebar: "#0A0A18"
  elevated: "#1C1C3A"
  primary: "#5B6CF7"
  primary-dark: "#4C5DE8"
  secondary: "#8B5CF6"
  text-primary: "#FFFFFF"
  text-secondary: "rgba(255,255,255,0.5)"
  text-tertiary: "rgba(255,255,255,0.35)"
  border: "rgba(255,255,255,0.06)"
  pill: "rgba(255,255,255,0.08)"
  success: "#10B981"
  warning: "#F59E0B"
  danger: "#EF4444"
  info: "#06B6D4"
  vendor-anthropic: "#D97757"
  vendor-openai: "#10A37F"
  vendor-google: "#4285F4"
typography:
  page-title:
    fontFamily: SF Pro
    fontSize: 26px
    fontWeight: 300
  section-label:
    fontFamily: SF Pro
    fontSize: 11px
    fontWeight: 600
    letterSpacing: 1.2px
  row-title:
    fontFamily: SF Pro
    fontSize: 14px
    fontWeight: 600
  body:
    fontFamily: SF Pro
    fontSize: 13px
    fontWeight: 400
  caption:
    fontFamily: SF Pro
    fontSize: 11px
    fontWeight: 500
  code:
    fontFamily: SF Mono
    fontSize: 12px
    fontWeight: 400
rounded:
  pill: 999px
  sm: 7px
  md: 8px
  row: 12px
  card: 14px
spacing:
  gutter: 32px
  section: 28px
  card-padding: 20px
  row-padding-x: 14px
  row-padding-y: 12px
  stack: 8px
components:
  primary-button:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.md}"
    padding: 8px 14px
  secondary-button:
    backgroundColor: "{colors.elevated}"
    textColor: "{colors.text-primary}"
    rounded: "{rounded.md}"
    padding: 8px 12px
  choice-row:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.row}"
    padding: 12px 14px
  status-pill:
    rounded: "{rounded.pill}"
    padding: 4px 9px
  provider-badge:
    rounded: "{rounded.pill}"
    padding: 3px 8px
---

# Whisperer Design System

## Overview

Whisperer is a private, native Mac tool: calm, dark, precise. Surfaces are dark navy,
interaction is blue→purple, and every element has its own color so a screen reads at a
glance. The best references in the app are **Workspace → LLM** (`LLMPageView`) and
**Workspace → MCP** (`MCPConnectPageView`) — rebuild any settings or "connect" screen on
their pattern:

1. **One question per screen, answered first.** Show the current state before any choice
   (LLM: an animated "Your meeting → AI → Notes" banner; MCP: a hero with the live server
   status and one big switch).
2. **One list or grid of choices, not stacked cards of options.** Detected or ready items
   first, the rest after or behind "More…". Each item is a row/tile with icon, name, one
   plain sentence, a status pill and a selection indicator.
3. **Progressive disclosure in place.** Clicking an item either does the thing, or unfolds
   the one step it still needs *inside that item* (consent, numbered sign-in steps, a key
   field, "Show config"). No modal sheets for the main flow.
4. **One primary action at a time** (gradient), everything else secondary. After it: visible
   success (checkmark draw-in), then automatic verification (connection test, readiness).
5. **Plumbing is collapsed.** Ports, tokens, endpoints, network → one "Advanced" disclosure,
   each setting with a plain-language line.
6. **Motion explains state changes**, never decorates: springs on expand/select, a moving dot
   or sheen for "working", pulses for "live". Always honor Reduce Motion.
7. **Say who did it with an icon and a name**, never a sentence ("ChatGPT", not "Answered by
   ChatGPT"). See *Provider identity* under Components.

## Table of Contents

1. [Colors](#colors) — Unified dark navy palette, blue-purple accents, per-element colorful icons
2. [Typography](#typography) — Font scale, weight ladder, tracking, design variants
3. [Layout](#layout) — Workspace window, sidebar, panels, overlay HUD, onboarding, settings pages
4. [Elevation & Depth](#elevation--depth) — Card shadows, glows, hover lift
5. [Shapes](#shapes) — Corner radii by element
6. [Components](#components) — Cards, rows, buttons, choice lists, connect flow, provider badges, motion
7. [Do's and Don'ts](#dos-and-donts) — Collected rules, including interaction guardrails

---
## Colors

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

## Typography

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

## Layout

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
- Panel: 420x300 (medium), bottom-center with 10pt bottom margin. Dynamically resizes when live transcription card expands.
- Recording indicator: Blue circle (44x44) with pulsing dot (10x10)
- Mic button: Blue circle (36x36) with accent opacity 0.15 background
- Transcribing state: 3 animated dots in blue circle (36x36)
- Processing state: 4 animated gradient bars (blue → purple)
- Close button: Red circle (36x36) with red.opacity(0.1) background

---

### Settings & Connect Pages (LLMPageView, MCPConnectPageView)

- Content column centered, `maxWidth: 860`, `32pt` side gutter, `28pt` between sections.
- Order: header (gradient icon tile + 26pt `.light` title + one-sentence subtitle) → current
  state banner / hero → the choice list or grid → secondary sections → Privacy/Advanced last.
- Section labels: 11pt semibold, uppercase, `tracking(1.2)`, tertiary text, with one 13pt
  secondary sentence under them saying what the section decides.
- Group labels inside a list: 10pt semibold uppercase `tracking(1.0)` + an 11pt hint.

## Elevation & Depth

- Every card and row has a shadow: rest `black 5%, r4, y1`; hover `black 12%, r8, y3`.
- The selected item glows: `primary 45%, r6` around its 1.5pt `primary` ring.
- Hero/state banners carry a soft colored shadow (`primary 12%, r10, y3`); primary buttons
  `secondary 20%` at rest → `45%, r8` on hover.
- Hover never moves layout: change fill, shadow and at most `scaleEffect(1.02)` on buttons.

## Shapes

- Pills, chips, badges, status: capsule. Buttons and inputs: 8pt. Icon tiles: 7–9pt.
- Choice rows and panels: 12pt. Cards and hero banners: 14pt. Use `.continuous` corners for
  app-icon-like marks.

## Components

### Choice List (LLM page) — `ChoiceRow` in LLMPageView.swift

The pattern for "pick one of N":

- Row: 36pt icon (the item's real icon when there is one) · title 14pt semibold + optional
  orange PREVIEW pill · one-line 12pt subtitle · `StatusPill` · radio (check fills on select).
- Selection ring is one `matchedGeometryEffect`, so it *slides* between rows.
- Tapping a row: ready + allowed → select; ready + not allowed → inline consent panel;
  not ready → inline setup (numbered steps, `CommandPill` with Copy→Copied, "Check again");
  the row already in use → inline manage panel. Logic lives in a controller
  (`ConnectedAIPageController`) so it is unit-tested; the view only renders.
- Inline panel: separated by a 1pt border, indented under the title (64pt), unfolds with
  `.move(edge: .top) + .opacity`.
- `StatusPill`: dot + text in a tinted capsule; green ready, amber needs-attention,
  red error, grey neutral; a pulsing halo while checking; a 2pt progress bar for downloads.

### Connect Flow (MCP page) — MCPConnectPageView + MCPClientConnectPanel

The pattern for "connect X to Y":

- Hero: value sentence, live status (`MCPPulsingDot`), one big switch, then fact chips
  (`MCPChip`: "Only this Mac", "Read-only", "1 app connected") and the URL with `MCPCopyButton`.
- Grid of app tiles (min 260pt): detected apps first with a badge (Connected → Needs update →
  Installed), the rest under a collapsed "More apps (n)".
- Selecting a tile opens one panel: three numbered step cards (what happens, what to do,
  what to try), one gradient button ("Connect to Codex", or "Copy setup" when it can't write),
  "Show config" disclosure (`MCPCodeBlock`, path + Reveal). Success → `MCPSuccessCheck`
  draw-in → automatic connection test → inline result with a fix suggestion on failure.
- Every side effect (install, copy, reveal, test, detect) goes through an injectable
  actions struct (`MCPConnectActions`) so click tests never touch real config files.

### Provider Identity — `ProviderMark` / `ProviderBadge` (ProviderBadge.swift)

- An AI is shown as **its real icon + its name**, e.g. [icon] ChatGPT. Icons come from the
  user's installed apps (ChatGPT.app, Claude.app, the Codex icon inside ChatGPT.app,
  Antigravity/Gemini); nothing is bundled. Fallback: vendor-colored glyph tile
  (Anthropic `#D97757`, OpenAI `#10A37F`, Google `#4285F4`).
- Never a sentence around it: no "by", "Answered by", "Powered by", "Polished by". The
  tooltip says what the AI did; a green check may follow when an action completed.
- Use the same mark everywhere the AI acted: overview, Ask AI chip and each answer, transcript
  polish, meeting list rows, settings rows.

### Motion

- Expand/collapse and selection: `.spring(response: 0.38, dampingFraction: 0.86)`.
- Working: a moving sheen (`LinearGradient` offset, 1.4s linear repeat) or a travelling dot;
  live: pulsing halo; done: checkmark draw-in or `.scale + .opacity` transition.
- Copy buttons morph to "Copied ✓"; counters use `.contentTransition(.numericText())`.
- Read `@Environment(\.accessibilityReduceMotion)` and drop repeating animations when set.

### Testability (required for new screens)

- Tag every interactive control with `.uiTestFrame("screen.control.id")` and set
  `.environment(\.uiTestScope, …)` on the page; write click tests that send real mouse
  events (see `LLMPageClickTests`, `MCPConnectPageClickTests`, docs/knowledge/ui/).
- Keep behavior in a controller/model object; the view forwards clicks to it.

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
- Expand/collapse button: rightmost header element (after badges), 22x22pt circle hit target, `chevron.up.2`/`chevron.down.2` icon (9pt semibold blueAccent), hover glow + 1.12x scale. Dimmed (0.3 opacity) when content fits, normal (0.7) when overflow, full (1.0) on hover.
- Text: 16pt regular rounded, white.opacity(0.9), lineSpacing 5, 72pt minimized / up to 340pt expanded
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
| `OverlayPanel.swift` | NSPanel subclass, positioning, visibility, dynamic height for expanded card |
| `LiveTranscriptionCard.swift` | Live transcription bubble, expand/collapse toggle, TypewriterAnimator, speech bubble |
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

## Do's and Don'ts

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

### Interaction Guardrails

- **Never put a hit-testable view on top of a control.** An `.overlay { RoundedRectangle().stroke() }`
  on a row swallowed every click on its button. Borders/rings go in `.background { }`, or add
  `.allowsHitTesting(false)`.
- Don't add a second sheet or modal for something that can unfold in place.
- Don't show more than one gradient button in a view.
- Don't show a disabled control without saying why (status pill or one-line hint).
- Don't use jargon in the main flow (ports, tokens, schemas) — it belongs under Advanced.
- Don't attribute with a sentence ("by ChatGPT") — use `ProviderBadge`.

# Design Check — Quick Design System Compliance

Scan recently changed UI files for design system violations. Run this before committing UI changes.

## Step 1: Identify Changed UI Files

Run `git diff --name-only HEAD` and filter for Swift files in UI/, History/, or any file ending in View.swift, Window.swift, Row.swift, or Card.swift.

If no UI files changed, report "No UI files changed — nothing to check" and stop.

## Step 2: Load Relevant Design Skills

Load these skills based on what you'll be checking:
- `design-colors` — color system rules
- `design-typography` — font scale rules
- `design-components` — component patterns and anti-patterns

## Step 3: Scan Each Changed File

For each changed UI file, check for these violations:

### Color Violations
- [ ] `Color.primary` or `Color.secondary` used in workspace views (should be `WhispererColors.primaryText()` / `.secondaryText()`)
- [ ] `NSColor.windowBackgroundColor` or `.controlBackgroundColor` in workspace (should be `WhispererColors.background()`)
- [ ] `Color.green` or system greens (should be `WhispererColors.accent` or per-surface green)
- [ ] `.foregroundStyle(.primary)` or `.foregroundStyle(.secondary)` (should use WhispererColors)
- [ ] `Color(nsColor: .separatorColor)` (should be `WhispererColors.border()`)
- [ ] `.background(.ultraThinMaterial)` or `.regularMaterial` (should use WhispererColors backgrounds)

### Typography Violations
- [ ] `.font(.body)`, `.font(.title)`, `.font(.caption)` or other semantic text styles (should be explicit `.system(size:weight:design:)`)
- [ ] Uppercase text without `.tracking()` applied
- [ ] `.bold` weight on text 20pt or larger (should be `.light` for elegance)

### Component Violations
- [ ] `ContentUnavailableView` (should use custom empty state pattern)
- [ ] `.searchable()` modifier (should use custom search field)
- [ ] `Picker(.segmented)` for tabs (should use custom tab pattern)
- [ ] Cards or containers without `.shadow()` (every card needs depth)
- [ ] Hover states without any visual change (must have at least one: color, scale, shadow, or border)
- [ ] Plain icons for section labels (should wrap in gradient container with shadow)
- [ ] Gradient fill on play button or filter tabs (should use flat `WhispererColors.accent`)

## Step 4: Report

For each violation found, report:
- File path and line number
- What was found
- What it should be instead

If no violations found, report "Design check passed — no violations found."

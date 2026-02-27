# Design Check — Quick Design System Compliance

Scan recently changed UI files for design system violations. Run this before committing UI changes.

## Step 1: Identify Changed UI Files

Run `git diff --name-only HEAD` and filter for Swift files in UI/, History/, or any file ending in View.swift, Window.swift, Row.swift, or Card.swift.

If no UI files changed, report "No UI files changed — nothing to check" and stop.

## Step 2: Load Design Reference

Read `DESIGN.md` for the complete design system (unified dark navy palette, blue-purple accents, colorful icons, typography, layout, components, anti-patterns).

## Step 3: Scan Each Changed File

For each changed UI file, check for these violations:

### Color Violations
- [ ] `Color.primary` or `Color.secondary` used anywhere (should be explicit `Color.white` / `Color.white.opacity()`)
- [ ] `NSColor.windowBackgroundColor` or `.controlBackgroundColor` (should be navy background `#0C0C1A`)
- [ ] `Color.green` used as an accent color (should be `accent` #5B6CF7 blue or per-element colorful color)
- [ ] `.foregroundStyle(.primary)` or `.foregroundStyle(.secondary)` (should use explicit white/white.opacity)
- [ ] `Color(nsColor: .separatorColor)` (should be `white.opacity(0.06)`)
- [ ] `.background(.ultraThinMaterial)` or `.regularMaterial` (should use dark navy backgrounds)
- [ ] System blue for toggles without `.tint(accent)` (all toggles must use `.tint(accent)` #5B6CF7)
- [ ] `window.hasShadow = true` (all windows must be flat with `hasShadow = false`)
- [ ] Gray hex values for backgrounds (should be navy: #0C0C1A, #14142B, #0A0A18, #1C1C3A)
- [ ] Light mode colors or `colorScheme` adaptive logic that produces non-navy backgrounds

### Icon Violations
- [ ] Plain bare `Image(systemName:)` for section headers without tinted container (should wrap in `ZStack { RoundedRectangle + Image }` with `color.opacity(0.15)` fill)
- [ ] All section icons using the same color (should use per-element colorful colors)
- [ ] Green icons where blue accent should be used

### Typography Violations
- [ ] `.font(.body)`, `.font(.title)`, `.font(.caption)` or other semantic text styles (should be explicit `.system(size:weight:design:)`)
- [ ] Uppercase text without `.tracking()` applied
- [ ] `.bold` weight on text 20pt or larger (should be `.light` for elegance)

### Component Violations
- [ ] `ContentUnavailableView` (should use custom empty state pattern)
- [ ] `.searchable()` modifier (should use custom search field)
- [ ] `Picker(.segmented)` for tabs (should use custom tab pattern)
- [ ] Cards or containers without `.shadow()` (every card needs depth)
- [ ] Hover states without any visual change
- [ ] Gradient fill on filter tabs or toggles (should use flat `accent`)

## Step 4: Report

For each violation found, report:
- File path and line number
- What was found
- What it should be instead

If no violations found, report "Design check passed — no violations found."

---
name: design-typography
description: Use when working with text, fonts, or typography in Whisperer UI. Covers the Jony Ive-inspired font scale, weight ladder, tracking rules, line spacing, and design variants (.rounded, .monospaced).
---

# Whisperer Typography System

Whisperer uses **explicit font sizes** with `.system(size:weight:design:)`, never semantic styles (`.body`, `.title`, `.caption`).

## Core Principles

1. **Weight contrast = hierarchy** — `.light` for large display text (stat values, hero numbers). `.bold` for smaller structural elements (section titles, nav items). The bigger the text, the lighter the weight.
2. **`.rounded` = warmth** — SF Rounded for ALL titles, stat values, brand text, section headers. Default (non-rounded) for body copy, form labels, metadata.
3. **Tracking = breathing room** — Uppercase labels MUST have tracking (0.5-1.2). Prevents cramped look, adds premium quality.
4. **Line spacing = readability** — Body text uses `.lineSpacing(4-6)`. Default line spacing is too tight for premium feel.
5. **Opacity for sub-hierarchy** — Within the same color, use `.opacity(0.7)` or `.opacity(0.5)` for additional layers without new colors.

## Weight Ladder

| Weight | Usage | Feel |
|--------|-------|------|
| `.light` | Large stat values (20pt+), hero numbers | Elegant, airy, premium |
| `.regular` | Body text, descriptions, placeholder text | Clean, readable |
| `.medium` | Nav items (unselected), form labels, metadata | Functional, clear |
| `.semibold` | Field titles, selected nav items, button text, filter tabs | Emphasized, interactive |
| `.bold` | Section titles, brand name, uppercase labels, date headers | Structural, anchoring |

## Standard Scale

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

## Design Variants

- **`.rounded`** — Titles, brand text, section headers, stat values, modal headers. The app's typographic signature.
- **`.monospaced`** — Dictionary entries, time formats, keyboard shortcuts, code-like data.
- **Default** — Body text, form labels, descriptions, metadata, helper text.

## Tracking Guide

| Text Size | Tracking | Usage |
|-----------|----------|-------|
| 9-10pt uppercase | `1.0-1.2` | Stat labels, tiny uppercase captions |
| 11pt uppercase | `0.5-0.8` | Section labels, date headers, sidebar labels |
| 12-13pt | `0.2-0.3` | Field titles, category badges (optional) |
| 14pt+ | `0` | Body text, titles — no tracking needed |

## What NOT to Do

- DO NOT use `.bold` for large display numbers (20pt+) — use `.light` for elegance
- DO NOT use uppercase text without tracking — looks cramped and cheap
- DO NOT use `.title` / `.body` / `.caption` semantic styles — always explicit sizes
- DO NOT use the same weight for everything — weight ladder creates visual rhythm
- DO NOT skip `.lineSpacing()` on multi-line body text — default is too tight
- DO NOT use `.rounded` for body text or metadata — reserve for titles and stat values

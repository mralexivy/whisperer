# Whisperer v1.1 (4) — Local Test Build

**Date**: 2026-03-08
**Config**: Release (arm64, no sandbox)
**Signing**: Apple Development (ialex.ivy@gmail.com)
**Entitlements**: whisperer-nosandbox.entitlements (no App Sandbox)

---

## What's New

### Phase 1: Bug Fixes & Reliability

- **Word count fix** — Fixed `split(separator: " ")` failing on newlines and multiple spaces. Now uses `components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }`. Affects WPM, statistics, and all word-based metrics.
- **AudioStartupGate** — Actor-based gate replaces fragile `asyncAfter(0.5)` for CoreAudio initialization. Prevents EXC_BAD_ACCESS from audio init during SwiftUI AttributeGraph processing. Uses 2 runloop yields + 3s safety timeout.
- **Overlay generation counter** — Prevents stale animation handlers from hiding a visible overlay panel during rapid state changes.
- **Active app icon in overlay** — Shows the frontmost app's icon (20x20 rounded) in the recording overlay via `NSWorkspace.shared.frontmostApplication?.icon`.

### Phase 2: Statistics Enhancements

- **Time saved metric** — Calculates time saved vs typing. Formula: `(totalWords / typingWPM) - (totalWords / speakingWPM)`. Editable typing speed (default 40 wpm). Displayed as a new summary card.
- **Milestones system** — Achievement milestones for words (1K-500K), sessions (50-5K), streak (7-365 days). Shows next milestone with gradient progress bar and achieved milestones in a 2-column grid.
- **Personal records** — Tracks longest transcription, most words in a day, most sessions in a day, and best streak. Displayed with colored icon rows.
- **Best streak tracking** — Persists best-ever streak in UserDefaults (survives streak breaks).

### Phase 3: Rewrite Mode (Local LLM)

- **Text selection service** — Read-only AX calls to get selected text from any app. Uses `kAXSelectedTextAttribute` with 100ms timeout. App Store safe (read-only, no `SetAttributeValue`).
- **Rewrite mode** — Hold rewrite hotkey + speak instruction to rewrite selected text via local MLXLLM. Falls back to "write mode" if no text selected. Purple accent (#8B5CF6) overlay.
- **Rewrite shortcut** — Separate Carbon hotkey (ID 3) for rewrite mode. Configurable via `ShortcutConfig.rewriteShortcut`.
- **Prompt profiles** — Named prompt presets (Default, Coding, Email, Creative) with custom dictation and rewrite prompts. CRUD + UserDefaults persistence.

### Phase 4: Command Mode (Non-Sandbox Only)

- **Terminal service** — `Process()`-based shell execution with destructive command detection, 30s timeout, `#if !ENABLE_APP_SANDBOX` gated.
- **Command mode service** — Agentic voice-to-terminal loop via local LLM. Max 20 turns, streaming output, destructive command confirmation.
- **Chat history** — JSON-persisted chat sessions (max 50) in `~/Library/Application Support/Whisperer/ChatHistory/`.
- **Command mode UI** — Chat-style conversation view with message bubbles, tool result cards, pending command confirmation, new/recent/delete chat controls.

### Phase 5: UI Enhancements & Polish

- **Overlay customization** — Position picker (bottom center, top center, bottom left, bottom right) and size picker (small, medium, large). Persisted to UserDefaults with live repositioning via NotificationCenter.
- **Sound customization** — Default / Subtle / Silent sound options for recording start/stop cues. Persisted to UserDefaults.
- **File transcription: chunked reading** — Memory-efficient frame-position-based reading instead of loading entire file. Handles multi-hour files without OOM.
- **File transcription: export** — Export as TXT (with metadata header) or JSON (structured with metadata). Uses NSSavePanel with existing entitlement.
- **File transcription: ETA & speed** — Shows estimated time remaining during transcription and speed multiplier on completion (e.g., "12.5x").
- **Setup checklist** — Persistent setup tab with glow-ring progress hero, animated progress arc, step cards with hover effects, gradient CTAs, status pills.
- **Feedback form** — In-app feedback via NSSharingService email composer. Two-column layout with contact/system info. Hover effects on system info rows, feedback type pills, gradient dividers.
- **Settings polish** — Sub-labels under Overlay and Rewrite Mode section headers. CAF format support for file transcription.

---

## Files Changed (17 modified, 10 new)

### Modified
| File | Changes |
|------|---------|
| AppState.swift | ActiveMode enum, rewrite/command mode, targetAppIcon, prompt profiles |
| AudioDeviceManager.swift | Audio device recovery improvements |
| AudioRecorder.swift | Engine recovery, startup gate integration |
| SoundPlayer.swift | SoundOption enum, subtle/silent modes |
| Notification+Extensions.swift | overlaySettingsChanged notification |
| FileTranscriptionView.swift | ETA display, speed multiplier card, export menu |
| HistoryWindowView.swift | Setup/feedback sidebar items, overlay/rewrite settings sections |
| StatisticsView.swift | Time saved card, milestones, personal records, best streak |
| TranscriptionEntity.swift | Word count fix |
| TranscriptionRecord.swift | Word count fix |
| UsageStatisticsManager.swift | Time saved, milestones, personal records, best streak |
| GlobalKeyListener.swift | Rewrite + command mode hotkeys |
| ShortcutConfig.swift | Rewrite + command shortcut configs |
| FileTranscriptionManager.swift | Chunked reading, export, ETA, speed multiplier, CAF |
| OverlayPanel.swift | Generation counter, position/size customization |
| OverlayView.swift | App icon display, rewrite mode purple accent |
| WhispererApp.swift | Sound picker in menu bar, startup gate |

### New Files
| File | Purpose |
|------|---------|
| Core/AudioStartupGate.swift | SwiftUI-safe startup synchronization |
| Core/RewriteModeService.swift | AI text editing via local LLM |
| Core/PromptProfile.swift | Named prompt presets |
| Core/TerminalService.swift | Shell command execution (non-sandbox) |
| Core/CommandModeService.swift | Agentic voice-to-terminal (non-sandbox) |
| Persistence/ChatHistoryStore.swift | Command mode conversation history |
| TextInjection/TextSelectionService.swift | Read-only AX text selection |
| UI/CommandModeView.swift | Command mode chat UI |
| UI/FeedbackView.swift | In-app feedback form |
| UI/SetupChecklistView.swift | Persistent setup checklist |

---

## Testing Checklist

- [ ] Launch app — no startup crashes (AudioStartupGate)
- [ ] Hold Fn key — record and transcribe — text appears at cursor
- [ ] Check word count in history — verify correct with newlines
- [ ] Open Statistics tab — verify time saved, milestones, personal records
- [ ] Open Setup tab — verify glow ring progress, checklist items
- [ ] Open Feedback tab — verify form layout, send button
- [ ] Settings > Overlay — change position/size, verify overlay moves
- [ ] Settings > Sound — switch between Default/Subtle/Silent
- [ ] File Transcription — transcribe a file, check ETA, speed multiplier
- [ ] File Transcription — export as TXT and JSON
- [ ] Rewrite mode — configure shortcut, select text, hold shortcut + speak
- [ ] Command mode — configure shortcut, hold + speak a command (non-sandbox only)
- [ ] Memory — transcribe a long file, monitor memory usage
- [ ] Multiple recordings — verify audio engine recovery across sessions

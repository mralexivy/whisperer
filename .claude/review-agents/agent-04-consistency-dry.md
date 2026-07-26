# Agent 4 — Codebase Consistency & DRY Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file
- Reference: `AGENTS.md` (Naming Patterns, Swift Idioms, Comment Style), `DESIGN.md` (Color System, Typography)

## Output
Write to `.claude/review-state/findings/agent-04.md`
Return: `Agent 4 (Consistency & DRY): X P0, Y P1, Z P2`

## Preamble

Read `docs/knowledge/ui/rules.md` if it exists. Check all `Check:` patterns first.

## Focus Checklist

### Performance Anti-Patterns in Hot Paths

- **BUG-S08 (P2)**: `NSFont` or `NSParagraphStyle` objects allocated inside `updateNSView()` or any function called per animation frame or per word update. These are expensive objects — create them once in the `NSViewRepresentable.Coordinator.init()` and reuse. Flag: `NSFont(...)`, `NSMutableParagraphStyle()`, or `NSParagraphStyle()` anywhere inside `updateNSView()`.

### LLM Output Sanitization

- **BUG-T07 (P1)**: Prompt delimiter strings leaking into LLM output — structural delimiters like `[INPUT]`, `[/INPUT]`, `<think>`, `</think>` appear in injected text. Any LLM result processing path must strip every delimiter pattern that appears in the system or user prompt template. Check: does `LLMPostProcessor.process()` strip all possible delimiter variants? Is the stripping regex compiled once as `private static let`? Flag if regex is compiled per-call inside the function.

### Naming Patterns

Per `AGENTS.md`:
- Services: `AudioRecorder`, `WhisperBridge`, `TextInjector` — noun + verb/purpose
- Managers: `HistoryManager`, `DictionaryManager` — noun + Manager
- Views: `TranscriptionRow`, `WaveformView` — semantic name + View
- Bool flags: `isRecording`, `isModelLoaded` — `is` + adjective, never `currentState`, `recordingState`
- Callbacks: `onStreamingSamples`, `onTranscription` — `on` + purpose
- State transitions: `startRecording()`, `stopAsync()`, `cancelRecording()` — verb + noun

Flag: any new type/property/method that violates these patterns (P2).

### Reuse Before Adding

Before adding a new implementation, verify these existing helpers are not already sufficient:
- `ModelPool.previewBridge` — shared tiny whisper context; never create a separate detection bridge
- `WhispererColors` / `MBColors` / `OnboardingColors` — do not add new color literals inline
- `Logger.debug/info/warning/error` — no `print()` statements
- `SafeLock` — do not introduce raw `NSLock` without timeout
- `HistoryManager` / `DictionaryManager` — no parallel CoreData stack
- `ScriptAnalyzer` — do not duplicate Unicode range checks inline
- `AudioDeviceManager.shared` — singleton; do not create a second instance

Flag: any duplication of functionality already provided by these helpers (P2).

### Comment Style

Per `AGENTS.md` "Comment Style — WHY not WHAT":
- Comments should explain decisions, constraints, and workarounds — not restate what the code does
- No multi-line comment blocks explaining obvious behavior
- No comments referencing ticket numbers or PR descriptions (those belong in git history)
- Flag: comments that say "Set state to idle" above `state = .idle`, or "Stop the audio engine" above `engine.stop()` (P2, style)

### Constants vs Magic Numbers

Per `AGENTS.md`:
- No magic numbers — use existing constants from `AudioRecorder` (`maxRecordingSamples`, `sampleRate`), `StreamingTranscriber` (`chunkDuration`, `overlapDuration`), `LanguageRouter` (`routeThreshold`, `switchMargin`), `LLMPostProcessor` (token budget constants)
- Flag: any new numeric literal in `StreamingTranscriber` or `AudioRecorder` that should reference an existing constant (P2)

### UserDefaults Pattern

Per `AGENTS.md`:
```swift
@Published var muteOtherAudioDuringRecording: Bool = true {
    didSet {
        UserDefaults.standard.set(muteOtherAudioDuringRecording, forKey: "muteOtherAudioDuringRecording")
    }
}
```
Init must use `UserDefaults.standard.object(forKey:) != nil` guard before reading, to distinguish "never set" from "set to false". Flag any `UserDefaults.standard.bool(forKey:)` without the `object(forKey:) != nil` guard (P2).

### Guard for Preconditions

Per `AGENTS.md`:
```swift
guard state == .idle else { return }
guard let bridge = whisperBridge else { ... }
guard !samples.isEmpty else { return "" }
```
- Do not use `if let` for early returns — use `guard let`
- `guard` conditions should be at the function entry, not nested inside the body (P2)

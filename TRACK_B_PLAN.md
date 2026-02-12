# Track B: Pro Pack Feature Development

This document contains the implementation plan for Track B (Pro Pack features). These features differentiate the Pro Pack IAP from the base app.

**Status**: In Progress (B3 Personal Dictionary completed)

---

## Overview

The Pro Pack infrastructure (StoreKit 2, purchase UI) is complete. Below are the features that Pro Pack unlocks.

### Pro Pack Features

| Feature | Complexity | Priority | Status |
|---------|-----------|----------|--------|
| Code Mode | Medium | High (Flagship #1) | Pending |
| Per-App Profiles | High | High (Flagship #2) | Pending |
| Personal Dictionary | Medium | Medium | **DONE** |
| Pro Insertion Engine | Medium-High | Medium | Pending |
| Pro Dictation Controls | Medium | Low (Optional) | Pending |
| Pro Model Gating | Low | Low (Optional) | Pending |

**Remaining**: 5 features (B1, B2, B4, B5, B6)

---

## Phase B1: Code Mode

**Goal**: Enable developers to dictate code with spoken symbols and casing commands

### Files to Create

**1. `CodeMode/CodeModeProcessor.swift`**

```swift
//  CodeModeProcessor.swift
//  Processes transcribed text to replace spoken code symbols

class CodeModeProcessor {
    static let shared = CodeModeProcessor()

    // Symbol mappings
    private let symbolMappings: [String: String] = [
        "open paren": "(",
        "close paren": ")",
        "open bracket": "[",
        "close bracket": "]",
        "open brace": "{",
        "close brace": "}",
        "double quote": "\"",
        "single quote": "'",
        "equals": "=",
        "arrow": "->",
        "fat arrow": "=>",
        "less than": "<",
        "greater than": ">",
        "ampersand": "&",
        "pipe": "|",
        "colon": ":",
        "semicolon": ";",
        "comma": ",",
        "period": ".",
        "underscore": "_",
        "dash": "-",
        "plus": "+",
        "star": "*",
        "slash": "/",
        "backslash": "\\",
        "at sign": "@",
        "hash": "#",
        "dollar": "$",
        "percent": "%",
        "caret": "^",
        "tilde": "~",
        "backtick": "`"
    ]

    // Casing commands
    func applyC asingCommand(_ text: String, command: String) -> String
    func processCodeSymbols(_ text: String) -> String
    func enableLiteralMode(_ enabled: Bool)
}
```

**Features to implement**:
- Symbol replacement (word → symbol)
- Casing commands:
  - "camel case foo bar" → "fooBar"
  - "snake case foo bar" → "foo_bar"
  - "constant case foo bar" → "FOO_BAR"
  - "pascal case foo bar" → "FooBar"
  - "kebab case foo bar" → "foo-bar"
- Literal mode (disable auto-correct)
- Smart spacing around operators

### Files to Modify

**`StreamingTranscriber.swift`**
- Add code mode toggle
- Post-process transcription through CodeModeProcessor
- Add to settings

**`AppState.swift`**
- Add `@Published var isCodeModeEnabled: Bool`
- Gate behind `StoreManager.shared.isPro`

---

## Phase B2: Per-App Profiles

**Goal**: Automatically switch settings based on active application

### Files to Create

**1. `Profiles/ProfileManager.swift`**

```swift
//  ProfileManager.swift
//  Manages per-app profiles and auto-switching

import AppKit

class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [AppProfile] = []
    @Published var activeProfile: AppProfile?

    func createProfile(for bundleId: String)
    func deleteProfile(_ profile: AppProfile)
    func detectActiveApp() -> AppProfile?
    func startMonitoring()
    func stopMonitoring()
}

struct AppProfile: Codable, Identifiable {
    let id: UUID
    let appBundleId: String
    let appName: String

    // Settings per profile
    var isCodeModeEnabled: Bool
    var selectedLanguage: TranscriptionLanguage
    var punctuationStyle: PunctuationStyle
    var capitalizationStyle: CapitalizationStyle
    var customShortcut: ShortcutConfig?
}

enum PunctuationStyle {
    case automatic  // Whisper adds punctuation
    case spoken     // User speaks punctuation
}
```

**2. `UI/ProfileEditorView.swift`**
- UI to create/edit profiles
- App picker (NSRunningApplication)
- Per-profile settings editor
- Profile list with delete

### Files to Modify

**`AppState.swift`**
- Integrate ProfileManager
- Apply profile settings when active app changes
- Gate behind Pro check

### Implementation Notes

- Use `NSWorkspace.shared.frontmostApplication` to detect active app
- Use `NSWorkspace.didActivateApplicationNotification` to monitor switches
- Store profiles in UserDefaults or JSON file
- Default profile for unknown apps

---

## Phase B3: Personal Dictionary - COMPLETED

**Status**: Implemented with dictionary-based spell correction using SymSpell fuzzy matching.

**What was built**:
- Premium dictionary packs with unified pack naming
- SymSpell fuzzy matching for spell correction
- Dictionary pack dropdown in settings UI
- Integration with transcription pipeline

---

## Phase B4: Pro Insertion Engine

**Goal**: Improve text insertion reliability across all apps

### Files to Modify

**`TextInjector.swift`**

Add these features:

```swift
// 1. Clipboard-safe paste
func insertTextWithClipboardSafety(_ text: String)

// 2. Keystroke fallback
func insertViaKeystrokes(_ text: String)

// 3. App-specific workarounds
func getInsertionMethod(for bundleId: String) -> InsertionMethod

enum InsertionMethod {
    case accessibility  // Current method
    case clipboard      // Paste via Cmd+V
    case keystrokes     // Simulate typing
    case appSpecific    // Custom per app
}

// 4. Secure field detection
func isSecureField(_ element: AXUIElement) -> Bool
```

**App-Specific Workarounds**:
- Terminal: Use keystrokes instead of paste
- JetBrains IDEs: Custom delay timing
- Slack: Clipboard method
- VS Code: Accessibility works
- Chrome/Safari: Accessibility works

### Implementation Notes

- Save previous clipboard contents
- Restore after insertion
- Detect secure fields via AXRole
- Per-app insertion preferences
- Fallback chain: Accessibility → Clipboard → Keystrokes

---

## Phase B5: Pro Dictation Controls (Optional)

**Goal**: Voice commands and advanced recording controls

### Files to Create

**1. `Commands/VoiceCommandProcessor.swift`**

```swift
//  VoiceCommandProcessor.swift
//  Processes voice commands in transcription

class VoiceCommandProcessor {
    func processCommands(_ text: String) -> (text: String, command: VoiceCommand?)

    enum VoiceCommand {
        case deleteLastSentence
        case deleteLastWord
        case newParagraph
        case newLine
        case undo
        case bulletPoint
        case numberedList
    }
}
```

**Features**:
- Detect commands in transcription
- Execute commands instead of inserting text
- "delete last sentence" → remove previous sentence
- "new paragraph" → insert "\n\n"
- "undo" → revert last insertion

### Files to Modify

**`AppState.swift`**
- Add end-of-speech padding setting
- Add push-to-mute behavior option

---

## Phase B6: Pro Model Gating (Optional)

**Goal**: Limit base app to Small model, unlock all models in Pro

### Files to Modify

**`AppState.swift`**

```swift
// In model selection
func selectModel(_ model: WhisperModel) {
    guard StoreManager.shared.isPro || model.isBaseTier else {
        // Show upgrade prompt
        return
    }
    // ... select model
}

extension WhisperModel {
    var isBaseTier: Bool {
        switch self {
        case .tiny, .base, .small:
            return true
        default:
            return false
        }
    }
}
```

**`ModelsTabView`**
- Show lock icon on Pro models
- Tapping locked model shows purchase view

---

## Implementation Priority

### Completed
- [x] **B3: Personal Dictionary** - SymSpell fuzzy matching with premium dictionary packs

### Minimum Viable Pro Pack (MVP)
Implement these next:
1. **B1: Code Mode** (Flagship feature)
2. **B2: Per-App Profiles** (Second flagship)
3. **B6: Pro Model Gating** (Easy to implement, adds value)

### Full Pro Pack
Add these for maximum value:
4. **B4: Pro Insertion Engine**
5. **B5: Pro Dictation Controls** (if time allows)

---

## Testing Checklist

After implementing each feature:

- [ ] Feature works when Pro Pack purchased
- [ ] Feature is disabled/hidden when not Pro
- [ ] Purchase prompt appears when accessing Pro feature
- [ ] Restore Purchases re-enables features
- [ ] Settings persist across restarts
- [ ] No crashes when toggling features
- [ ] Works in all supported apps
- [ ] Memory/CPU usage is reasonable

---

## UI/UX Considerations

### Feature Discoverability
- Show "🔒 Pro" badge on locked features
- Tapping locked feature shows purchase view
- Settings clearly indicate which features are Pro

### Purchase Flow
- Single tap to purchase from any locked feature
- Clear value proposition shown
- Feature comparison before purchase
- Immediate unlock after purchase (no restart)

### Visual Design
- Pro features have subtle yellow star icon
- Locked state is clear but not intrusive
- Purchase view matches app aesthetics

---

## Code Organization

File structure (Dictionary already implemented):

```
Whisperer/whisperer/whisperer/
├── CodeMode/                    # Pending
│   ├── CodeModeProcessor.swift
│   ├── SymbolMappings.swift
│   └── CasingTransformer.swift
├── Profiles/                    # Pending
│   ├── ProfileManager.swift
│   ├── AppProfile.swift
│   └── ProfileStorage.swift
├── Dictionary/                  # DONE
│   └── (SymSpell integration)
├── Commands/                    # Pending
│   └── VoiceCommandProcessor.swift
└── UI/
    ├── ProfileEditorView.swift  # Pending
    └── ProFeatureLockView.swift # Pending
```

---

## Integration Points

Each Pro feature integrates at these points:

| Feature | Integration Point | Gating Check | Status |
|---------|------------------|--------------|--------|
| Code Mode | StreamingTranscriber output | StoreManager.isPro | Pending |
| Per-App Profiles | AppState initialization | StoreManager.isPro | Pending |
| Personal Dictionary | Transcription pipeline | StoreManager.isPro | **DONE** |
| Pro Insertion | TextInjector method | StoreManager.isPro | Pending |
| Voice Commands | StreamingTranscriber output | StoreManager.isPro | Pending |
| Pro Models | AppState.selectModel() | StoreManager.isPro | Pending |

---

## Next Steps

1. **B1: Code Mode** - Implement symbol replacement and casing commands
2. **B2: Per-App Profiles** - Auto-switch settings per application
3. **B6: Pro Model Gating** - Lock larger models behind Pro
4. **B4: Pro Insertion Engine** - Improve text insertion reliability
5. **B5: Pro Dictation Controls** - Voice commands (optional)

---

**Status**: 1/6 features completed (Personal Dictionary)

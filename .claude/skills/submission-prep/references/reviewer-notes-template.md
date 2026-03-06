# Reviewer Notes Template

Fill in `{VERSION}` with current version. Must be under 4000 characters.

```
Whisperer v{VERSION} — Addressing Guideline 2.4.5 Feedback

WHAT IS WHISPERER:
An offline voice-to-text productivity tool for macOS. Users record speech, the app transcribes it locally using whisper.cpp with Metal GPU acceleration, and the transcribed text is available for use. 100% offline — no data leaves the device, no cloud services, no accounts.

ACCESSIBILITY IS FULLY OPTIONAL (DEFAULT OFF):
In direct response to your feedback, Accessibility is genuinely optional. The app ships with auto-paste disabled by default (autoPasteEnabled = false in UserDefaults). Users who never enable auto-paste will never see an Accessibility permission prompt, and the app never calls AXIsProcessTrusted() unless the user explicitly opts in.

Two modes of operation:
1. Clipboard mode (DEFAULT): Transcribed text is copied to clipboard. User presses Cmd+V to paste. Recording, transcription, history, model management — everything works without Accessibility.
2. Auto-paste mode (OPT-IN): User explicitly enables auto-paste via Settings toggle or during onboarding (page is labeled "Optional" with "Use Clipboard Mode" as alternative). Only then is Accessibility requested.

WHY ACCESSIBILITY IS NEEDED FOR AUTO-PASTE:
CGEvent.post() requires AXIsProcessTrusted() to deliver a synthetic Cmd+V keystroke to the frontmost app — this is a macOS system requirement. The mechanism is: copy text to NSPasteboard → post one Cmd+V via CGEvent.post(tap: .cgAnnotatedSessionEventTap). Same clipboard+paste approach used by macOS built-in Dictation. No AX elements are read, queried, or modified.

HOW OPT-IN WORKS (code-level detail):
1. AppState.autoPasteEnabled defaults to false
2. PermissionManager only tracks accessibility status when isAccessibilityTrackingEnabled = true (set by auto-paste toggle)
3. TextInjector.insertText() checks: guard autoPasteEnabled && hasAccessibilityPermission() — otherwise copies to clipboard only
4. Onboarding page 5 ("Auto-Paste") is labeled "Optional" with two paths: "Enable Auto-Paste" and "Use Clipboard Mode"
5. Periodic permission checks skip accessibility entirely when auto-paste is disabled

NO BANNED APIs:
• No CGEventTap or event monitoring of any kind
• No IOHIDManager or IOKit HID
• No global keyDown/keyUp monitors
• No AXUIElementCopyAttributeValue or AXUIElementSetAttributeValue
• No direct AX element manipulation — only AXIsProcessTrusted() for permission check

SHORTCUT DETECTION (not keystroke monitoring):
• Fn key: NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) — modifier state changes only, keyCode 63
• Custom shortcuts: Carbon RegisterEventHotKey — standard macOS hotkey API

PERMISSIONS:
• Microphone (required) — records voice for on-device transcription
• Accessibility (optional, default OFF) — only for CGEvent.post to deliver Cmd+V

HOW TO TEST:
Clipboard mode (default): Launch → onboarding → grant Microphone → skip Auto-Paste ("Use Clipboard Mode") → menu bar → hold Fn → speak → release → text copied to clipboard → Cmd+V to paste.
Auto-paste (opt-in): Settings → enable Auto-Paste toggle → grant Accessibility → open TextEdit → hold Fn → speak → release → text appears at cursor.

NO SIGN-IN REQUIRED — uncheck "Sign-in required."
PRIVACY: 100% offline. No data transmitted. No accounts. No analytics.
EXPORT: HTTPS only (exempt). No proprietary encryption.
IAP: com.ivy.whisperer.propack (non-consumable)
```

# Reviewer Notes Template

Fill in `{VERSION}` with current version. Must be under 4000 characters.

```
Thank you for your feedback. v{VERSION} makes significant architectural changes to address every Guideline 2.4.5 concern.

WHAT IS WHISPERER:
An assistive dictation tool — an alternative text input method for users who cannot or prefer not to type (RSI, carpal tunnel, mobility limitations, temporary injuries, or anyone who works faster by voice). It provides the same "dictate anywhere you can type" capability as Apple's built-in Dictation, but runs a local Whisper AI model for 100% offline, private transcription. No data ever leaves the Mac.

ALL FLAGGED APIs REMOVED:
Every API cited in the rejection has been deleted from source and binary:
• CGEventTap/CGEventTapCreate — REMOVED. No event taps of any kind.
• IOHIDManager/IOKit HID — REMOVED. No hardware-level monitoring.
• NSEvent globalMonitor with keyDown/keyUp — REMOVED. No keystroke monitoring.
• Input Monitoring permission — REMOVED entirely.
• AXUIElementCopyAttributeValue — REMOVED. We no longer read AX element attributes.
• AXUIElementSetAttributeValue — REMOVED. We no longer write to AX elements.
• NSAppleEventsUsageDescription — REMOVED from Info.plist.
None of these symbols exist in our binary.

ACCESSIBILITY IS NOW FULLY OPTIONAL (DEFAULT OFF):
In direct response to your latest feedback, Accessibility is genuinely optional. The app ships with auto-paste disabled by default (autoPasteEnabled = false). Users who never enable it will never see an Accessibility prompt, and the app never calls AXIsProcessTrusted() unless the user explicitly opts in.

Two modes of operation:
1. Clipboard mode (DEFAULT): Transcribed text copies to clipboard. User presses Cmd+V. Recording, transcription, history — everything works without Accessibility.
2. Auto-paste mode (OPT-IN): User enables via Settings toggle or onboarding (page labeled "Optional" with "Use Clipboard Mode" as alternative). Only then is Accessibility requested.

Code-level enforcement:
• AppState.autoPasteEnabled defaults to false
• PermissionManager only polls AXIsProcessTrusted() when auto-paste is enabled
• TextInjector checks: guard autoPasteEnabled && hasAccessibilityPermission() — otherwise clipboard only
• Onboarding page labeled "Optional" with two paths: "Enable Auto-Paste" and "Use Clipboard Mode"

WHY ACCESSIBILITY IS NEEDED FOR AUTO-PASTE:
CGEvent.post requires AXIsProcessTrusted() to deliver a Cmd+V paste keystroke to the frontmost app. That is the sole reason this permission is needed. The mechanism: copy to NSPasteboard → post one Cmd+V via CGEvent.post(tap: .cgAnnotatedSessionEventTap). Same clipboard+paste approach as macOS built-in Dictation and Voice Control. No AX elements are read, queried, or modified.
Without Accessibility: app still works fully. Transcriptions copy to clipboard for manual paste.

SHORTCUT DETECTION (no keystroke monitoring):
• Fn key: NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) — modifier state only. Detects Fn press/release via keyCode 63. No typed characters observed.
• Custom shortcuts: Carbon RegisterEventHotKey — standard macOS hotkey API. No Input Monitoring needed.

DOES NOT: create event taps • use IOKit HID • monitor keystrokes • read/write AX elements • log or transmit input • require Input Monitoring • use ChatGPT/OpenAI cloud

HOW TO TEST:
Clipboard mode (default): Launch → onboarding → grant Microphone → skip Auto-Paste ("Use Clipboard Mode") → menu bar → hold Fn → speak → release → text copied to clipboard → Cmd+V to paste.
Auto-paste (opt-in): Settings → enable Auto-Paste → grant Accessibility → TextEdit → hold Fn → speak → release → text at cursor.
Tip: Set Globe key to "Do Nothing" in System Settings → Keyboard → Modifier Keys.

NO SIGN-IN REQUIRED — uncheck "Sign-in required."
PRIVACY: 100% offline. No data transmitted. No accounts. No analytics.
EXPORT: HTTPS only (exempt). No proprietary encryption.
CHINA (Guideline 5): No ChatGPT/OpenAI cloud. whisper.cpp runs on-device. No network needed.
IAP: com.ivy.whisperer.propack
```

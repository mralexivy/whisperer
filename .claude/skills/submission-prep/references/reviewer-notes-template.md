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

KEY ARCHITECTURAL CHANGES:
1. System-wide dictation is OPT-IN (default OFF). A 4-page onboarding guides first-run setup. The final page presents dictation as explicitly "Optional" with "Enable" and "Set Up Later" buttons. The core app — recording, transcription, history, clipboard copy — works fully without it and without Accessibility.

2. Text entry rewritten — clipboard+paste ONLY. All direct AX element manipulation removed. The mechanism is now: copy transcription to NSPasteboard → post one Cmd+V via CGEvent.post. Same clipboard-paste approach as macOS built-in Dictation. No AX elements are read, queried, or modified.

PERMISSIONS — WHY EACH IS NEEDED:

1. Microphone (required)
Records voice for on-device speech-to-text — the core function of a dictation app. Audio captured only while user holds their trigger key. All processing runs locally via whisper.cpp (MIT licensed). No audio ever transmitted.

2. Accessibility (optional — only when user enables system-wide dictation)
CGEvent.post requires AXIsProcessTrusted() to deliver a Cmd+V paste keystroke to the frontmost app. That is the sole reason this permission is needed. We post one paste event so dictated text appears where the user is typing — the same assistive behavior as Apple's built-in Dictation and Voice Control.
Without Accessibility: app still works fully. Transcriptions copy to clipboard for manual paste.

SHORTCUT DETECTION (no keystroke monitoring):
• Fn key: NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) — modifier state only. Detects Fn press/release via keyCode 63. No typed characters observed.
• Custom shortcuts: Carbon RegisterEventHotKey — standard macOS hotkey API. No Input Monitoring needed.

DOES NOT: create event taps • use IOKit HID • monitor keystrokes • read/write AX elements • log or transmit input • require Input Monitoring • use ChatGPT/OpenAI cloud

HOW TO TEST:
Core (no Accessibility): Launch → onboarding → grant Microphone → "Set Up Later" → menu bar → record → speak → transcription appears → copy to clipboard.
System-wide (optional): Settings → enable System-Wide Dictation → grant Accessibility → TextEdit → hold Fn → speak → release → text at cursor.
Tip: Set Globe key to "Do Nothing" in System Settings → Keyboard → Modifier Keys.

NO SIGN-IN REQUIRED — uncheck "Sign-in required."
PRIVACY: 100% offline. No data transmitted. No accounts. No analytics.
EXPORT: HTTPS only (exempt). No proprietary encryption.
CHINA (Guideline 5): No ChatGPT/OpenAI cloud. whisper.cpp runs on-device. No network needed. Previous "OpenAI" metadata removed.
IAP: com.ivy.whisperer.propack
```

# Reviewer Notes Template

Fill in `{VERSION}` with current version. Must be under 4000 characters.

```
Thank you for your feedback. v{VERSION} addresses both Guideline 2.4.5 and Guideline 5.1.1(iv).

WHAT IS WHISPERER:
An offline voice-to-text productivity tool for macOS. It provides the same "dictate anywhere you can type" capability as Apple's built-in Dictation, but runs a local Whisper AI model for 100% offline, private transcription. No data ever leaves the Mac. Built for developers and knowledge workers who want fast voice input without cloud dependencies.

GUIDELINE 2.4.5 — COMPLETE ACCESSIBILITY REMOVAL:
All Accessibility code has been completely removed from this build. This is not a behavioral change or an opt-in toggle — the code does not exist in this version.

The app has been rebuilt with a clipboard-only architecture:
• Zero AXIsProcessTrusted references
• Zero AXUIElement API calls
• Zero CGEvent.post calls
• Zero CGEventTap/CGEventTapCreate
• Zero IOHIDManager/IOKit HID
• Zero references to "auto-paste", "assistive", or Accessibility
• No Input Monitoring permission
• No Accessibility permission request — never prompted, never referenced
• NSAppleEventsUsageDescription removed from Info.plist

How text delivery works:
Transcribed text is copied to NSPasteboard. User pastes with ⌘V. No synthetic keystrokes, no AX element interaction, no Accessibility permission involved. One mode only — clipboard.

GUIDELINE 5.1.1(iv) — PERMISSION LANGUAGE FIXED:
• "Grant Microphone Access" button → "Continue"
• "Set Up Later" skip button → "Continue" (user always proceeds to system dialog)
• "Grant Permissions" button → "Open Permissions"
• Descriptive text is informational only, not directive
No directive language or skip/exit buttons remain.

SHORTCUT DETECTION (no keystroke monitoring):
• Fn key: NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) — modifier state only. Detects Fn press/release via keyCode 63. No typed characters observed.
• Custom shortcuts: Carbon RegisterEventHotKey — standard macOS hotkey API. No Input Monitoring needed.

DOES NOT: create event taps • use IOKit HID • monitor keystrokes • read/write AX elements • request Accessibility • log or transmit input • require Input Monitoring • use ChatGPT/OpenAI cloud

HOW TO TEST:
Launch → onboarding → microphone permission (button says "Continue") → last page: press "Download <size>" (nothing downloads until you do) → menu bar icon → hold Fn → speak → release → text copied to clipboard → ⌘V to paste in any app.
DOWNLOADS (Guideline 4.2.3): every model download starts from a button that names its size: onboarding "Download <size>", the Models list, the meeting screen "Download about 3.4 GB", the Smart Polish card "Download 138 MB". Nothing is fetched at launch.
Tip: Set Globe key to "Do Nothing" in System Settings → Keyboard → Modifier Keys.

NO SIGN-IN REQUIRED — uncheck "Sign-in required."
PRIVACY: 100% offline. No data transmitted. No accounts. No analytics.
EXPORT: HTTPS only (exempt). No proprietary encryption.
CHINA (Guideline 5): No ChatGPT/OpenAI cloud. whisper.cpp runs on-device. No network needed for transcription.
IAP: com.ivy.whisperer.pro (Non-Consumable, $14.99; the app is $4.99)
ENTITLEMENTS (state each one; Apple's automated review rejects an entitlement it cannot match to a feature):
- com.apple.security.network.client: model downloads, optional calendar and AI sign-in.
- com.apple.security.network.server: loopback only (127.0.0.1). (1) The optional local MCP server, OFF by default, bearer token required. (2) The one-shot OAuth redirect listener of the ChatGPT sign-in. Neither opens a port to the network.
- com.apple.security.device.audio-input: microphone for dictation and meetings.
- com.apple.security.files.user-selected.read-write: file import and export through open/save panels.
```

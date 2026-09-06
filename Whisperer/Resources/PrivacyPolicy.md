# Whisperer Privacy Policy

**Last Updated:** February 1, 2026

## Overview

Whisperer is a voice-to-text transcription app for macOS that processes audio entirely on your device. We are committed to protecting your privacy.

## Data Collection

**We do not collect any personal data.**

### Audio Data

- All audio recording and transcription happens **100% locally** on your Mac
- Audio is **never uploaded** to any server or cloud service
- Audio recordings are **always saved** to your local disk (in `~/Library/Application Support/Whisperer/Recordings/`)
- You can auto-delete old recordings: set retention to Never / 7 / 30 / 90 / 365 days in Settings
- You have full control and can manually delete recordings at any time

### Network Usage

The app uses network connectivity for:

- **Model Downloads & Updates**: On launch, the app checks Hugging Face for model updates. Downloads contain no personal information.
- **No Telemetry**: We do not use analytics, tracking, or crash reporting services that transmit data.

Once models are downloaded, **transcription works completely offline**. No internet connection is required to record and transcribe audio.

### Third-Party Services

- **Hugging Face**: Used to download open-source AI models including whisper.cpp (speech-to-text engine) and whisper-polish (fine-tuned model for improved transcription). No personal data is transmitted during these downloads.
- **MCP Server**: Whisperer runs a local HTTP server on localhost:8080 that serves your transcript history. This allows AI tools like Claude Desktop and Cursor to access your transcripts for context. The server is local-only and disabled by default—you can turn it off in Settings.
- **No Analytics**: We do not use Google Analytics, Mixpanel, Segment, or any other analytics platform.
- **No Ads**: The app contains no advertising or ad networks.

## Permissions Explained

Whisperer requires the following macOS permissions to function:

### Microphone Access
**Purpose**: Record your voice for transcription

The microphone permission allows the app to capture audio when you hold the recording shortcut. This audio is processed entirely on your device and is never transmitted over the network.

### Accessibility Permission (Optional)
**Purpose**: Auto-paste transcribed text into applications

If you enable the optional Auto-Paste feature, the Accessibility permission allows Whisperer to automatically paste transcribed text into the text field you're focused on. Without this permission, transcribed text is copied to your clipboard for manual pasting. This is a macOS system permission required for cross-application text pasting via simulated Cmd+V.

**Learn From My Corrections** is on by default and can be turned off at any time in Dictionary
settings. When a word you fix qualifies, Whisperer adds it to your dictionary, tells you it did
so, and offers Undo; undone words are never learned again.

In every build, including the App Store build, this learns from two things, neither of which needs
an additional permission: edits you make to a transcript in Whisperer's own History window, and
words you fix yourself on the card Whisperer shows for a few seconds after a dictation. That card
only teaches the dictionary — it does not change text that has already been inserted.

Outside the App Store build, and only if you have also granted Accessibility for Auto-Paste, it
additionally re-reads the same focused text field for up to about 30 seconds after a paste to
notice isolated words you correct there. It stops as soon as focus leaves that app or the field
changes identity. It does not monitor keys, inspect other windows, or send text over the network.
Learned words and pending suggestions stay on device and can be deleted from Dictionary settings.

## Data Storage

All data remains on your device:

- **AI Models**: Stored in `~/Library/Application Support/Whisperer/` (~500MB to 3GB depending on model)
- **Audio Recordings**: Stored in `~/Library/Application Support/Whisperer/Recordings/` (always saved; auto-delete rules available in Settings)
- **Dictionary**: Your learned words are stored in `~/Library/Application Support/Whisperer/` for offline use
- **Settings**: Stored in macOS UserDefaults (locally)
- **Optional Correction Candidates**: Stored in `~/Library/Application Support/Whisperer/correction-candidates.json` when you explicitly enable collection
- **Logs**: Debug logs stored in `~/Library/Logs/Whisperer/` for troubleshooting

**No data is stored in iCloud or any cloud service.**

## In-App Purchases

If you purchase the Pro Pack upgrade:

- The purchase is processed through Apple's App Store
- Apple handles all payment information according to their privacy policy
- We receive only a notification that the purchase was completed
- No payment information is accessible to us

## Children's Privacy

Whisperer does not knowingly collect any information from children under 13. The app does not collect any personal information from users of any age.

## Changes to This Policy

We may update this privacy policy from time to time. Any changes will be posted at this URL with an updated "Last Updated" date. Continued use of the app after changes indicates acceptance of the updated policy.

## Your Rights

Since we don't collect or store any personal data:

- There is no personal data to access, modify, or delete
- All app data is stored locally on your device
- You can delete all app data by uninstalling the app or manually deleting the folders listed above

## Contact

For privacy questions or concerns:
- **Email**: [Your Contact Email]
- **Website**: [Your Website]

## Compliance

Whisperer complies with:
- Apple's App Store Review Guidelines
- California Consumer Privacy Act (CCPA) - N/A as we collect no personal data
- General Data Protection Regulation (GDPR) - N/A as we collect no personal data

---

**Summary**: Whisperer is a privacy-first app. Everything happens on your device, nothing is sent to the cloud, and we don't collect any personal information.

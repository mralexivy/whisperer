# Whisperer Privacy Policy

**Last Updated:** February 1, 2026

## Overview

Whisperer is a voice-to-text transcription app for macOS that processes audio entirely on your device. We are committed to protecting your privacy.

## Data Collection

**We do not collect any personal data.**

### Audio Data

- All audio recording and transcription happens **100% locally** on your Mac
- Audio is **never uploaded** to any server or cloud service
- Audio recordings are **optionally saved** to your local disk only (in `~/Library/Application Support/Whisperer/Recordings/`)
- You have full control over saved recordings and can delete them at any time

### Network Usage

The app uses network connectivity only for:

- **Model Downloads**: On first launch, the app downloads AI models from Hugging Face (a third-party service). These downloads are one-time and contain no personal information.
- **No Telemetry**: We do not use analytics, tracking, or crash reporting services that transmit data.

After the initial model download, **the app works completely offline**. No internet connection is required for transcription.

### Third-Party Services

- **Hugging Face**: Used solely to download open-source whisper.cpp AI models. No personal data is transmitted during these downloads.
- **No Analytics**: We do not use Google Analytics, Mixpanel, Segment, or any other analytics platform.
- **No Ads**: The app contains no advertising or ad networks.

## Permissions Explained

Whisperer requires the following macOS permissions to function:

### Microphone Access
**Purpose**: Record your voice for transcription

The microphone permission allows the app to capture audio when you hold the recording shortcut. This audio is processed entirely on your device and is never transmitted over the network.

### Accessibility Permission
**Purpose**: Insert transcribed text into applications

The Accessibility permission allows Whisperer to automatically paste the transcribed text into any text field you're focused on. This is a macOS system permission required for cross-application text insertion.

### Input Monitoring Permission
**Purpose**: Detect keyboard shortcuts globally

Input Monitoring allows the app to detect when you press and release your recording shortcut (e.g., the Fn key) while using other applications.

## Data Storage

All data remains on your device:

- **AI Models**: Stored in `~/Library/Application Support/Whisperer/` (~500MB to 3GB depending on model)
- **Optional Recordings**: Stored in `~/Library/Application Support/Whisperer/Recordings/` (if you enable saving)
- **Settings**: Stored in macOS UserDefaults (locally)
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

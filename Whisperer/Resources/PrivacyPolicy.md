# Whisperer Privacy Policy

**Last Updated:** November 17, 2026

## Overview

Whisperer is a voice-to-text transcription app for macOS. It processes audio entirely on your
device. This policy explains what the app does with your data. The short version: everything stays
on your Mac.

## Data Collection

**Whisperer does not collect any personal data.**

There are no accounts, no sign-in, no telemetry, no analytics, and no advertising. Whisperer does
not use Google Analytics, Mixpanel, Segment, or any comparable platform. No crash reporter
transmits data off the device. Whisperer has no servers, so nothing you say, write or record ever
reaches its developer.

The only time text leaves your Mac is when you yourself connect a third-party service (a calendar
or an AI provider) with your own sign-in or API key. It then goes straight from your Mac to the
provider you chose, never through us. We do not see it or keep a copy, and you can disconnect at
any time.

## Audio and Transcripts

- All recording and transcription happen on your Mac. Audio is never uploaded.
- Dictation audio and meeting audio are saved locally in
  `~/Library/Application Support/Whisperer/Sessions/`.
- You control retention. Choose Never, 7, 30, 90, or 365 days in Settings.
- You can delete any recording or transcript at any time.

## Meeting Notes

Whisperer can detect a video or audio call and offer to take notes.

- **Whisperer records your microphone only.** It never records system audio, and it never records
  the audio streams of other participants.
- Before the first meeting recording, Whisperer shows a consent screen explaining what is recorded
  and where it is stored.
- A recording indicator stays visible for the whole recording.
- **You decide what to record, and you are responsible for it, including notice to and consent from
  other participants where the law requires it.** Recording laws differ by country and by state.
  Whisperer does not provide legal advice and takes no responsibility for your recordings.
- Recording and transcription run locally on your Mac and are not sent to the cloud.
- If you choose to use your own AI provider, that is your decision and the provider's responsibility,
  not ours.
- Meeting transcripts and audio stay on your Mac under the same retention rules as dictation.

## Network Usage

Whisperer uses the network to download AI model weights. It reaches a calendar or an AI provider only if you connect one.

- Model weights are **data files**, not executable code. The transcription and language engines are
  compiled into the app itself.
- Models are downloaded from Hugging Face (from ModelScope, modelscope.cn, in the China mainland edition). The speech model is about 2.5 GB. The language model
  used for meeting overviews is about 3.2 GB.
- No personal information is transmitted during a download.
- Calendar (optional): if you sign in to Google or Microsoft, the app reads your events directly from that service.
- AI providers (optional): if you connect ChatGPT, OpenAI, Anthropic or Gemini for meeting notes or Ask AI, the text transcript of that meeting and your question are sent from your Mac straight to the provider, with your own sign-in or API key. Text you press Polish on is sent the same way, only when you press it. Audio is never sent, and dictation text is never sent automatically. Whisperer's developer is not a party to that exchange and receives none of it. The provider's own terms and privacy policy apply to what it receives.
- Without a connected provider, Polish, meeting summaries and Ask AI run on the on-device language model (Alibaba Qwen) and nothing leaves your Mac.
- China edition: Whisperer China has no cloud AI provider, no Ask AI and no Google Calendar sign-in. Meeting text is never sent to an AI service.

Once the models are on disk, **transcription works completely offline**.

## Permissions

### Microphone

**Purpose:** record your voice for transcription.

Whisperer captures audio when you hold the recording shortcut, and during a meeting recording you
start. That audio is processed on your device and is never transmitted.

### Camera (optional, off by default)

**Purpose:** tell a video call apart from an app that is only using the microphone.

Whisperer checks **whether** the camera is in use. It never captures, records, or views camera
video. This signal improves meeting detection. It is off until you turn it on in Meeting settings,
and the app works without it.

## MCP Server

Whisperer can run a local server that exposes your own transcript history to AI tools you already
use, such as Claude, Cursor, and ChatGPT.

- It is **off by default**. You turn it on in Settings.
- It listens on **loopback only** by default, so only your own Mac can reach it.
- It requires a **bearer token**. Requests without the token are rejected.
- LAN access is a separate, explicit opt-in.
- It serves your transcripts to the client you configure. Nothing is sent to us.

## Open at Login

The "Open at Login" setting uses the macOS `SMAppService` API. Whisperer installs no helper app and
no background daemon. You can turn it off in Whisperer's settings or in System Settings → General →
Login Items.

## Learn From My Corrections

This feature is on by default and can be turned off in Dictionary settings. When you fix a word,
Whisperer may add it to your dictionary, tell you it did so, and offer Undo. An undone word is never
learned again.

Whisperer learns from two things: edits you make to a transcript in Whisperer's own History window,
and words you fix on the card shown for a few seconds after a dictation. Learned words stay on your
device and can be deleted from Dictionary settings. Nothing is sent over the network.

## Data Storage

Everything stays on your device:

| What | Where |
|---|---|
| AI models | `~/Library/Application Support/Whisperer/` |
| Audio and transcripts | `~/Library/Application Support/Whisperer/Sessions/` |
| Dictionary | `~/Library/Application Support/Whisperer/` |
| Settings | macOS UserDefaults |
| Logs | `~/Library/Logs/Whisperer/` |

**No data is stored in iCloud or any other cloud service.**

## In-App Purchases

Whisperer Pro is a one-time purchase, not a subscription.

- Apple processes the purchase and handles all payment information under Apple's privacy policy.
- Whisperer receives only a confirmation that the purchase completed.
- No payment information is accessible to us.
- Refunds are handled by Apple.

## Open-Source Models

Whisperer is built on open-source AI models released under permissive licenses that allow
commercial use. The full list, with authors and licenses, is in the Acknowledgements screen in the
app's settings.

## Children's Privacy

Whisperer does not knowingly collect information from children under 13. The app collects no
personal information from users of any age.

## Your Rights

Whisperer collects and stores no personal data on any server, so there is no personal data for us
to access, modify, or delete. All app data is on your device. Deleting the app and the folders
listed above removes all of it.

## Changes to This Policy

This policy may be updated. Changes are posted at this URL with a new "Last Updated" date.

## Contact

For privacy questions: **support@whispererapp.com**
Website: **https://whispererapp.com**

## Compliance

- Apple's App Store Review Guidelines
- CCPA — not applicable, as no personal data is collected
- GDPR — not applicable, as no personal data is collected

---

**Summary:** Whisperer is a privacy-first productivity app. Everything happens on your device,
nothing goes to the cloud, and no personal information is collected.

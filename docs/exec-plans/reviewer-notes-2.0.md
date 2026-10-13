# Reviewer Notes — Whisperer 2.0 (1)

Paste the section below into App Store Connect → App Review Information → Notes.

Everything above the line is internal guidance and must **not** be sent to Apple.

## Internal guidance (do not send)

- Never mention compile flags, build configurations, or the dual-build architecture.
- Never describe the app as assistive, accessibility-related, or aimed at people with
  disabilities. The audience is developers and knowledge workers.
- Keep it factual and short. Reviewers skim.

---

## Notes for App Review (send this)

Whisperer is an offline voice-to-text productivity app for developers and knowledge workers. You
hold a key, speak, and the text is placed on your clipboard. It also takes notes during meetings.
All speech processing runs on the device.

**No account is required.** The app is fully functional without signing in to anything.

### Microphone

Used to capture your voice for transcription, and to record your own audio during meeting notes.
Audio is processed on the device and is never uploaded.

### Camera — optional, off by default

Whisperer can use camera activity as one signal for detecting that you are in a video call, which
helps it distinguish a video meeting from an app that is only using the microphone.

- This is **off by default** and must be turned on in Settings → Meeting Detection.
- Whisperer only checks **whether** the camera is in use. It never opens a capture session, never
  records, and never views camera video.
- The app is fully functional with this turned off.

### Meeting recording consent

Before the first meeting recording, the app shows a consent screen explaining that it records your
microphone only, never other participants' audio, that recordings are stored locally, and that
you are responsible for obtaining consent from other participants where the law requires it. No
recording can start until you accept.

While recording, a persistent on-screen indicator with a recording dot, an audio level, and an
elapsed timer remains visible for the entire duration.

### Local MCP server — optional, off by default

Whisperer can expose **your own transcript history** to AI developer tools you already use, such
as Claude, Cursor, and ChatGPT, through a local Model Context Protocol server. This is a core
feature for our developer audience and has its own settings card with a full explanation
(see screenshots).

- It is **off by default** and requires explicit opt-in.
- It binds to **loopback only**. Nothing outside your Mac can reach it.
- Every request requires a **bearer token**. Unauthenticated requests are rejected with 401.
- Serving to other devices on your network is a separate, explicit opt-in.
- This is why the app declares the network server entitlement.

### Model downloads

On first use the app downloads AI model **weights** from Hugging Face — roughly 2.5 GB for the
speech model and 3.2 GB for the language model used to summarize meetings.

These are **data files, not executable code**. The inference engines are compiled into the binary
you are reviewing. The app does not download, install, or execute any code. This complies with
Guideline 2.5.2.

All models are open source under licenses that permit commercial use (Apache 2.0, MIT, CC-BY-4.0,
OpenMDW). The app includes an Acknowledgements screen listing every model, its author, and its
license.

### Transcription engines

The app ships seven speech engines so users can trade off speed, accuracy, and language coverage.
If a chosen engine's weights are not present, the app falls back to a bundled engine so
transcription always works. Some engines require Apple Silicon or macOS 26 and are presented
accordingly.

### Open at Login

Uses the system `SMAppService` API. No helper application or background daemon is installed. You
can see and control it in System Settings → General → Login Items.

### Pro Pack

A one-time non-consumable in-app purchase. Not a subscription. Refunds are handled by Apple.

### Privacy

No accounts, no telemetry, no analytics, no advertising, no tracking. Nothing is uploaded. The
privacy policy is at https://whispererapp.com/privacy and the terms of use at
https://whispererapp.com/terms.

### Testing notes

- Microphone permission is requested on first recording.
- To test meeting detection, start a call in Zoom, Teams, or Google Meet, or any app that uses the
  microphone continuously; a notification offering to take notes appears.
- The MCP server and the camera signal are both off by default and must be enabled in Settings to
  be exercised.

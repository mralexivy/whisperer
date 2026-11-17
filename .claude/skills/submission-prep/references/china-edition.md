# China edition — App Store Connect notes

Used for the `com.ivy.whisperer.cn` record (China mainland only). Fill `{VERSION}`. Keep under 4000 characters.

## Review notes (paste)

```
Whisperer {VERSION} (China edition) is an offline voice-to-text tool for macOS. Speech recognition runs on the Mac with open-source models; audio and text never leave the device.

CHINA COMPLIANCE (AI-Generated or Synthetic Content / Security Assessment): both answers are No.
This edition has no AI chatbot, no image/video generation, no voice or face alteration, and no end-to-end encrypted messaging. The following exist in our other edition and are removed from this one at build time (compiled out of the China build, not hidden by a setting):
• Ask AI chat over transcripts
• Connected cloud AI providers (OpenAI, Anthropic, Google) and coding-tool CLI providers
• Voice reshaping / Privacy Shield
• Command Mode
• Cloud sync
• Google Calendar sign-in
The remaining text features (a title and short overview of a recording, punctuation/grammar clean-up) run fully on-device with an open-source model and do not offer a conversational or generative service to the user.

MODELS: downloaded once, on first use, from ModelScope (modelscope.cn). No other server is contacted for transcription.
NO SIGN-IN REQUIRED. No accounts, no analytics.
EXPORT: HTTPS only (exempt).
HOW TO TEST: Launch → onboarding → microphone permission → menu bar icon → hold Fn → speak → release → text is copied; press ⌘V.
IAP: same products as the main app, purchased separately in this app.
```

## What to say if Apple asks about on-device models

Transcription (speech to text) and the short on-device summary are not chat, image/video generation, or voice/face alteration, the three services named on Apple's China compliance page. If Apple wants the summary feature off as well, it is one flag: `ComplianceFeature` already separates it from Ask AI.

## Verify before submitting

- `scripts/verify-china-models.sh`
- `strings <china app binary> | grep whisperer-edition=china-mainland` returns 1 line
- bundle id `com.ivy.whisperer.cn`

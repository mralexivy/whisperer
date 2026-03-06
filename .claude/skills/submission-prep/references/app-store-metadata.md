# App Store Metadata Templates

## App Store Description

```
Whisperer - Voice to Text - is a fast, completely offline voice-to-text app for macOS. Record voice memos, transcribe audio, and dictate text, all processed locally on your Mac. Nothing ever leaves your device.

THREE WAYS TO USE

1. Quick Transcription
Click the menu bar icon, tap record, and speak. Your transcription appears instantly — copy it anywhere you need.

2. Voice Memo & History
Record longer passages and review them later in the Workspace. Every transcription is saved with audio playback, word count, and language metadata.

3. System-Wide Dictation (Optional)
Hold the Fn key in any app — Notes, Slack, VS Code, Safari — speak naturally, and release. Your transcribed text appears at the cursor. Enable this optional feature during onboarding or later in Settings.

THREE TRANSCRIPTION ENGINES

Choose the engine that fits your workflow:

• Whisper.cpp (Default) — 10 models from Tiny (75 MB) to Large V3 (2.9 GB). 99+ languages. Metal GPU accelerated.
• Parakeet (FluidAudio) — Apple Silicon native. Parakeet v2 (English) and Parakeet v3 (25 European languages) with high recall accuracy.
• Apple Speech — Native macOS speech recognition with 90+ supported locales. Requires macOS 26+.

Switch engines anytime. Language compatibility hints appear automatically when your selected language isn't supported by the current engine.

100% PRIVATE & OFFLINE
All transcription runs locally on your Mac. Your voice never leaves your device. No cloud processing, no accounts, no subscriptions.

APPLE SILICON OPTIMIZED
Built for speed with Metal GPU acceleration. The recommended Large V3 Turbo model delivers exceptional accuracy with real-time transcription on Apple Silicon Macs.

LIVE PREVIEW
Watch your words appear as you speak with streaming transcription. A floating overlay shows your audio waveform and progress in real time.

AI POST-PROCESSING (Pro)
Refine transcriptions locally with on-device Qwen3 language models. Rewrite for professional tone, translate, format as markdown, summarize, fix grammar, or run your own custom prompt — all offline.

OPTION+V TRANSCRIPT PICKER
Hold Option and press V to browse your 5 most recent transcriptions. Press V to cycle, release Option to copy. Quick access without opening the Workspace.

FILE TRANSCRIPTION
Drag and drop audio or video files (MP3, WAV, M4A, MP4, MOV, and more) for offline transcription with chunked processing and progress tracking.

99+ LANGUAGES
Transcribe in over 99 languages with Whisper models. Set your preferred language or let the app auto-detect. Parakeet v3 supports 25 European languages.

SMART RECORDING
• Hold-to-Record or Toggle mode
• Customizable keyboard shortcuts (Fn key or any key combination)
• Audio muting — optionally mutes other audio while recording
• Audio feedback — distinct sounds confirm recording start and stop
• Voice Activity Detection for improved accuracy

THOUGHTFUL DESIGN
• Lives in your menu bar — always available, never in the way
• Guided onboarding — set up permissions, download a model, and start dictating in minutes
• Workspace — browse, search, and manage your transcription history
• Custom dictionary — teach the app names, terms, and jargon

REQUIREMENTS
• macOS 13.0 (Ventura) or later
• ~2GB disk space for recommended model
• Apple Silicon recommended (Intel Macs supported)

PERMISSIONS
• Microphone — to record your voice for transcription
• Accessibility (optional) — to auto-paste transcribed text at your cursor

All processing happens locally. Your data stays on your Mac.
```

## Promotional Text

```
Offline voice-to-text with 3 transcription engines (Whisper, Parakeet, Apple Speech), local AI post-processing, and 99+ languages. 100% private, no cloud, no subscription.
```

## Keywords

```
voice to text,speech-to-text,dictation,transcription,whisper,offline,privacy,voice memo,productivity,developer
```

## Submission Summary Template

### Build Status
- Release build: PASS/FAIL
- Warning count: N
- Conventions violations: N

### Compliance Status
- Banned APIs found: YES/NO
- Permissions correct: YES/NO
- Entitlements correct: YES/NO
- Info.plist correct: YES/NO
- TextInjector clipboard-only default: YES/NO
- Auto-paste opt-in (default OFF): YES/NO

### Version Info
- Version: (from Info.plist)
- Build: (from Info.plist)

### Archive & Upload
- Archive command: `xcodebuild archive -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "generic/platform=macOS" -archivePath build/Whisperer.xcarchive ARCHS=arm64 'CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements' ENABLE_APP_SANDBOX=YES`
- Upload command: `xcodebuild -exportArchive -archivePath build/Whisperer.xcarchive -exportOptionsPlist /tmp/ExportOptions.plist -exportPath build/export`
- ExportOptions.plist: method=app-store-connect, destination=upload, teamID=8NM6EHZB4G, signingStyle=automatic
- Archive: PASS/FAIL
- Upload to App Store Connect: PASS/FAIL

### Notes
- Release config uses `whisperer-nosandbox.entitlements` and `ENABLE_APP_SANDBOX=NO` for local dev. Override with sandboxed entitlements at archive time (see commands above).
- FluidAudio dependency fails on x86_64 (Float16 issue). Always archive with `ARCHS=arm64`.

### Ready to Submit?
- If all checks pass and upload succeeded: "Build uploaded to App Store Connect. Copy reviewer notes into App Store Connect → App Information → Notes for Reviewer. Update Description, Promotional Text, and Keywords if changed."
- If any checks fail: "NOT ready — fix the issues above before submitting."

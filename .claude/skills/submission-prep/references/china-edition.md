# China edition — App Store Connect notes

Used for the `com.ivy.whisperer.cn` record ("Whisperer China", China mainland only; app id 6835744579). Already applied to the record on 2026-11-17: zh-Hans listing, 3 screenshots, categories, age rating 4+, privacy URL, these review notes, availability, prices ($4.99 app, Pro $14.99 `com.ivy.whisperer.propack`).

## Review notes (as sent)

```
Whisperer China is the China-mainland edition of our macOS app "Whisperer - Voice to Text" (separate App Store record, bundle id com.ivy.whisperer.cn, sold in China mainland only). It is an offline voice-to-text tool: speech is recognised on the Mac and nothing is sent to any server.

CHINA COMPLIANCE FORMS (AI-Generated or Synthetic Content; Security Assessment): both answered No.
This edition offers no AI chatbot, no image or video generation, no voice or face alteration and no end-to-end encrypted messaging. These features exist in our other edition and are disabled in this one: the build is fixed to the China-mainland market, their entry points are removed from the UI and their services refuse to run. Disabled here: Ask AI chat over transcripts; the AI Modes page (free-form rewrite prompts); connected cloud AI providers and coding-tool providers (third-party AI services); voice reshaping (Privacy Shield); Command Mode; cloud sync; Google Calendar sign-in. No transcript or audio is ever sent to a third-party AI service from this edition.

MODELS (complete list). The models this edition downloads are Alibaba's Qwen models:
1. Qwen3-ASR-1.7B (8-bit MLX) for speech recognition (default engine).
2. Qwen3.5-4B (4-bit MLX), used only by the Pro in-app purchase, on the Mac: a title and a short overview (decisions, action items) of a recorded meeting. There is no chat, no free-form prompt box and no rewrite or generation of text for the user in this edition.
3. Apple's own built-in on-device language model (Foundation Models framework, Apple Intelligence). It is provided by macOS, not downloaded or bundled by us, and macOS alone decides whether it is available on a given Mac and in a given region. Where macOS reports it available it can write the same Pro meeting title and short overview instead of Qwen; nothing else: no chat, no free-form prompt, no rewrite or generation of text for the user. Nothing leaves the Mac.
Models 1 and 2 are downloaded once, on first use, from ModelScope (modelscope.cn, repositories mlx-community/Qwen3-ASR-1.7B-8bit and mlx-community/Qwen3.5-4B-MLX-4bit); files are verified against ModelScope's published SHA-256. Hugging Face is not used in this edition.
Also used, neither generative: (a) Apple's built-in on-device speech recogniser, for the live preview while speaking; (b) Silero VAD (about 0.9 MB, MIT licence), a voice-activity detector downloaded from ModelScope (ggml-org/whisper-vad). No other model is offered or downloaded.

HOW TO TEST
Launch, accept the microphone permission (button reads "Continue"), complete model download in onboarding, then hold Fn, speak, release; the text is copied to the clipboard and can be pasted with Cmd+V. No Accessibility or Input Monitoring permission is requested. Drop an audio file on the Workspace to transcribe it.
Pro (in-app purchase com.ivy.whisperer.propack, non-consumable, one time): meeting recording, meeting detection, Outlook/Microsoft 365 calendar sync, on-device meeting titles and summaries, and a local MCP server that stays on the Mac.

NO SIGN-IN REQUIRED. No accounts, no analytics, no advertising.
PRIVACY: all processing is on the device; the only network use is downloading the models above and the App Store purchase.
EXPORT: HTTPS only (exempt encryption).
```

## Keep the claims true

- The features listed as disabled are disabled at runtime by `MarketPolicy` (the China edition fixes the market at build time). They are **not** compiled out; do not say they are.
- The model list must match `LLMModelVariant.available` (Apple's built-in model is offered wherever macOS reports it, declared as model 3 above), `BackendType.selectable`, `ModelSources` and `AcknowledgementsView` (China branch). Change all together.
- Screenshots must not show: Whisper/Parakeet or any non-Qwen model, several model sizes, Ask AI, cloud AI providers, Accessibility or "Set Up Later", third-party app logos, or a "Pro" badge on Basic features.

## Verify before submitting

- `scripts/verify-china-models.sh`
- `strings <china app binary> | grep whisperer-edition=china-mainland` returns 1 line; bundle id `com.ivy.whisperer.cn`

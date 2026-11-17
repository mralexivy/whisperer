# China mainland compliance — plan

Status: proposal (2026-11-17). Based on Apple's own page and an audit of the code, not on legal summaries.

## 1. What Apple asks

Source (read in full): <https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-china-mainland-compliance-information>

- **AI-Generated or Synthetic Content** form. Trigger, verbatim: "if your app offers services such as **AI chatbots, image or video generation, or voice and face alteration**". Yes → an approved LLM/Algo filing number, plus (for someone else's technology) an authorization naming us from the owner listed in the CAC registry.
- **Security Assessment** form: "distributing AI-generated or Synthetic content or enabling end-to-end encrypted instant messaging".
- **"Select No: if your app does not offer these features, or if they are disabled or geoblocked in China mainland."** Both forms are mandatory for every app in the China storefront; existing apps by **2027-01-31**, before the next version. Account Holder/Admin only.
- The App Review Guidelines say nothing about China, generative AI or on-device models.

So the rule for us: whatever matches the trigger list is either **off in China** (answer No) or **filed** (answer Yes, needs a filing number we cannot get). Everything else is unaffected.

## 2. Model inventory (from the code)

Every model runs on-device. Weights come from huggingface.co. Nothing is gated by `APP_STORE` except the CLI providers, so the Mac App Store binary contains the same models as the direct build (derived from source, binary not inspected).

| Model | Role | Generative? | Used for | Origin |
|---|---|---|---|---|
| Whisper ggml (tiny … large-v3-turbo-Q5, default), Distil, ivrit Hebrew | speech-to-text | no | dictation, meetings, refine pass | OpenAI / community |
| WhisperKit large-v3-turbo | speech-to-text | no | picker | OpenAI via Argmax |
| Parakeet TDT 0.6B v2/v3, Nemotron 0.6B (+Hebrew) | speech-to-text | no | picker (Nemotron hidden) | NVIDIA |
| **Qwen3-ASR-1.7B-8bit** | speech-to-text + language ID | **no** | opt-in engine ("Qwen3 ASR"), dictation and meetings | **Alibaba** |
| Apple SpeechAnalyzer | live preview, language ID | no | all engines | Apple |
| Silero VAD, Nemotron-3 diarizer | voice activity, speakers | no | recording, meetings | Silero, NVIDIA |
| `whisperer-polish` (mmBERT-small token tagger, 138 MB) + DeterministicPolisher (rules) | "Fast Polish": punctuation, casing, fillers | **no** (edit tags / rules) | default Correct and Grammar modes | JHU (MIT) / ours |
| **Qwen2.5-1.5B, Qwen3.5-2B / 4B / 9B, Qwen3.5-4B MTP** | text LLM | **yes** | see §3 | **Alibaba** |
| "Whisperer V3" LLM (Qwen3-0.6B fine-tune) | text LLM | yes | AI Post-Processing picker | Shantanu Goel, derived from Qwen |
| ChatGPT sign-in, OpenAI / Anthropic / Gemini API keys | text LLM | yes | meeting notes, Ask AI, "Polish with AI" | OpenAI, Anthropic, Google (network) |
| Claude Code, Codex, Antigravity CLIs | text LLM | yes | same | direct build only |

Note: "Whisperer V3" is two different things (a Whisper large-v3-turbo-Q5 transcription model, and a Qwen3-0.6B LLM). Worth renaming one.

## 3. Where the generative models are used

- **Dictation AI Post-Processing**: master switch `llmEnabled` is **off by default**. When on, the user-picked LLM (default Qwen3.5-4B MTP) runs the non-strict modes (Translate, Format, Summarize, List, Coding, Email, Creative, Custom). The default Correct and Grammar modes use no LLM.
- **Meetings**: title, overview, **Ask AI chat** and local summary run on Qwen3.5-4B MTP (fixed, no user choice) when no cloud provider is active.
- **Cloud providers** (opt-in, per-provider consent): receive the meeting transcript with timestamps and speaker names, the Ask AI question, and chunks for "Polish with AI". Dictation text is never sent.
- **Direct build only**: rewrite-selection, Command Mode, dictation-polish card, CLI providers, MCP auto-install, Privacy Shield.

## 4. Mapping to Apple's trigger list

| Feature | In the list? | China |
|---|---|---|
| Speech-to-text in any model, incl. Qwen3-ASR; VAD; diarization; Fast Polish | no | **keep** |
| Meeting title, overview, local summary, local polish (Qwen) | no (text rewriting, not chat/image/video/voice) | **keep** — Qwen becomes the only LLM |
| **Ask AI** | **yes: it is an AI chatbot** | **off** |
| Cloud providers (OpenAI, Anthropic, Gemini, ChatGPT) | third-party AI + foreign servers | **off** |
| Claude Code / Codex / Antigravity **as AI providers** (they send meeting text to a foreign cloud), Command Mode | foreign cloud AI / terminal agent | **off** |
| **MCP server and its connect page** | no: it is local, our data never leaves the Mac, and any client (Chinese ones too) can connect | **keep** |
| Privacy Shield (voice reshaping) | yes: voice alteration | **not shipped** (already direct-only; stays out of the China build entirely) |
| Whisperer Cloud (E2E sync) | not messaging, but data leaves China | stays off (`isLive = false`) |

Result: answer **No / No** on both forms with Ask AI, cloud AI (including the CLI providers) and voice reshaping disabled by region. MCP stays.

Open point worth asking Apple (App Review notes or Developer Support), not a lawyer: whether on-device summaries and rewrites count as an "AI service". Their list does not include them.

## 5. Detecting China

- App Store build: `Storefront.current?.countryCode == "CHN"` (ISO 3166-1 alpha-3; StoreKit, macOS 12+), re-checked on `Storefront.updates`. The storefront is the account's App Store country, so it can differ from the device region.
- Cache the last value so offline launches behave; **unknown is treated as restricted** for anything that needs a network (cloud AI, sync) — it costs other users nothing because those need a connection anyway.
- Direct build has no storefront: use the system region (`CN`) as a conservative rule. Apple's forms do not cover that channel.

## 6. Implementation

1. `RegionPolicy` (`Whisperer/Compliance/`): `Region` (`.chinaMainland`, `.other`, `.unknown`), `RegulatedFeature`, `allows(_:)` with a reason string; injectable `StorefrontProviding`; debug override `WHISPERER_FORCE_REGION=CHN`.
2. Enforce in layers: UI hides the entry points with a plain "not available in your region" note; services refuse before building a prompt (`ConnectedAIStore.availableProviders/activeProviderID`, `MeetingAIService.ask`); stored provider, consent and keys stay dormant in China and return when the storefront changes.
3. Ask AI tab removed in the China profile; meeting notes keep the local Qwen title/overview.
4. Direct build: also gate rewrite-selection, Command Mode, CLI providers, Privacy Shield by region (MCP stays: it is local).
5. Tests: with a simulated CHN storefront, every `RegulatedFeature` entry point is closed; a grep test fails if a regulated service is referenced outside the policy.
6. Hide Google sign-in in China (unreachable there); keep Apple Calendar and Microsoft.
7. **Model delivery**: huggingface.co is unreliable from mainland China and the code has no mirror. Options: Apple-hosted Background Assets, or our own CDN. Needs its own plan; without it a China user cannot download a model.
8. Default engine for China: Qwen3-ASR is already built in. Choose it as the China default only after a Chinese-accuracy benchmark against Whisper Large V3 Turbo and Apple Speech.
9. zh-Hans strings for the notices and the China App Store listing.
10. App Store Connect: complete both forms (No / No) before the next submission, with review notes explaining the storefront geoblock and screenshots of the China behaviour. Existing app: before 2027-01-31.
11. If the business later wants Ask AI in China: it needs an approved filing number and an authorization from the model's owner. That is a separate project, not a code change.

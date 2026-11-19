# China mainland compliance — plan

Status: implemented (2026-11-17) — China edition + market policy + ModelScope sources. Open items in §9.

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

## 5. Design as built

### 5.1 Two editions

| | Regular | China |
|---|---|---|
| Xcode configuration | `AppStore` | `AppStoreChina` (clone of `AppStore`, added to all four configuration lists) |
| Flags | `APP_STORE` | `APP_STORE CHINA_EDITION` |
| Bundle ID | `com.ivy.whisperer` | `com.ivy.whisperer.cn` |
| App Store Connect | existing record, China mainland removed from availability | separate record, China mainland only |
| Gating | runtime, by storefront | fixed at compile time |

A separate record is needed because App Store Connect cannot ship different binaries per territory within one record. The China record answers both Apple forms **No** (features disabled in the build); the regular record is not sold in China. The direct (website) build follows the system region at runtime. The submission skill (`.claude/skills/submission-prep`) archives both editions every time and checks the marker string `whisperer-edition=china-mainland` (present only in the China binary).

### 5.2 Market detection (`Whisperer/Compliance/MarketPolicy.swift`)

- `Market`: `.chinaMainland`, `.other`, `.unknown`. `MarketPolicy.current` is a lock-protected value readable from any thread; `MarketMonitor` (main actor) updates it.
- App Store build: `Storefront.current?.countryCode == "CHN"` (alpha-3), re-read on `Storefront.updates`. Hong Kong (`HKG`), Macau and Taiwan are `.other`. Last value cached for offline launches.
- Direct build: system region `CN`. China edition: always `.chinaMainland`.
- `unknown` is treated as restricted only for features that need a network (`ComplianceFeature.needsNetwork`), so offline users lose nothing they could have used.
- Debug only: `WHISPERER_FORCE_MARKET=china|other`, `MarketPolicy.testOverride`.

### 5.3 What is closed in China (`ComplianceFeature`)

`askAIChat` (Ask AI tab and `MeetingAIService.ask`), `connectedCloudAI` (provider list, active provider, "Polish with AI" bar), `cliAIProviders`, `commandMode`, `voiceReshaping` (Privacy Shield `start()`), `cloudSync` (`CloudFeature`), `googleCalendar` (`CalendarAccountProvider.available`). Stored provider choices and consent stay dormant and return when the market is not China. **Kept:** MCP, transcription, Fast Polish, local Qwen titles/overviews.

The LLM page hides empty provider groups and is titled "Meeting notes" when Ask AI and cloud are closed.

### 5.4 Model sources (`Whisperer/Transcription/ModelSources.swift`)

Hugging Face is unreliable from mainland China. In China the app downloads from ModelScope (modelscope.cn):

| Model | Source in China |
|---|---|
| whisper.cpp base / small / medium / large-v3 / large-v3-q5_0 (default) | `cjc1887415157/whisper.cpp` — SHA-256 equal to the pins in `ModelChecksums.swift` |
| Silero VAD | `ggml-org/whisper-vad` |
| Qwen3-ASR-1.7B-8bit, Qwen2.5-1.5B, Qwen3.5-2B/4B/9B (MLX) | same repo id under `mlx-community/…` |
| ggml turbo, turbo-q5, distil, ivrit; Parakeet; Nemotron; speaker model; MTP LLM; Whisperer V3 LLM; `whisperer-polish`; WhisperKit | **not on ModelScope** — hidden in China (see §9) |

`ModelScopeFetcher` downloads a repo snapshot into the directory the existing loaders read, verifying each file's Size and SHA-256 from ModelScope's listing, and skips files already present. **China is built around Qwen**: the default engine is Qwen3-ASR (Whisper stays selectable, with large-v3-q5 as its default model there) and the default text model is Qwen3.5-4B (the MTP build when reachable). Meetings still run without the speaker and cleanup models.

`scripts/verify-china-models.sh` checks every row above (reachability and checksums) and is part of the submission skill.

## 6. Tests

`MarketPolicyTests` (storefront mapping, every feature closed in China and open elsewhere, unknown market, providers and Ask AI disappear including stored consent, Cloud and Google closed) and `ModelSourcesTests` (host choice, URL mapping, listing parser, an opt-in real ModelScope download with `TEST_RUNNER_NETWORK_TESTS=1`).

## 7. Verified

- `xcodebuild -configuration AppStoreChina`: builds, bundle id `com.ivy.whisperer.cn`, flags `APP_STORE CHINA_EDITION`, marker string present only in this binary.
- ModelScope sources: `scripts/verify-china-models.sh` all good (2026-11-17).

## 8. If the business later wants Ask AI in China

It needs an approved filing number and an authorization from the model's owner naming us. That is a separate project, not a code change.

## 9. Open items

1. **Missing models in China.** Parakeet, Nemotron, the speaker model, the MTP LLM, Whisperer V3 LLM, `whisperer-polish`, ggml turbo/distil/ivrit have no ModelScope copy. Publish them under our own ModelScope repo (`mralexivy/whisperer-models`, list the files in `ModelSources.ownFiles`) or leave them hidden. Needs a ModelScope account.
2. **Chinese accuracy.** Qwen3-ASR is the China default by decision; still worth a benchmark against Whisper large-v3-q5 on our Chinese corpus.
3. **Manual App Store Connect steps** (skill Step 14): App ID and second record, availability, forms, IAP re-creation, zh-Hans metadata.
4. **Apple's view on on-device summaries.** Not in Apple's trigger list; if App Review objects, the local title/overview is one flag away.
5. Background Assets (Apple-hosted) as a later alternative to ModelScope.
6. **Models built into macOS are not restricted in China (decision 2026-11-19).** Apple's on-device speech
   recognizer (live preview) and Apple Intelligence (Foundation Models, `AppleIntelligenceProvider`) are used in every
   edition and market whenever macOS reports them available; there is no per-market or per-edition list for them. The
   rule above applies to third-party models Whisperer downloads. Consequences: the China edition's meeting title,
   overview and polish may be written by Apple's model instead of Qwen (the user picks it on the LLM page), so the
   review notes must say "Qwen or the model built into macOS". Ask AI is still off in China (`askAIChat`).

## 10. Submission log

- **2026-11-17: "Whisperer China" (`com.ivy.whisperer.cn`, app `6835744579`) submitted to App Review**, version 2.0 build 7, with the Pro purchase `com.ivy.whisperer.propack` ($14.99; app $4.99). Both China forms saved as **No**. App Privacy: Data Not Collected. Availability: China mainland only. The regular app (`6758626671`) no longer lists China mainland.
- Basis for "No" on AIGC: no chat, no image/video, no voice or face alteration, no free-form prompts. The only generated text is a meeting title and short overview from the on-device Qwen (disclosed in the review notes). If App Review objects, the single switch is the meeting-summary feature (`MeetingAIService`, gated by `ProAccess`/`MarketPolicy`).
- Not done: the **ICP Filing Number** block on App Compliance (Apple shows it as "if you have one"); ask Apple if a number is required for this app.
- The first China archive (build 1) wrongly embedded the Privacy Shield driver (`embed-driver.sh` only knew `AppStore`); fixed, build 1 and 2 expired. The submission skill now asserts no driver in either archive.

# Model Licenses

Whisperer is a paid app with a Pro Pack in-app purchase. Every model weight the app downloads
must permit commercial use. This file records the license of each model the app can actually
fetch at runtime.

Date checked: 2026-10-13.

Scope rule: a repo is listed here only when app code can request it. Test, benchmark and corpus
repos in `Vendor/FluidAudio/` (`FluidInference/librispeech`, `fleurs`, `ami-corpus-mirror`,
`test-repo`, the Kokoro, StyleTTS2, Supertonic and SenseVoice entries, and the other unused
`Repo` cases in `Vendor/FluidAudio/Sources/FluidAudio/ModelNames.swift`) are excluded. Whisperer
never calls them.

## Blockers

**None.** No model Whisperer downloads carries a non-commercial or research-only license.

## Open items (not blockers)

1. `mralexivy/whisperer-polish` has **no model card and no license tag** on Hugging Face. The
   repo belongs to the app author, and the weights derive from `jhu-clsp/mmBERT-small` (MIT), so
   commercial use is permitted. Add an explicit `license:` tag and an MIT attribution notice to
   the repo to remove the ambiguity.
2. `FluidInference/parakeet-tdt-0.6b-v3-coreml` shows `cc-by-4.0` in its metadata tag, but the
   card body text says "Apache 2.0". Both permit commercial use, so either reading is safe.
   Treat it as CC-BY-4.0, the stricter of the two, and attribute it.
3. Attribution is a live obligation for the CC-BY-4.0 and OpenMDW models. See "Attribution
   duties" at the bottom.
4. `Whisperer/UI/AcknowledgementsView.swift` credits `nvidia/parakeet-tdt-1.1b`. The app ships
   the 0.6b v2 and v3 CoreML conversions, not the 1.1b model. Correct the link.

## Shipped by default

These download automatically, or on the first use of a default feature.

| Repo ID | What uses it | License | Commercial OK? | Source | Checked |
|---|---|---|---|---|---|
| `mlx-community/Qwen3-ASR-1.7B-8bit` | `Qwen3ASREngine` — default ASR backend | Apache 2.0 | Yes | https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit | 2026-10-13 |
| `ggerganov/whisper.cpp` (`ggml-tiny/base/small/medium/large-v3/large-v3-turbo/*-q5_0.bin`) | `WhisperModel` — `whisperCpp` fallback backend | MIT | Yes | https://huggingface.co/ggerganov/whisper.cpp | 2026-10-13 |
| `ggml-org/whisper-vad` (`ggml-silero-v6.2.0.bin`) | `ModelDownloader` — Silero VAD, always loaded | MIT | Yes | https://huggingface.co/ggml-org/whisper-vad | 2026-10-13 |
| `mralexivy/whisperer-polish` | `PolishModelManager` — polish editor, fetched on first launch | No tag on HF. Derived from `jhu-clsp/mmBERT-small` (MIT). Author-owned. | Yes | https://huggingface.co/mralexivy/whisperer-polish · https://huggingface.co/jhu-clsp/mmBERT-small | 2026-10-13 |
| `Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed` | Default `AppState.selectedLLMModel`, and `MeetingEngines.intelligenceVariant` | Apache 2.0 (base: `Qwen/Qwen3.5-4B`, Apache 2.0) | Yes | https://huggingface.co/Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed | 2026-10-13 |
| `FluidInference/nemotron-3-diarization-coreml` | `MeetingDiarizerService` — meeting speaker separation | OpenMDW v1.1 | Yes | https://huggingface.co/FluidInference/nemotron-3-diarization-coreml | 2026-10-13 |

## User-selectable

A user reaches these by picking a backend, a Whisper model, or an LLM in the Models tab.

| Repo ID | What uses it | License | Commercial OK? | Source | Checked |
|---|---|---|---|---|---|
| `ivrit-ai/whisper-large-v3-turbo-ggml` | `WhisperModel.ivritLargeTurbo` — Hebrew | Apache 2.0 | Yes | https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml | 2026-10-13 |
| `distil-whisper/distil-large-v3-ggml` | `WhisperModel.distilLargeV3` | MIT | Yes | https://huggingface.co/distil-whisper/distil-large-v3-ggml | 2026-10-13 |
| `dharmab/distill-whisper-ggml` | `WhisperModel.distilSmallEn` | MIT | Yes | https://huggingface.co/dharmab/distill-whisper-ggml | 2026-10-13 |
| `FluidInference/parakeet-tdt-0.6b-v2-coreml` | `FluidAudioBridge`, Parakeet v2 | CC-BY-4.0 (base `nvidia/parakeet-tdt-0.6b-v2`, CC-BY-4.0, "ready for commercial use") | Yes, with attribution | https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml | 2026-10-13 |
| `FluidInference/parakeet-tdt-0.6b-v3-coreml` | `FluidAudioBridge`, Parakeet v3 | CC-BY-4.0 tag, Apache 2.0 in card body (base `nvidia/parakeet-tdt-0.6b-v3`, CC-BY-4.0, "ready for commercial use") | Yes, with attribution | https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml | 2026-10-13 |
| `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` | `NemotronBridge` — streaming backend | OpenMDW v1.1 (base `nvidia/nemotron-3.5-asr-streaming-0.6b`, OpenMDW v1.1, "ready for commercial use") | Yes | https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML | 2026-10-13 |
| `mralexivy/nemotron-3.5-asr-streaming-0.6b-hebrew` | `NemotronHebrewBridge` | OpenMDW v1.1, inherited from `nvidia/nemotron-3.5-asr-streaming-0.6b` | Yes | https://huggingface.co/mralexivy/nemotron-3.5-asr-streaming-0.6b-hebrew | 2026-10-13 |
| `argmaxinc/whisperkit-coreml` | `WhisperKitBridge` | MIT | Yes | https://huggingface.co/argmaxinc/whisperkit-coreml | 2026-10-13 |
| `mlx-community/Qwen2.5-1.5B-Instruct-8bit` | `LLMModelVariant.qwen2_5_1_5B` | Apache 2.0 | Yes | https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-8bit | 2026-10-13 |
| `mlx-community/Qwen3.5-2B-MLX-4bit` | `LLMModelVariant.qwen3_5_2B` | Apache 2.0 | Yes | https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit | 2026-10-13 |
| `mlx-community/Qwen3.5-4B-MLX-4bit` | `LLMModelVariant.qwen3_5_4B` | Apache 2.0 | Yes | https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit | 2026-10-13 |
| `mlx-community/Qwen3.5-9B-MLX-4bit` | `LLMModelVariant.qwen3_5_9B` | Apache 2.0 | Yes | https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-4bit | 2026-10-13 |
| `shantanugoel/aawaaz-qwen3-0.6b-transcriber-4bit` | `LLMModelVariant.whispererV3` | Apache 2.0 tag. Card defers to base `Qwen/Qwen3-0.6B`, which is Apache 2.0. | Yes | https://huggingface.co/shantanugoel/aawaaz-qwen3-0.6b-transcriber-4bit | 2026-10-13 |

Apple `SpeechAnalyzer` (`BackendType.speechAnalyzer`) downloads nothing from Hugging Face. The
system supplies the weights under the macOS license.

## Vendored code

| Component | Path | License | Commercial OK? |
|---|---|---|---|
| FluidAudio | `Vendor/FluidAudio/LICENSE` | Apache 2.0 | Yes |
| fastcluster | `Vendor/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md` | BSD 3-Clause (Daniel Müllner, Google Inc.) | Yes |
| VBx | `Vendor/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md` | Apache 2.0 | Yes |
| mlx-swift-lm | `Vendor/mlx-swift-lm/LICENSE` | MIT (ml-explore) | Yes |
| whisper.cpp | `whisper.cpp/LICENSE` | MIT (the ggml authors) | Yes |

## Attribution duties

Permissive does not mean silent. Keep these notices in `Whisperer/UI/AcknowledgementsView.swift`.

1. CC-BY-4.0 requires credit to the creator and a link to the license. This covers both Parakeet
   CoreML repos and their NVIDIA bases.
2. OpenMDW v1.1 requires that the NVIDIA attribution and the license notice travel with the
   weights. This covers the diarizer, the multilingual Nemotron, and the Hebrew fine-tune.
3. MIT and Apache 2.0 require that the copyright notice and the license text stay with any
   redistribution. This covers whisper.cpp, the ggml models, WhisperKit, mlx-swift-lm, FluidAudio
   and every Qwen-derived model.

## Notes on derived weights

- `mralexivy/nemotron-3.5-asr-streaming-0.6b-hebrew` trains on `ivrit-ai/crowd-transcribe-v5` and
  `ivrit-ai/crowd-recital-whisper-training`. The model license is OpenMDW v1.1. Dataset terms are
  a separate question from weight terms; confirm them before any redistribution of the training
  corpus itself. The weights as shipped are clear.
- Several model cards warn that training data carries its own terms. That is standard language
  and does not change the license of the weights.

## How to re-check

1. Open `https://huggingface.co/<repo-id>`.
2. Read the `license:` tag in the card metadata, not only the prose.
3. When the tag and the prose disagree, record both and apply the stricter one.
4. When the repo is a quantization or a conversion, follow the model tree to the base and verify
   the base license too.

# Language Routing Reference

## Overview

When the user configures multiple allowed languages (e.g., English + Hebrew + Russian), the language routing system detects the spoken language at recording start and routes transcription to the appropriate model and language setting. This replaces whisper.cpp's built-in auto-detect, which considers all 100+ languages and produces noisy results.

## Architecture

```
Audio samples (16kHz)
    ↓
VAD filter (SileroVAD — extract voiced segments only)
    ↓
WhisperBridge.detectLanguage() (shared preview bridge, CPU-only tiny model)
    ↓ [String: Float] probabilities for all languages
LanguageRouter (filter to allowed shortlist, score, state machine)
    ↓ RouteDecision (language + confidence)
ModelRouter (map language → model profile, check warm/cold)
    ↓ ModelRouteDecision (language + profile + isFallback)
ModelPool (activate warm backend or return fallback + async load)
    ↓ TranscriptionBackend
StreamingTranscriber (transcribe with fixed language)
```

### Component Files

| Component | File | Purpose |
|-----------|------|---------|
| `WhisperBridge` | `Transcription/WhisperBridge.swift` | whisper.cpp wrapper — transcription + language detection via `detectLanguage()` |
| `LanguageRouter` | `Transcription/LanguageRouter/LanguageRouter.swift` | Stateful language classifier with session-lock state machine |
| `ModelRouter` | `Transcription/LanguageRouter/ModelRouter.swift` | Maps language decisions to model profiles |
| `ModelPool` | `Transcription/LanguageRouter/ModelPool.swift` | Manages all whisper_context instances (preview/detector, fallback, targets) |
| `ScriptAnalyzer` | `Transcription/LanguageRouter/ScriptAnalyzer.swift` | Unicode script classification for post-chunk stabilization |

## whisper.cpp API Usage

The correct detection pattern uses separate whisper.cpp API calls. There is no built-in "preferred languages pool" or "restrict auto-detect to this subset" setting. The shortlist constraint lives entirely in app logic (LanguageRouter).

### Detection Flow (WhisperBridge.detectLanguage)

Detection uses the shared `previewBridge` in ModelPool (CPU-only tiny model). The same context also handles live preview transcription — both operations serialize via `ctxLock`.

```swift
// 1. Convert PCM to mel spectrogram (required before auto-detect)
whisper_pcm_to_mel(ctx, samples, sampleCount, threads)

// 2. Run auto-detection — returns probabilities for ALL languages
let maxId = whisper_lang_max_id()
var probs = [Float](repeating: 0, count: maxId + 1)
let topId = whisper_lang_auto_detect(ctx, 0, threads, probs)

// 3. Map indices to language codes
for i in 0...maxId {
    let code = String(cString: whisper_lang_str(Int32(i)))
    result[code] = probs[i]
}
```

### Transcription with Fixed Language

```swift
// 4. Set chosen language on transcription params
wparams.language = languageCode  // e.g., "he", "en", "ru"
wparams.detect_language = false  // Disable re-detection during decode

// 5. Run transcription
whisper_full(ctx, wparams, samples, sampleCount)
```

### Key API Functions

| Function | Purpose |
|----------|---------|
| `whisper_pcm_to_mel()` | Prepare mel spectrogram from PCM — MUST call before auto-detect |
| `whisper_lang_auto_detect()` | Detect language from mel, fills probability array for all languages |
| `whisper_lang_max_id()` | Number of supported languages (for sizing probability array) |
| `whisper_lang_id()` | Get numeric ID for a language code |
| `whisper_lang_str()` | Get language code string from numeric ID |
| `whisper_full_lang_id()` | Language ID from last decode pass (decoder state, not independent detection) |
| `whisper_is_multilingual()` | Check if model supports multiple languages |

## LanguageRouter State Machine

```
undecided → locked(language) → suspectedSwitch(candidate, checkCount) → locked(new)
    ↑                                      ↓ (not confirmed)
    └──────────────────────────────────────┘
```

- **undecided**: No language decided yet. Requires `routeThreshold` (0.75) confidence to lock.
- **locked**: Language chosen. Re-detection only on script mismatches (3+) or new utterance after silence.
- **suspectedSwitch**: Different language scored higher by `switchMargin` (0.20). Needs `switchConfirmations` (2) consecutive checks to confirm switch.

### Composite Scoring

For initial routing (no transcript yet):
```
score = 0.875 × normalizedProb + 0.125 × prior
```

For post-chunk stabilization (transcript available):
```
score = 0.70 × normalizedProb + 0.20 × scriptHint + 0.10 × prior
```

Prior bonuses: primary language (+0.05), currently locked (+0.08), last session (+0.02).

### Confidence-Gated Fast Path

When the voiced audio window is short (< 3s), detection requires the top language to beat the runner-up by `fastPathMargin` (0.30) before locking. This prevents premature locking on uncertain short-window detections while allowing fast detection when confidence is high.

## VAD-Filtered Detection

Detection runs on VAD-filtered audio, not raw samples. SileroVAD (8kHz/16kHz) extracts voiced segments; silence is stripped before passing to `whisper_lang_auto_detect()`. This provides denser speech signal for detection.

- Minimum 1.5s (24000 samples) of voiced audio required before detection proceeds
- If insufficient voiced audio, detection is skipped without consuming retry budget
- Up to 3 detection attempts with 1s growth per retry
- Uses single-allocation buffer: compute total voiced length, `reserveCapacity`, append slices

## Per-Chunk Language Reinforcement

After each chunk transcription, `whisper_full_lang_id()` provides the decoder's language state. This is treated as a **weak signal** (not an independent classifier):

- Separate `chunkLangMismatchCount` counter with decay on agreement
- Combined with script mismatches at half-weight: `combinedMismatches = scriptMismatches + (chunkLangMismatches / 2)`
- Triggers re-detection when combined mismatches reach threshold (3+)

`whisper_full_lang_id()` reflects the decoder state of the current pass, not a fresh language classification. Do not treat it as authoritative.

## Script Analysis

`ScriptAnalyzer` detects Unicode script families from transcript text, then maps to candidate languages filtered by the user's allowed shortlist. **Script is not language** — this is heuristic support for the probability-based router.

### Script Families Detected

Latin, Cyrillic, Hebrew, Arabic, Devanagari, Greek, Armenian, Georgian, Thai, Hiragana, Katakana, Hangul, CJK.

Coverage is heuristic (sufficient for speech transcription output). CJK Extensions B-J (0x20000+) are omitted as rare in transcription.

### CJK Disambiguation

CJK characters (Unified Ideographs + Extension A) are shared by Chinese, Japanese, and Korean:
- If Hiragana or Katakana also detected → attribute CJK to Japanese
- If Hangul also detected → attribute CJK to Korean
- Otherwise → attribute CJK to Chinese (if in allowed shortlist)

## ModelPool — Backend Management

ModelPool owns all whisper_context instances:

| Slot | Purpose | Always loaded? |
|------|---------|----------------|
| Preview/Detector | Live preview + language detection (tiny model, CPU-only) | Yes (when routing enabled) |
| Fallback | Multilingual model for transcription while target loads | Yes |
| Target | Specialized model for detected language | Loaded on demand |

The preview/detector bridge uses `useGPU: false` to avoid Metal contention with the main model and SwiftUI rendering. CoreML encoder still uses ANE regardless of the `useGPU` flag.

### Warm vs Cold Routing

- **Warm**: Target model already loaded → use directly, zero latency
- **Cold**: Target model not loaded → use fallback (multilingual) immediately, load target async, promote at next chunk boundary

In-flight loads are deduplicated by ModelProfile. Standby models can be preloaded if memory allows (1GB headroom check via `SystemMemory.availableGB()`).

## Common Pitfalls

1. **whisper_pcm_to_mel() must precede whisper_lang_auto_detect()** — The API requires mel preparation before detection. `WhisperBridge.detectLanguage()` handles this.

2. **C string lifetime during detection** — Language codes passed to `wparams.language` must remain alive during `whisper_full()`. Use `withCString` to keep the pointer valid.

3. **Detection shares the preview bridge context** — `ModelPool.previewBridge` handles both live preview and language detection via `WhisperBridge.detectLanguage()`. Both operations serialize via `ctxLock`. Never create a separate detector context — it wastes ~77MB and causes GPU contention.

4. **whisper_full_lang_id() is decoder state** — It reflects the language used in the most recent decode pass, not an independent per-chunk classification. Treat as weak evidence only.

5. **Non-multilingual models cannot route** — `whisper_is_multilingual()` must return 1 for routing to work. English-only models bypass the router entirely.

6. **Detection retry budget** — `detectionAttempts` only increments when detection was actually attempted (sufficient voiced audio). Silence-heavy recordings never exhaust the budget.

7. **ScriptAnalyzer is heuristic** — Script detection provides supporting evidence for the probability-based router. It does not authoritatively identify languages. Cyrillic is not "Russian"; Latin is not "English".

8. **ModelProfile warm check compares model binary** — `ModelRouter.resolve()` and `ModelPool.routeTarget()` check `model` + `backend` fields, NOT `language`. Same `.bin` file with `language: .auto` vs `language: .english` = same backend. Loading a duplicate model during recording causes 1.6s GPU freeze and HUD stutter.

9. **Preview bridge must be CPU-only** — `ModelPool.previewBridge` (`useGPU: false`) handles both live preview and detection. GPU causes Metal contention with the main model and SwiftUI rendering, freezing HUD animations. CoreML encoder still uses ANE regardless of the `useGPU` flag (loaded unconditionally by whisper.cpp).

10. **Core ML first-run compilation** — First launch after install takes ~40s for Core ML encoder compilation (logged as `"first run on a device may take a while"`). Subsequent launches use cached compiled model (~2s). This is an Apple Neural Engine behavior, not a bug.

## Live Preview Architecture

Live transcription preview uses the shared `previewBridge` (CPU-only tiny model) to show text during recording, before VAD chunks finalize. The same bridge also handles language detection — both operations serialize via `ctxLock`.

### Append-Only Design

Each preview pass transcribes only NEW audio since the last pass (with 0.5s overlap for boundary quality). Text is appended to `previewAccumulatedText`, never replaced. This ensures `SmoothTextUpdater.hasPrefix` always succeeds → smooth word-by-word animation.

```
Pass 1: transcribe audio[0..1.5s]    → "Hello how are"
Pass 2: transcribe audio[1.0..2.5s]  → dedup → append " you doing"
Pass 3: transcribe audio[2.0..3.5s]  → dedup → append " today"
Display: "Hello how are you doing today"
```

### Why Not Re-Transcribe the Tail

Previous approach re-transcribed the entire unchunked tail every pass. This caused:
- **Text jumping** — same audio produces slightly different text each pass → `hasPrefix` fails → `SmoothTextUpdater` takes "fundamental change" path → instant replacement = visible jump
- **HUD stutter** — re-transcribing 5-10s of audio on the main model takes 300-700ms of GPU time

### Chunk Handoff

When a VAD chunk finalizes:
1. `completedChunkTexts` gets the main model's high-quality text
2. `previewAccumulatedText` is cleared
3. `lastPreviewedSampleIndex` resets to `lastTranscribedSampleIndex`
4. Preview starts fresh for the next unchunked tail

### Detection Gating

Preview waits for `routeDecision != nil` (language detection complete) or 5s timeout before starting. This prevents wrong-language preview text.

## RTL Rendering

### SwiftUI Text Limitations

SwiftUI `Text` does NOT support paragraph base writing direction control under an en-US device locale. Six approaches were tested and all failed to make multiline Hebrew text start lines from the right margin. The system resolves "natural" writing direction to LTR based on user language preferences (en-US), regardless of content.

### NSTextField Solution

`TranscriptionTextView` (NSViewRepresentable) wraps `NSTextField` and sets `NSParagraphStyle.baseWritingDirection = .rightToLeft`. AppKit renders via Core Text directly — guaranteed correct paragraph direction.

### RTL Detection

Two-level detection, content-based takes priority:

1. **Content-based** (`detectRTL(in:)`) — scans first 50 chars of transcript for Hebrew/Arabic Unicode. Triggers immediately when RTL text appears.
2. **Language-based** (`TranscriptionLanguage.isRTL`) — set from `selectedLanguage` at recording start, updated by `onLanguageDetected`.

### RTL Animation

Word-by-word animation is skipped for RTL — text shows immediately. The typewriter effect reveals words left-to-right visually, which looks wrong for RTL scripts.

## Core ML Encoder Acceleration

### Build Setup

whisper.cpp static library compiled with:
```bash
cmake .. -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON ...
```

Xcode project links: `libwhisper.a` + `libwhisper.coreml.a` + CoreML.framework.
`WHISPER_USE_COREML=1` in all build configs.

### Runtime Behavior

whisper.cpp automatically looks for `{model-name}-encoder.mlmodelc` next to the `.bin` file. If found → encoder runs on ANE. If not → falls back to Metal GPU silently.

### Encoder Downloads

Pre-converted Core ML encoders hosted on HuggingFace:
- `ggml-tiny-encoder.mlmodelc.zip` (~15MB)
- `ggml-large-v3-turbo-encoder.mlmodelc.zip` (~1.1GB)

`ModelDownloader.ensureCoreMLEncoder(for:)` downloads and unzips automatically.

### Selective ANE Usage

Only download Core ML encoders for models that benefit. The main model (large-v3-turbo) benefits significantly (~19% faster). The tiny preview/detector bridge also uses ANE via CoreML (loaded unconditionally regardless of `useGPU` flag). Models without `.mlmodelc` stay on Metal GPU.

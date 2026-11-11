# Live preview: Apple dictation vs WhisperKit base / small / large-v3 turbo (2026-11-11)

All numbers measured on this Mac (M2 Pro), in-process, by `WhispererTests/LivePreviewEngineBenchmarkTests`
(the app's own `SystemLivePreviewBridge` for Apple; WhisperKit `argmax-oss-swift` 1.1.0, mel on CPU,
encoder and decoder on the Neural Engine). Scored by `Tools/omni-eval` (`preview_metrics.py`,
`stream_events_report.py`, `preview_bench_report.py`). Raw data in `hyp/` and `results/`.

## Verdict

- **The live preview stays Apple.** It is the only engine that is live: words as spoken (lag ≈ 0,
  ~34 updates per clip), 1.4 % of shown words revised, every short reply right (24/24), no compute
  in our process, +0 % on the main engine.
- **WhisperKit large-v3 turbo is the most accurate engine** (he CER 10.6 vs Apple 13.5, en 2.5 vs 5.5,
  mixed-language 48 vs 61, noisy 7/35/6 vs 17/66/11) with real punctuation and working language ID,
  but streams only by re-decoding once a second: 0.7 s lag, 1.5 s to final, 0.76 s of Neural Engine
  per update, and **10 of 24 short replies come back empty** (the loop needs a second of new audio and
  drops short bursts as silence). Not a live engine.
- Recommended next step: Apple live + **large-v3 turbo re-reading each settled paragraph** with the
  language Apple's probe found — and benchmark it first on the **whisper.cpp** V3 turbo that every
  meeting already has resident (no extra 630 MB, no 174 s first load; one decode per paragraph rather
  than per second). Not measured yet.
- WhisperKit base and small are not candidates: weaker than Apple in Hebrew, unusable with automatic
  language, unstable when streaming (the same 6 Russian clips: 42.9 % then 7.4 % WER in two runs).

## Does WhisperKit stream?

Not truly, for any model. Open-source WhisperKit's `AudioStreamTranscriber` re-transcribes the buffer
from the last confirmed segment every second of new audio and confirms all but the last two segments.
"Real-time transcription" is listed as an Argmax **Pro SDK** feature (README of the package we ship).

## Accuracy (whole clip; FLEURS 100 per language, 40 code-switched, 90 noisy)

Char. error / WER / meaning words kept (IDF-weighted recall) / sentence-end F1:

| | he | ru | en |
|---|---|---|---|
| Apple, pinned | 13.5 / 30.9 / 70 / 0 | **3.7** / 12.3 / 88 / 8 | 5.5 / 12.4 / 88 / 42 |
| WhisperKit base, pinned | 27.6 / 66.0 / 36 / 14 | 7.2 / 24.5 / 76 / 50 | 6.0 / 13.2 / 88 / 70 |
| WhisperKit small, pinned | 17.2 / 44.4 / 56 / 13 | 5.2 / 13.8 / 87 / 65 | 3.5 / 7.8 / 93 / 68 |
| **WhisperKit v3 turbo, pinned** | **10.6 / 27.5 / 73 / 50** | 4.0 / **6.9 / 94 / 69** | **2.5 / 5.8 / 94 / 82** |
| WhisperKit v3 turbo, auto | 12.1 / 28.1 / 72 / 50 | 3.0 / 6.9 / 94 / 69 | 2.5 / 5.8 / 94 / 81 |
| WhisperKit small, auto | 59.6 / 87.0 / 39 / 5 | 75.3 / 100 / 20 / 26 | 3.5 / 7.7 / 93 / 68 |

Mixed-language CER: Apple 61.1, small 80.1 (18.6 invented words / 100), v3 turbo 47.5.
Noisy CER (babble / room pink / laptop mic): Apple 17.1 / 66.2 / 10.9, small 18.2 / 51.4 / 9.5,
base 27.3 / 63.0 / 25.0, v3 turbo 6.8 / 34.6 / 6.4.
Language detection on its own (auto): v3 turbo he 92/100, ru 85/100 (all Cyrillic), en 100/100;
small/base mis-script 33–39 % of he/ru.

Metric notes: WER over-punishes Hebrew/Russian morphology (one wrong prefix fails a word), so CER is
the primary; "meaning words" weights recall by rarity over each language's full FLEURS test set;
punctuation is scored at aligned word positions against FLEURS' punctuated transcripts. The Apple
**auto** accuracy rows from the offline phase are invalid (the clip ends before the probe answers) —
use the real-time rows.

## Live (1× playback, 18 clips)

| | Apple pin | Apple auto | small pin | v3 turbo pin | v3 turbo auto |
|---|---|---|---|---|---|
| WER while streaming | 16.8 | 22.5 | 28.6 | **12.4** | 13.1 |
| First correct word | 1.7 s | 3.2 s (he 3.9) | 2.8 s | 2.3 s | 2.5 s |
| First committed word | **2.1 s** | 2.3 s | 3.5 s | 3.5 s | 3.8 s |
| Lag behind speaker | **≈0** | ≈0 | 0.5 s | 0.7 s | 0.8 s |
| Final after speech ends | **0.1 s** | 0.1 s | 1.2 s | 1.5 s | 1.8 s |
| Shown words revised | **1.4 %** | 2.3 % | 8.7 % | 2.7 % | 4.3 % |
| Updates per clip | **34** | 36 | 11 | 11 | 11 |
| Compute per update p50 / p95 | — | — | 0.50 / 1.03 s | 0.76 / 1.26 s | 0.84 / 1.34 s |

## Edge cases

| | Apple pin | Apple auto | small | v3 turbo |
|---|---|---|---|---|
| 24 short replies (TTS, en/ru/he) | **24/24, 0 % WER** | 8/24 right language | 10 empty | 10 empty |
| Silence, invented words / clip | 1,0,1,1 | 1,0,1,1 | **0,0,0,0** | 2,0,2,2 |
| Quiet −26 dB, WER | 34 % | 36 % | 63 % | **32 %** |
| 236 s he/en/ru/he/en, longest wait for new words | — | 6.7 s | 26.6 s | **5.5 s** |

Apple-auto short replies: a phrase under ~2 s ends before the language probe decides, so it stays in
the session's start language (the benchmark starts every session in English; the app starts in the
last language used, which hides most of this).

## Cost and contention

Main engine (whisper.cpp V3, 15 s clip) decode p50 1.57 s alone; with a preview streaming beside it:
Apple +0 %, base +2 %, small +2 %, v3 turbo +1 % (Neural Engine and GPU do not contend).
Whisperer-process power while streaming: Apple 0.15 W (its recognizer runs in a system process,
not counted), base 0.35 W, small 0.52 W, v3 turbo 0.54 W pinned / 0.76 W auto. v3 turbo: 630 MB
download, 174 s first load+warm (Core ML compile).

Not measured: Apple's out-of-process CPU (the counter read running totals); 8/16 GB Macs; a
long-meeting soak; whisper.cpp V3 as a per-paragraph refiner.

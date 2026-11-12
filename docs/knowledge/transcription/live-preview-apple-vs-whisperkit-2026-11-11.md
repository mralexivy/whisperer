# Live preview: Apple dictation vs WhisperKit base / small / large-v3 turbo (2026-11-11)

All numbers measured on this Mac (M2 Pro), in-process, by `WhispererTests/LivePreviewEngineBenchmarkTests`
(the app's own `SystemLivePreviewBridge` for Apple; WhisperKit `argmax-oss-swift` 1.1.0, mel on CPU,
encoder and decoder on the Neural Engine). Scored by `Tools/omni-eval` (`preview_metrics.py`,
`stream_events_report.py`, `preview_bench_report.py`). Raw data in `hyp/` and `results/`.


## Final results (supersede everything below this section)

The sections below were written before four harness errors were found and fixed: WhisperKit
live ran through a re-implementation of its demo loop instead of the app's streaming; the app
passes WhisperKit as its own preview bridge and the harness did not (no live passes ran);
pinned runs got a one-language router the app never builds; Apple-auto accuracy ended before
the probe answered. The WhisperKit live rows and the early verdict below are therefore wrong.

**Engines, through the app's own code** (whisper.cpp = Whisperer V3 q5_0; WhisperKit = large-v3
turbo 632 MB, the app's variant; 547 MB measured as the same-size match to q5_0).

| | Apple | whisper.cpp q5_0 | WhisperKit 632 MB |
|---|---|---|---|
| Whole-utterance WER he / ru / en (100 clips each) | 30.9 / 12.3 / 12.4 | **25.0 / 5.4 / 4.8** | 26.9 / 5.7 / 5.4 |
| Same, case + punctuation counted | 40.6 / 29.3 / 23.9 | **30.4 / 11.1 / 10.4** | — |
| Sentence-end F1 he / ru / en | 0 / 8 / 42 | **53 / 67 / 76** | 50 / 67 / 82 |
| Live: behind the speaker / gap between updates | **0.22 s / 0.42 s** | 0.69 s / 0.77 s (after the 2026-11-11 fixes) | 0.33 s / 0.67 s |
| Live: longest freeze / words per update | **0.95 s / 1** | 1.6 s / 2 | 2.3 s / 2 |
| Live final WER, same 18 clips | 15.3 | 23.6 (streamed) — 7.7 decoded whole | 21.6 |
| GPU while live | 0 % | ~50 % | 0 % (Neural Engine) |
| 6 s dictation decode alone / beside a live preview on the same model | — | 0.80 / 1.57 s (p95 3.4) | 0.67 / 1.13 s |

All whole-utterance differences between Apple and whisper.cpp are outside their 95 % bootstrap
intervals (`compare_paired.py`). WhisperKit 547 MB is clearly worse than q5_0 at the same size
(he CER 15.9 vs 9.7).

**Decisions.** Apple drives live text; Whisper (q5_0) produces the kept text. Whisper decoded
whole is twice as accurate as Apple; streamed it is worse than Apple — so whatever is saved must
come from a whole decode. Meetings already do this (refine pass); dictations still save the
streamed text: the open item.

**Shipped from this work** (main): no previous-text prompt and no whole-pass hold on anchor
loss in the whisper.cpp eager stream (updates 1.44 → 0.77 s, longest freeze 2.4–2.9 → 1.5–1.6 s,
final WER on 60 clips not worse, English better); WhisperKit decodes speech under 1 s, retries
failed windows, and starts auto-language live text without the 5 s route gate.

**Option 4 (one Whisper engine for live and final), q5_0.** No prompt and no whole-pass holds
are the only changes that clearly help. Confirming before the language is locked hurts auto
mode; an AlignAtt-lite time guard of 1.0 s is indistinguishable from plain agreement at this
sample size, 0.6 s is worse; window, commit and threshold settings do not change the update
cadence (it is set by decode time: ~0.6 s whisper.cpp, ~0.7 s WhisperKit with its fixed 30 s
encoder). Run-to-run noise on 18 clips is about ±8 WER points.

**Open bugs.** WhisperKit auto language locks the first language for the session (a he/en/ru
recording came back Hebrew only, 97 words, a 156 s gap). whisper.cpp pinned streaming still
loses some words. Quiet speech is worse without holds (3 clips — check on more).

## Verdict (initial — superseded above)

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

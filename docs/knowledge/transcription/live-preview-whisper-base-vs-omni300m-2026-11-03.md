# Live preview: Whisper Base vs Omnilingual CTC 300M Core ML (2026-11-03)

Origin labels: **[new]** measured in this session, **[existing]** earlier benchmark in this repo, **[pub]** third-party published
(model card / docs), **[inferred]** derived from other numbers, **[unknown]** not established.

## Verdict

**No unconditional winner, and no candidate meets the Hebrew gate.** Omni 300M INT8 on the Neural Engine does **not** replace
Whisper Base as a universal live-preview model.

- Whisper Base is better on English (9.9 vs 17.5 WER) and Russian (23.7 vs 30.6), is ~9× cheaper per pass (0.13 s vs 1.15 s),
  and disturbs the final ASR less (Qwen3 +4% vs +15%).
- Omni 300M is better on Hebrew (50.5 vs 62.8 WER) and on mixed-language speech (44.8–49.1 vs 80.3–93.4 WER), and has no
  language lock.
- Both are poor at Hebrew (>50% WER), so neither is a usable Hebrew preview on its own.
- The Core ML encoder acceleration of Whisper Base is sufficient: its encoder runs fully on the Neural Engine at ~48 ms. The
  remaining cost is the ggml decoder.

## 1. What Whisperer actually used for preview [existing + new git inspection]

- **The historical preview/detector model was Whisper Tiny, not Base.** `WhisperModel.detectorModel = .tiny`
  (`ggml-tiny.bin`, ~75 MB f16, multilingual), loaded as a CPU-only `WhisperBridge` ("CPU-only tiny model (WhisperBridge) …
  for live preview", `StreamingTranscriber.swift:557`; introduced `00d3becf` 2026-03-28). It was CPU-only on purpose because
  "Metal contention with the main model freezes the HUD" (`docs/knowledge/transcription/knowledge.md`). Its encoder had a Core
  ML variant name (`ggml-tiny-encoder.mlmodelc`) in that era's code; whether Core ML was active in the shipped build at the time
  is **[unknown]**. The whisper.cpp library has been built with Core ML OFF since 2026-08-15.
- **Today there is no separate preview model on the whisper.cpp path**: `livePreviewBridge(for:)` returns `nil`; the main V3
  model's eager stream is the preview (CLAUDE.md). Qwen3 previews through its own bridge (LocalAgreement, ~9× real time).
- **Whisper Base only exists as the bundled stand-in** (`base-q5_1`, 59.7 MB, Metal), never as a preview engine.
- CLAUDE.md forbids restoring a second whisper context for preview (≈77 MB, Metal contention, HUD freezes). A Whisper Base
  preview would overturn that rule, so it needs the contention evidence in §5 to justify it.
- Reused: FLEURS manifests (100 × he/ru/en, seed 42), `score.py`, `stream_sim.py` logic, the 40 mixed clips, Qwen3 resource
  numbers. No earlier tiny/base preview WER or streaming numbers existed except one-clip notes **[existing]**.

## 2. Candidates, runtimes, provenance

| | Whisper Base | Omni CTC 300M |
|---|---|---|
| Checkpoint | `ggerganov/whisper.cpp` rev `5359861c`: `ggml-base.bin` (f16), `ggml-base-encoder.mlmodelc`, `ggml-base-q5_1.bin` | `aufklarer/Omnilingual-ASR-CTC-300M-CoreML-INT8` (5 s, rev `a755e007`) and `…-INT8-10s` (10 s, rev `ce99f14b`) |
| Upstream model | OpenAI Whisper base (multilingual) | `facebook/omniASR-CTC-300M` per model card. The card says vocab 10,288, which is the v2 vocabulary; version labelling is inconsistent **[unknown]** |
| Parameters | ~74 M **[pub]** | 326 M **[pub]** (model card) |
| Runtime | whisper.cpp 1.8.3, Core ML encoder + ggml decoder. Local build from the vendored source with `WHISPER_COREML=1` | `speech` CLI 0.0.29 (soniqo/speech-swift), Core ML MLProgram, CPU+NE |
| Disk **[new]** | 148 MB (f16) + 39 MB encoder = 187 MB; q5_1 alone 59.7 MB | 312 MB per window variant |
| Window | encoder fixed to 30 s | **fixed input**: 5 s or 10 s per model; longer audio is chunked by the runtime |
| Output | cased, punctuated | lowercase, no punctuation |

## 3. Matched accuracy on FLEURS, full 100 clips per language [new]

Greedy decoding, no prompt, same audio and `score.py` normalization. WER % / CER %.

| Engine | he | ru | en | mixed (40) |
|---|---|---|---|---|
| Whisper Base, Core ML enc + CPU dec, pinned language | 62.8 / 24.8 | 23.7 / 6.3 | **9.9 / 4.2** | 93.4 / 75.4 (pinned he) |
| Whisper Base, language auto-detect | 64.4 / 27.8 | 23.7 / 6.3 | 9.9 / 4.2 | 80.3 / 63.4 |
| Whisper Base q5_1, Metal (the app's build) | 63.3 / 25.4 | 24.1 / 6.3 | 10.3 / 4.5 | – |
| Whisper Tiny CPU (historical preview) | 76.3 / 31.9 | 35.6 / 10.5 | 12.8 / 5.6 | – |
| **Omni CTC 300M Core ML, 10 s window** | **50.5 / 16.7** | 30.6 / 6.9 | 17.5 / 6.1 | 49.1 / 23.7 |
| Omni CTC 300M Core ML, 5 s window | 56.2 / 21.2 | 36.1 / 8.7 | 22.1 / 8.1 | **44.8 / 17.1** |
| *Reference [existing]:* Qwen3-1.7B / Omni CTC 3B 4-bit / ivrit-v3-turbo | 77.2 / 28.6 / **14.8** | 6.4 / 11.7 / – | 4.1 / 10.3 / – | 55.4 / 70.7 / 69.7 |

- **Language misidentification:** Whisper Base auto-detect: he → `ar` on 5/100 Hebrew clips, 0/100 for ru and en. Omni has no
  language ID (language-agnostic); 1 Hebrew clip at 5 s produced mostly non-Hebrew script.
- **Hallucinations / translation:** no translation outputs and no repetition loops in 300 clips for Whisper Base or Omni
  (heuristic: output >1.6× reference words or a repeated trigram ≥3×). Whisper Tiny: 2 loop-suspect clips.
- **Short clips (<7 s)** keep the same ordering: he 69.6 (Base) vs 52.8 (Omni-10); ru 22.9 vs 33.3; en 12.1 vs 19.9
  (small n: 9 ru and 22 en clips).
- **Mixed set caveat:** the 40 clips are synthetic concatenations, switch language at sentence boundaries, and cover he↔en and
  he↔ru only. Omni's advantage is partly structural: each fixed window is decoded independently, so a switch between windows
  is free. It says nothing yet about mid-sentence switching or ru↔en. No spontaneous recordings were evaluated **[unknown]**.

## 4. Progressive streaming [new]

18 clips (6 per language, 8–14 s), fed in 2 s increments, repeated offline decode of the growing prefix. This is **not**
incremental inference for either engine: neither keeps decoder or encoder state between passes. Committed text uses
LocalAgreement-2. "Compute" is model-only time per pass (process start and load excluded).

| Engine | 1st partial (audio s) | 1st correct word | 1st committed word | Flicker | Final WER | Committed WER | Compute p50 / p95 per pass |
|---|---|---|---|---|---|---|---|
| Whisper Base (CML enc + CPU dec) | 2.0 | 3.3 | 5.7 | 19.7% | 33.2 | 41.0 | **0.13 / 0.24 s** |
| Whisper Tiny CPU | 2.0 | 3.5 | 5.1 | 19.5% | 45.3 | 43.9 | 0.28 / 0.36 s |
| Omni 300M, 10 s window | 2.1 | 2.9 | 5.2 | 16.0% | 32.6 | 38.4 | 1.15 / 2.30 s |
| Omni 300M, 5 s window | 2.1 | 2.7 | 5.2 | **8.6%** | 39.2 | 40.2 | 1.16 / 1.74 s |

- First-partial times are bounded by the 2 s hop, not by the engines. Time-to-first-correct-word and stable-prefix latency are
  within ~0.5 s of each other.
- Omni is slightly more stable (lower flicker, especially at 5 s) but costs ~9× more compute per pass. Because the Core ML
  input is fixed-size, a 2 s prefix costs as much as a full window (~1.15 s for 10 s, ~0.6 s per 5 s window).
- **Backlog:** at a 2 s hop, Omni's p95 pass (2.3 s) exceeds the hop, so a naive growing-prefix loop falls behind on long
  utterances; Whisper Base uses ~6% of the hop. A real integration would decode only the trailing window.
- Not measured: language-switch recovery time as a duration, end-of-utterance finalization delay, backlog over a long
  recording. All streaming numbers come from fresh processes per pass (**no persistent in-process runtime was tested**).

## 5. Compute units, memory and concurrency

**Planned device placement [new]** (Core ML `MLComputePlan`, `Tools/omni-eval/computeplan/`; planned, not a power trace):
- Whisper Base encoder: 153/153 ops on the Neural Engine, 100% of cost weight. The decoder is ggml (CPU with `-ng`, else Metal).
- Omni 300M 10 s: with default units 94% of ops on the ANE but ~20% of cost weight planned on the **GPU**; restricted to
  CPU+NE: 99% of ops on the ANE and ~27% of cost on the **CPU** (3 front-end convs, GELU, cast, which the ANE can't run).
- Runtime ANE/GPU utilization and battery energy were **not measured**: `powermetrics` needs sudo, which was unavailable.

**Process memory and CPU time, 30 s clip, median of 3 [new]:**

| Engine | Peak footprint | RSS | CPU-s per audio-s (user+sys) |
|---|---|---|---|
| Whisper Base, Core ML enc + CPU dec | 213 MB | 241 MB | 0.025 |
| Whisper Base, Core ML enc + Metal dec | 213 MB | 241 MB | 0.007 |
| Whisper Base q5_1, Metal (app build) | 122 MB | 144 MB | 0.005 |
| Whisper Tiny CPU (historical) | 153 MB | 180 MB | 0.047 |
| Omni 300M Core ML 10 s | 241 MB | 654 MB | 0.133 |
| Omni 300M Core ML 5 s | 154 MB | 654 MB | 0.119 |
| Qwen3-1.7B 8-bit (final, reference) | 5,451 MB | 2,472 MB | 0.055 |

Footprint excludes ANE-side allocations (not observable here), and Omni's 654 MB RSS includes mapped model files. CPU time is
only a host-side proxy for energy. Per audio second, Omni uses ~5× (CPU decoder) to ~19× (Metal decoder) the host CPU of
Whisper Base. Model-load cost differs between engines; process start is included in these CPU figures.

**Preview + Qwen3 final running at once [new]**, M2 Pro 32 GB. Qwen3 transcribes a 30 s clip back-to-back (fresh process each
time, so load churn included) while each preview engine runs the streaming workload (106 passes each):

| Preview running | Preview pass p50 / p95 / p99 (idle → loaded) | Qwen3 30 s clip, median (p95) |
|---|---|---|
| none | – | 1.63 s (1.65) |
| Whisper Base CML enc + CPU dec | 0.13 / 0.24 / 0.27 → 0.15 / 0.28 / 0.33 s (+15% p50) | 1.69 s (1.82), **+4%** |
| Whisper Base CML enc + Metal dec | not run idle → 0.18 / 0.40 / 0.59 s | 1.73 s (1.80), +6% |
| Omni 300M Core ML 10 s | 1.15 / 2.30 / 2.31 → 1.22 / 2.39 / 2.44 s (+6% p50) | 1.87 s (2.09), **+15%** |

- Whisper Base on a CPU decoder is the least intrusive; putting its decoder on Metal adds p99 tail and slows Qwen3 slightly more.
- Omni is mostly ANE but still slows the GPU-bound Qwen3 by 15% (shared memory bandwidth, the planned GPU ops, and its high host
  CPU use are all candidate causes; not isolated).
- No thermal warning level was recorded by `pmset -g therm` over ~20 min of loaded runs. 2–180-minute residency and memory
  growth were not tested **[unknown]**. The concurrent run with the **ivrit** final model was not done **[unknown]**.
- **8 GB / 16 GB were not run [unknown].** Inferred from footprints: either preview is ≲0.25 GB on its own; the constraint is the
  final model (Qwen3 reaches 5.5–6.8 GB at 30–60 s **[new, from the earlier benchmark]**).

## 6. Commercial deployment [pub, verified against the HF/GitHub APIs on 2026-11-03]

| Component | License | Notes |
|---|---|---|
| OpenAI Whisper (code, weights) | MIT / Apache-2.0 (HF `openai/whisper-base` lists apache-2.0, GitHub repo MIT) | include license notice |
| whisper.cpp + `ggerganov/whisper.cpp` models | MIT | Core ML encoder from the same repo |
| `facebook/omniASR-CTC-300M`, omnilingual-asr repo | Apache-2.0 (README: "code and models … Apache 2.0") | include license and notices |
| `aufklarer/Omnilingual-ASR-CTC-300M-CoreML-INT8(-10s)` | Apache-2.0 (card) | third-party conversion by `aufklarer`; provenance as stated on the card, quality not independently verified |
| `soniqo/speech-swift` runtime | Apache-2.0 | |

No noncommercial-only artifact was found for either candidate. Downloading weights through the app and offline operation after
install are permitted by these licenses. App Store review of a downloaded Core ML model was not assessed.

## 7. Recommended configurations

- **Not a recommendation to ship either as Hebrew preview.**
- **32 GB:** Whisper Base (Core ML encoder, CPU decoder) as the resident en/ru preview beside Qwen3 final; keep ivrit-v3-turbo as
  the Hebrew final. Omni 300M is an optional second preview for Hebrew/mixed audio, not as a replacement.
- **16 GB / 8 GB [inferred]:** Whisper Base only, with the final-model segment length capped. Don't keep Omni plus Qwen3 resident on 8 GB.
- Both previews are small relative to Qwen3; memory is not the discriminating factor, compute cost and contention are.

## 8. Minimal next steps

1. Decide whether the "no second whisper context" rule should yield: this data says a Core ML + CPU-decoder Base context costs
   ~213 MB and slowed Qwen3 by 4%, with no Metal use. It needs a Core ML-enabled build of the library (Core ML is OFF today
   because the fixed-shape encoder conflicts with `audio_ctx` in the eager path), used only for the preview context.
2. For Hebrew preview, test the smallest Hebrew-specific option rather than either model here (e.g. a ggml-converted small
   Hebrew fine-tune, if one with a commercial license exists). This was not tested.
3. If Omni is pursued: a persistent in-process Core ML runner that decodes only the trailing window, to see whether compute
   falls well below 1.15 s per pass and whether the 15% Qwen3 slowdown persists.

## Artifacts

`Tools/omni-eval/`: `run_whisper.py`, `stream_preview.py`, `stream_report.py`, `qwen_loop.py`, `computeplan/main.swift`,
`results/stream-*.jsonl`, `results/qwen-loop-*.jsonl`, `results/cpu-mem-30s.json`, `hyp/w*.jsonl`, `hyp/omni300-cml-*.jsonl`.
Whisper.cpp Core ML build is in the session scratchpad; models are in `~/ai/omni-bench-models/whisper/`. No production code
or configuration was changed.

---

## Addendum: real-time streaming, Nemotron and Qwen3 included [new]

Harness: an in-process Swift program on speech-swift (`a57702e6`) that loads each model once and plays each clip at 1× real
time, recording every text update with its wall-clock time (`streambench`, scratchpad; analysis in
`Tools/omni-eval/stream_events_report.py`, raw events in `results/rt-*-idle.jsonl`). 18 clips (6 each he/ru/en, 8–14 s),
M2 Pro, idle machine.

- **Nemotron 3.5 0.6B (Core ML INT8)** is a genuine cache-aware streaming model: 320 ms chunks, persistent encoder and decoder state.
- **Qwen3-1.7B 8-bit and Omni 300M** have no incremental state. They are driven by repeated offline decode of the audio so far
  with one worker (a pass starts when the previous one is done and 1.0 s of new audio has arrived).
- **Omni has no streaming mode in speech-swift.** Its docs call it "streaming-friendly in principle" and point streaming users
  to Parakeet/Nemotron. The `--stream` CLI flag is native only for Kyutai and VAD-based for Qwen3.

| Engine (mode) | 1st partial | 1st correct word | 1st committed word | Lag p50 | Final text after clip end | Flicker | WER he / ru / en (all) | Compute per update p50 / p95 |
|---|---|---|---|---|---|---|---|---|
| **Nemotron** (native streaming, language hint) | 1.7 s | 1.9 s | 2.2 s | **0.04 s** | **0.03 s** | **0%** | 41.4 / 14.8 / 23.2 (26.5) | 0.036 / 0.043 s per 320 ms chunk |
| Nemotron (native, auto language) | 1.8 s | 1.9 s | 2.3 s | 0.04 s | 0.03 s | 0% | 52.1 / 17.4 / 23.2 (30.9) | 0.036 / 0.043 s |
| Qwen3-1.7B 8-bit (repeated decode) | 1.6 s | 2.4 s | 3.5 s | 0.49 s | 1.07 s | 11% | 77.3 (no Hebrew) / **2.4** / **6.0** (28.6) | 0.48 / 0.91 s |
| Omni 300M, 10 s window (repeated decode) | 2.7 s | 4.0 s | 5.3 s | 1.15 s | 3.13 s | 14.5% | 52.2 / 26.9 / 18.0 (32.4) | 1.15 / 2.30 s |
| Omni 300M, 5 s window (repeated decode) | 2.1 s | 3.0 s | 4.2 s | 1.16 s | 2.19 s | 10.3% | 65.6 / 29.4 / 26.6 (40.5) | 1.16 / 1.75 s |
| Whisper Base, Core ML enc. (repeated decode, **earlier spawn-per-pass method, 2 s hop**) | 2.0 s | 3.3 s | 5.7 s | n/a | n/a | 19.7% | 66.7 / 24.4 / 8.5 (33.2) | 0.13 / 0.24 s |

WER here is on only 6 clips per language, so treat it as indicative; the 100-clip numbers in §3 are the accuracy reference.

- **The Omni cost is real, not CLI overhead.** In-process, with the model resident, a pass costs 1.15 s on this M2 Pro. The
  published ~120 ms per 10 s window (M3 Pro, model card/docs) was not reproduced **[unknown cause]**.
- **Only Nemotron behaves like a streaming engine**: text appears within 0.04 s of the audio it covers, never revises text
  already shown, and the final text is ready as the clip ends. The repeated-decode engines trail the speaker by 0.5 s (Qwen3)
  and 1.15 s (Omni) and need 1–3 s after the end to finalize.

### Memory over time (resident engines) [new]

| Engine | Warm footprint | Behaviour |
|---|---|---|
| Qwen3-1.7B 8-bit | 2.8 GB | rises to 3.8–4.2 GB in the first passes, then **flat** over 150 passes |
| Omni 300M, 10 s / 5 s | 207 / 133 MB | grows ~0.6 MB per pass (218 → 312 MB over 150 passes) and ~6 MB per streamed clip |
| Nemotron (speech-swift Core ML) | 108 MB | grows ~1.1 MB per second of audio in one session (≈ 30 MB per 30 s, 530 MB at 390 s) and ~2.4 MB/s across short sessions |

- **Nemotron aborted at ~400 s of continuous audio, reproduced twice**: a Core ML exception (`MLE5BindEmptyMemoryObjectToPort`)
  inside the RNN-T decoder prediction at ~550 MB footprint. This is the speech-swift Core ML runtime, not necessarily the NVIDIA model.
  Whisperer's own Nemotron path uses FluidAudio, which I did **not** test, so I can't say it shares the problem.
- Extrapolated to 180 minutes, growth at these rates is not survivable for Nemotron (via speech-swift) or tolerable for Omni.
  Qwen3 is the only one of the three that is stable.

### Language support

| Model | Published coverage [pub] | Hebrew | Russian | English | FLEURS WER measured here (100 clips) |
|---|---|---|---|---|---|
| Nemotron 3.5 ASR Streaming 0.6B | 40 language-locales: 19 transcription-ready, 13 broad, 8 adaptation-ready | **adaptation-ready** (he-IL, needs fine-tuning for full ASR) | ready (ru-RU) | ready (en-US/GB) | not run on 100 clips (6-clip streaming run only) |
| Qwen3-ASR 1.7B | 30 languages + 22 Chinese dialects | **not supported** | yes | yes | he 77.2 (unsupported), ru 6.4, en 4.1 |
| Omnilingual CTC 300M Core ML | 1,672 languages (CTC, no language hint) | listed | listed | listed | he 50.5, ru 30.6, en 17.5 (10 s window) |
| Whisper Base (multilingual) | 99 languages | yes | yes | yes | he 62.8, ru 23.7, en 9.9 |

Licenses: Nemotron 3.5: NVIDIA OpenMDW-1.1 ("ready for commercial use" on the model card); Qwen3-ASR: Apache-2.0; Omni: Apache-2.0;
Whisper: MIT.

### What this changes

- Omni 300M is **not** a streaming engine and is the slowest to finalize; it only wins on mixed-language and Hebrew accuracy.
- If a **true** low-latency preview is the goal, Nemotron is the only candidate that streams, with the open questions being
  Hebrew (adaptation-ready only, 41.4 WER on 6 clips with a language hint; Whisperer already carries a Hebrew fine-tune bridge)
  and runtime stability (leak/abort seen in speech-swift's Core ML path).
- Not done: concurrent run of Nemotron with Qwen3 final, FluidAudio-based Nemotron soak, energy.

### Addendum 2: Nemotron on the full sets [new]

Native streaming session, 320 ms chunks, final text scored with `score.py` (100 clips each, 40 mixed; run in batches of ≤8-20 clips because the speech-swift Core ML runtime aborts after ~400 s of audio per process).

| Nemotron 3.5 0.6B | he | ru | en | mixed (40) |
|---|---|---|---|---|
| language hint (he-IL / ru-RU / en-US) | 43.6 WER / 26.4 CER | 13.1 / 6.0 | 10.9 / 6.0 | – |
| auto language | 47.0 / 31.5 | – | – | 53.0 / 43.8 |

- The 6-clip Hebrew figure (41.4) held up on 100 clips (43.6). Hebrew is "adaptation-ready" in NVIDIA's card (tokenizer knows it,
  full ASR needs fine-tuning), so ~44% WER is weak-but-nonzero ability, not support.
- The mixed set has no language hint (the harness's hint map covers he/ru/en only), so both mixed runs are auto-language and identical.
  Of 40 mixed clips, 33 contain Hebrew, 21 Latin and 23 Cyrillic output.

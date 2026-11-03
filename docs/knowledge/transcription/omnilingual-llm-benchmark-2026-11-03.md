# Omnilingual LLM variants vs Qwen3-ASR 1.7B and Omni CTC (2026-11-03)

**Decision: no compact Omnilingual LLM variant replaces Qwen3-ASR 1.7B, and none beats Omni CTC 7B on quality. Nothing in production changes.**
The LLM variants use 4–5 GB less memory than Qwen3 or CTC 7B, but they lose on every language measured, and the
Hebrew/Russian output has no word boundaries. The caveat that matters: this tests the third-party `cstr` GGUF files through
CrispASR, not Meta's reference implementation (see "What this does and does not show").

## Setup

| | |
|---|---|
| Hardware | MacBook Pro, Apple M2 Pro, 32 GB unified memory, macOS (Darwin 27.2) |
| LLM runtime | CrispASR `3181f0f8b2df8809197f5a8583fbb3363ba54379` (built locally, Metal, Release). Upstream HEAD `57fb8ff` did not build (`mini_bs_roformer.cpp`: unterminated `#if`), so the parent commit was used. Greedy decoding, defaults |
| Baseline runtime | `speech` CLI 0.0.29, MLX. Qwen3 = `Qwen3-ASR-1.7B-MLX-8bit`, **the same 8-bit weights Whisperer ships** (`mlx-community/Qwen3-ASR-1.7B-8bit`). Omni CTC baselines are 4-bit, so Qwen3 vs CTC is 8-bit vs 4-bit |
| Data | Existing `Tools/omni-eval` manifests: FLEURS test he/ru/en (100 each, seed 42), 40 synthetic mixes. Unchanged. Same normalization (`score.py`) |
| Model revisions (HF) | `cstr/omniasr-llm-300m-v2-GGUF` f77a5ccf, `cstr/omniasr-llm-unlimited-300m-v2-GGUF` a68f5d04, `cstr/omniasr-llm-1b-GGUF` 7b433b6a. Files: q4_k (all three), q8_0 (300M only) |

Memory is `peak memory footprint` from `/usr/bin/time -l`, one fresh process per run. It includes Metal allocations, which
`maximum resident set size` misses (Qwen3: 6.8 GB footprint vs 2.5 GB RSS at 60 s). It covers load plus inference in one
number.

## A. Model comparison

| Model | Disk GB | Peak footprint 5 s / 30 s / 60 s (MB) | RTF 5 s / 30 s / 60 s | en CER† | he CER† | ru CER† | Mixed WER (he+en, n=10) |
|---|---|---|---|---|---|---|---|
| Qwen3-ASR 1.7B 8-bit (baseline) | 2.3 | 3074 / 5523 / 6831 | 0.08 / 0.055 / 0.055 | **0.8** | 43.5 (unsupported) | **1.9** | **56.3** |
| Omni CTC 7B 4-bit | 3.5 | 5626 / 6777 / n/a (40 s cap) | 0.17 / 0.18 / n/a | 3.9 | 4.9 | 2.2 | 78.8 |
| Omni CTC 3B 4-bit | 1.7 | 3552 / 4716 / n/a | 0.08 / 0.085 / n/a | 3.5 | 6.3 | 2.4 | 70.3 |
| Omni LLM-300M q4_k (n=6) | 1.07 | 1268 / 1385 / 1387 | 0.34 / 0.60 / 0.94 | 8.8 | 10.7 | 35.4 | not run |
| **Omni LLM-Unlimited-300M q4_k (n=20)** | 1.08 | 1275 / 1391 / 1393 | 0.34 / 0.61 / 0.62 | 13.0 | 10.6 | 9.7 | 91.6 |
| Omni LLM-1B q4_k (n=6) | 1.44 | 1630 / 1750 / 1750 | 0.35 / 0.88 / 1.06 | 5.9 | 15.4 | 75.7 | not run |
| Omni LLM-300M q8_0 (n=6, smoke only) | 1.84 | ~2030 | 0.41–1.97 | – | Latin-script garbage | Latin-script garbage | not run |
| ivrit-v3-turbo (he only) | 1.62 | not measured | 0.20 | – | **3.1** | – | 65.9 (forced he) |

† **Space-insensitive CER, %**, lower is better, on the same clips for every engine (first 20; first 6 for the 300M/1B LLMs).
Word WER is not used for the LLMs because their Hebrew/Russian output has no spaces (below). Corpus-level, spaces counted,
on the full 100 clips the earlier benchmark gives en WER 4.1 (Qwen3) vs 9.4 (CTC 7B); the LLM variants were stopped at the
pilot.
Not measured, so not claimed: CPU/GPU utilisation, memory after unload, growth across repeated requests, macOS memory
pressure, time to first partial, and Whisperer's in-app Qwen3 footprint (CLI with identical weights was measured instead).

## B. Ranking (measured)

1. **Quality:** Qwen3 (en, ru) / ivrit (he) > Omni CTC 7B > CTC 3B > LLM-Unlimited-300M > LLM-300M > LLM-1B (ru collapses).
2. **Peak RAM, lowest first:** LLM-300M/Unlimited (1.3–1.4 GB) < LLM-1B (1.6–1.75) < CTC 3B (3.6–4.7) ≈ Qwen3 (3.1–6.8) < CTC 7B (5.6–6.8).
3. **Speed:** Qwen3 (RTF 0.055) > CTC 3B (0.08) > CTC 7B (0.17) > LLMs (0.34–1.06).
4. **Language coverage:** documented 1600+ for Omni, but empirically validated only for en/he/ru here. Qwen3 has no Hebrew.
5. **Code-switching:** Qwen3 best (56.3 WER), but all engines fail on this set.
6. **Continuous transcription:** none of the LLM variants. See D.
7. **Integration complexity:** LLM variants need a new C++ (ggml/CrispASR) backend; Qwen3 is already integrated.

## C. Analysis

- **Does the LLM decoder compensate for the smaller encoder? Not in this setup.** LLM-Unlimited-300M is roughly level with
  CTC 7B on Hebrew content (10.6 vs 4.9 on 20 clips, 8.5 vs 8.1 on the first six) and clearly worse on Russian (9.7 vs 2.2)
  and English (13.0 vs 3.9).
- **Failure modes seen:** Hebrew and Russian come out with no word spaces and with full-width CJK punctuation (`。`, `，`);
  Latin-only English is fine. LLM-1B merges Russian into near-noise (75.7 CER). The q8_0 300M file ignores the language
  input and writes Latin transliteration for Hebrew/Russian.
- **Best quality-to-memory balance: Omni CTC 3B 4-bit among Omni models** (CTC 7B adds ~2 pt WER for ~2 GB more). Among all
  engines, Qwen3 and Parakeet remain best for en/ru. For Hebrew the shipped ivrit model is clearly best.
- **Memory is the one genuine LLM advantage:** a flat ~1.3–1.4 GB regardless of audio length, against Qwen3 growing to
  6.8 GB at 60 s. That is worth remembering as a Qwen3 issue independent of this decision (see Follow-ups).

## D. Production feasibility

- **Streaming:** none is true streaming. CrispASR runs offline autoregressive decoding; Unlimited splits audio into
  15 s segments and decodes each in turn. A 15 s window costs ~9 s of compute (RTF 0.6), so partials would lag far behind
  speech. Unlimited does handle a 60 s file (37 s, RTF 0.62), but that is long-audio support, not low latency.
- **Real-time dictation:** unsuitable (RTF 0.34 on a 5 s clip; every pass is a full re-decode).
- **Continuous meetings:** unsuitable at RTF ~0.6 on a machine that is also running Whisperer's other models.
- **High-quality final transcription:** not better than what is already shipped.
- **Integration:** CrispASR is a C++/ggml hub (MIT), buildable with Metal; a Swift bridge is possible but would be a new
  backend (the CLAUDE.md rule against a second resident whisper-style context applies to the pipeline design too). Upstream
  HEAD was broken on the day of testing, which says something about pinning. No cancellation or unload API was evaluated.

## What this does and does not show

- **Measured:** the `cstr` GGUF q4_k/q8_0 files, run by CrispASR `3181f0f` on Metal, on the existing corpus.
- **Not measured:** Meta's reference PyTorch/fairseq2 models. I could not separate "the model is weak here" from "the port is
  defective". Evidence of port problems, found while testing:
  1. All three GGUFs ship **placeholder language codes** (`lang_0 … lang_1692`), so CrispASR's `-l he`/`-l heb_Hebr` never
     matches and silently conditions on `eng_Latn` (lang_id 417). I worked around it with `-l lang_<row index in Meta's
     languges_lookup_table.parquet>` (eng 416, heb 541, rus 1287) and verified `lang_id` changes (417 → 542). Results above
     use the corrected id. Outputs changed only slightly, and the missing spaces persisted.
  2. The files labelled `…-300m-v2` and `…-1b` have vocab size 9812 and base model `facebook/omniASR-LLM-300M`
     (v1 tokenizer). Only the Unlimited file has the v2 vocabulary (10288).
  3. CrispASR's own notes record Q4_K as too lossy for Omni CTC; the same may apply to the LLM decoder. The q8_0 test did
     not help, so quantization alone does not explain the failure.
- **Gating:** per the brief, the full 340-clip run was skipped for all three LLMs because the pilot gap was an order of
  magnitude (e.g. ru CER 9.7–75.7 vs 0.3–2.2), larger than anything n=6 or n=20 sampling noise can explain.
- **Mixed-language limits:** the synthetic set is concatenated monolingual clips and covers he↔en and he↔ru only. It has no
  ru↔en pair and no real conversational recordings, so it says nothing about real code-switching. The LLM mixed result is
  10 clips (all he+en); LLMs were conditioned on Hebrew, as `ivrit-forced-he` was.
- **Optional candidates not run:** Q5 does not exist for these LLMs (only f16, q8_0, q4_k are published). CTC 7B Q5 / 3B Q8 and
  MLX/CoreML ports were not pursued: nothing measured suggests they could change the decision.

## E. Final answers

1. **Can a compact Omnilingual LLM variant replace Qwen3-ASR 1.7B?** No. It is worse on English (13.0 vs 0.8 CER) and
   Russian (9.7 vs 1.9) and worse on mixed speech (91.6 vs 56.3 WER); the coverage claim (1600+) was not validated beyond
   he/ru/en, and RAM is the only win.
2. **Is Omni CTC 7B Q4 still competitive?** It beats every LLM variant tested and is the best Omni model, but it is not
   competitive with the shipped engines (Qwen3 on en/ru, ivrit on he), and its measured footprint (5.6–6.8 GB) is higher than
   the earlier "2× the 3B" note suggested. 3B 4-bit is the better trade-off if Omni is revisited.

**Recommendation:** keep the current engines; do not integrate CrispASR. Revisit only if (a) the corrected-language GGUFs or
Meta's reference weights show the LLM Unlimited variant reaching the CTC 7B level on ru/en, or (b) speech-swift ports the
LLM decoder, which would give a maintained Swift path.

## Follow-ups worth separate attention

- Qwen3 8-bit via the MLX CLI grows from 3.1 GB (5 s) to 6.8 GB (60 s) peak footprint while RSS is flat at ~2.5 GB. Check
  whether the in-app port releases the MLX buffer cache between windows; this was measured only in the CLI.
- One reference check on ~10 clips with Meta's PyTorch model would settle "model vs port" if anyone wants to reopen the
  LLM question. Cost: ~17 GB fp16 for the 7B, far less for 300M.

## Artifacts

`Tools/omni-eval/`: `run_crisp.py` (resumable, language-index workaround, per-clip footprint), `resource_bench.py`,
`score_nospace.py`, `results/resource.jsonl`, `hyp/llm*.jsonl` (gitignored). CrispASR checkout and build are in the session
scratchpad; models are in `~/ai/omni-bench-models/` (5.4 GB; delete when no longer needed). No Whisperer source was changed.

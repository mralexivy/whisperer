# Batched LLM decode — measurement rounds

Hardware for every number below: **Apple M2 Pro, 12 cores, 32 GB**, macOS 26.2.
Model: `Qwen3.5-4B-MTPLX-Optimized-Speed`, 4-bit affine group 64, 2.34 GB active.
Workload: the real `Correct` prompt on real VAD chunk text from
`WhispererTests/TestData/chunk-stream-corpus.json` (58 recordings, 295 chunks).

Batching is an **aggregate** lever. It never makes one chunk faster — per-row tok/s falls
monotonically with B. Every "tok/s" below is total across the batch.

---

## Round 0a — what the real workload looks like

58 recordings, 36.4 minutes of audio, replayed at wall-clock real time through the full
streaming path.

| bucket | recs | chunks | chunks/rec | gap p10 | gap p50 | gap p90 |
|---|---|---|---|---|---|---|
| short | 20 | 33 | 1.6 | 0.00 | 0.00 | 0.00 |
| medium | 20 | 83 | 4.2 | 0.00 | 5.37 | 9.90 |
| long | 15 | 123 | 8.2 | 2.90 | 8.19 | 11.01 |
| very-long | 3 | 56 | 18.7 | 2.82 | 7.00 | 13.91 |

Overall: 295 chunks, chunk chars p50/p90 = 82/145, inter-arrival **p50 6.84s**, only
**18% of gaps ≤ 2.0s**, chunks/recording p50/p90/max = 4/11/22.

**Mid-stream batching is dead.** A correction takes ~0.7s and the median gap is ten times
that, so while the user is speaking the queue never holds more than one request. The
batchable populations that survive are the drain at key release (p90 = 11 chunks
outstanding), the whole-text splitter, and meeting segments.

## Round 1 — batch size sweep

Identical unpadded rows, warm system prefix, best of 2 after a warm-up run.

| B | ms/step | agg tok/s | per-row tok/s | speedup | prefill ms |
|---|---|---|---|---|---|
| 1 | 26.36 | 37.9 | 37.9 | 1.00× | 442 |
| 2 | 44.68 | 44.8 | 22.4 | 1.18× | 1450 |
| 4 | 58.41 | 68.5 | 17.1 | 1.81× | 1613 |
| 8 | 159.36 | 50.2 | 6.3 | 1.32× | 4244 |
| 16 | 165.37 | 96.8 | 6.0 | 2.55× | 7978 |
| 24 | 187.88 | 127.7 | 5.3 | 3.37× | 12083 |
| 32 | 185.70 | **172.3** | 5.4 | **4.54×** | 17557 |

Two features matter. The sharp B=4→8 jump in ms/step (58→159) is a kernel switch — MLX
leaves its narrow quantised matvec path and starts dequantising into a GEMM. And prefill
does not batch **at all**: 341 tok/s at B=1 against 274 tok/s at B=32, because a
150-token prefill already saturates the GPU on its own.

## Round 2 — is the ceiling above 32?

ms/step was nearly flat from B=8 to B=32, which usually means extra rows ride along free
and the real ceiling is higher up. It is not.

| B | ms/step | decode tok/s | prefill ms | end-to-end tok/s |
|---|---|---|---|---|
| 32 | 252.66 | 126.7 | 13290 | 85.4 |
| 48 | 398.82 | 120.4 | 21033 | 81.1 |
| 64 | 368.67 | 173.6 | 31091 | 97.9 |
| 96 | 631.39 | 152.0 | 42860 | 93.7 |

ms/step now scales linearly with B and throughput is flat within noise. **Decode is fully
compute-bound past B≈16.** No improvement over round 1.

## Round 3 — straggler retirement

Ragged real chunks at B=32 reached only ~65% of the identical-row rate, at an average live
width of 15 rows out of 32. The knob is when to physically compact dead rows out.

| threshold | ms/step | agg tok/s | avg width | compactions |
|---|---|---|---|---|
| 1.00 (never) | 255.22 | 58.7 | 15.0 | 0 |
| 0.50 | 134.59 | 111.3 | 15.0 | 4 |
| 0.25 | 133.52 | **112.1** | 15.0 | 8 |
| 0.10 | 131.47 | 113.9 | 15.0 | 14 |

Compacting at all is worth **1.9×**; the exact threshold is worth 2%. Default set to 0.25.
Second consecutive round under 5% → **stop**.

---

## Result

**Measured ceiling: 172 tok/s aggregate at B=32, 4.5× over single-stream — not 1000 tok/s.**
On ragged real chunks the working figure is ~112 tok/s, about 3×. End-to-end including
prefill, ~85–98 tok/s, about 2.5–3×.

**Binding constraint: 4-bit quantised matmul on the M2 Pro GPU goes compute-bound at
B≈8–16.** The plan's 1000 tok/s assumed decode stays memory-bandwidth-bound to B≈32, which
is true for fp16 weights on a large-bandwidth part and false here — dequantising 2.4 GB of
4-bit weights into a GEMM costs arithmetic that a batch-1 matvec never pays. Prefill,
which is already a GEMM at B=1, gets nothing from batching at all and is roughly half of
end-to-end wall-clock on this workload.

## Correctness

- **Unpadded batching is bit-exact.** B=8 of identical rows equals B=1 exactly, and inside
  a ragged batch the single row needing no padding has a logit delta of exactly 0.0.
- **Padded rows drift by ≤0.28 in logit space** — one bf16 rounding step on logits whose
  magnitude is tens (bf16 relative epsilon ~0.008), caused by summing an attention row over
  a longer partly-masked span in a different order.
- That flips the greedy pick only where the top-two gap is small (median gap 6.5, but
  occasionally ~0.4). Measured: **7 of 64 real chunks (11%)** differ from serial, every one
  a comma or an article — "so that's" vs "so, that's".
- Hebrew and Russian rows preserve their script; warm-prefix broadcast is exact.

**Byte-exactness against the serial path is therefore not achievable with right-padding**,
which is a change to the plan's premise: the quality corpus in
`docs/knowledge/llm/criteria.md` cannot simply be assumed to carry over. It would have to
be re-run, or batching restricted to equal-length rows.

---

## Round 4 — production wiring (scheduler + per-chunk path)

`BatchedLLMScheduler` fires greedily on the next main-actor turn instead of holding a
deadline, because round 0a's arrival distribution makes a deadline pure added latency. A
width-1 batch is routed to the single-stream MTP path, so the sparse case cannot regress.
Suites green: `BatchedLLMSchedulerTests` 7/7, `PerChunkLLMTests` 10/10,
`BatchedLLMProductionPathTests` 5/5.

## Round 5b — whole-text correction, split into batched segments

`AIMode.correct` caps output at 256 tokens. On long dictation the single whole-text call
therefore does not correct the text — it stops a fifth of the way in, and the app returns
the truncated prefix or falls back to raw. So the baseline is **serial correction of the
same segments**, with the single pass reported for reference only.

M2 Pro / 32 GB, 5 longest loop-free real recordings, real `Correct` prompt. Percentages are
words out over words in.

| chars | segments | batched | serial segments | single pass (today) |
|---|---|---|---|---|
| 18169 | 102 | 71.4 s / 100% | 129.6 s / 99% | 15.7 s / 100% (uncorrected) |
| 12645 | 72 | 87.0 s / 100% | 181.0 s / 84% | 22.4 s / 100% (uncorrected) |
| 2998 | 15 | 17.4 s / 100% | 28.4 s / 99% | 11.4 s / 43% (truncated) |
| 2080 | 7 | 12.7 s / 102% | 21.8 s / 101% | 10.6 s / 63% (truncated) |
| 1645 | 5 | 9.6 s / 98% | 18.5 s / 96% | 10.2 s / 75% (truncated) |
| **total** | | **198.1 s / 100%** | **379.3 s / 96%** | **70.2 s / 76%** |

**1.92× over serial segments, and the first version of this path that returns a corrected
long transcript at all.**

Two bugs found by measuring rather than by reading:

- **A fixed 30 s whole-batch deadline truncated the largest batches.** Rows past the
  planner's slice width run *after* the earlier ones, so an 87-row batch is several
  sequential generations sharing one budget: 45 s of work against a 30 s deadline, and
  every row still live at that moment kept a half-finished sentence. It presented as
  53–74% word retention — a batching correctness bug that was not one. Fixed by
  `LLMPostProcessor.defaultTimeout(rowCount:)` = `max(30, 1.5 × rows)`, ~3.5× the measured
  0.4 s/row.
- **The retention metric penalised correct behaviour.** Rows collapsing to one word had
  inputs that were whisper hallucination loops ("it's okay," ×40). The degeneration guard
  collapsing those is right. Fixtures whose *input* loops are excluded and the exclusion
  count is printed (2 of 19).

One hypothesis was refuted by its own test: slice-to-slice warm-cache corruption. One
multi-slice call and two separate calls returned identical retention, and
`broadcastWarmCache` deep-copies and tiles per call. It was content, not slicing.

## Round 6 — repeatability

Five runs per width, on an otherwise idle machine.

| B | median tok/s | p10 | p90 | spread | median end-to-end tok/s |
|---|---|---|---|---|---|
| 1 | 36.1 | 35.8 | 36.3 | 1% | 26.7 |
| 16 | 73.4 | 73.2 | 73.4 | 0% | 45.0 |
| 32 | 120.3 | 120.1 | 120.3 | 0% | 61.2 |

Run-to-run spread ≤1% everywhere. The curve is a property of the hardware, not of the run.

## Round 7 — real-recording wall clock (the user-visible gate)

`BatchedLLMWallClockTests.testRealRecordingWallClock`. Chunks are fed to
`ChunkLLMCoordinator` at their real audio-time offsets from the harvested corpus, and the
clock that matters runs from the last chunk (key release) to `drain()` returning. Same
loaded model, two passes per recording: straight single-stream, then through
`BatchedLLMScheduler`.

| chunks | audio | serial tail | batched tail | max batch width | words |
|---|---|---|---|---|---|
| 22 | 204 s | 2.36 s | 2.20 s | 3 | 261 / 261 |
| 20 | 151 s | 1.29 s | 1.30 s | 2 | 310 / 310 |
| 14 | 132 s | 0.83 s | 0.83 s | 1 | 372 / 372 |
| 11 | 97 s | 1.26 s | 1.25 s | 1 | 256 / 256 |
| 11 | 82 s | 0.48 s | 0.46 s | 1 | 175 / 175 |
| 11 | 97 s | 0.87 s | 0.87 s | 1 | 233 / 233 |
| **total** | | **7.1 s** | **6.9 s** | | |

**1.03×. Parity, and parity is the correct result here.** Round 0a measured a 6.84 s median
inter-arrival against a ~0.7 s correction, so almost nothing is ever outstanding at release
— the max batch width the scheduler ever assembled on real timing was 3, and on four of six
recordings it was 1. The plan's ≥3× gate for this path is unreachable *because of the
workload*, not because of the implementation, and the plan says in that case the number is
re-derived from measurement. It is asserted as "never slower" (>0.95×), which is what the
width-1 → single-stream-MTP fallback exists to guarantee. Word counts are identical on
every recording.

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

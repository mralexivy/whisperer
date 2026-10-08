# Hebrew via LoRA — execution plan

Goal: add Hebrew to Qwen3-ASR-1.7B with **zero regression** on the other 30 languages, shipping a
single Apache-2.0 `model.safetensors` and requiring **no Swift changes**.

Replaces the Caspi merge approach, which capped at λ=0.2 (see
`docs/knowledge/transcription/knowledge.md`). Caspi is CC-BY-NC-4.0 and cannot ship; the
ivrit-ai datasets it trained on *can* (CC-BY-4.0 restricted to AI training — model weights are
an allowed derivative).

---

## Why this can't repeat the merge failure

The delta map measured during the merge work showed Caspi's changes were concentrated almost
entirely in the audio tower — the top-25 relative deltas were all `audio_tower.*`, peaking at
0.525 on `proj2`, while `model.embed_tokens` moved only 0.166 (rank 140 of 707).

The layer-split experiments then separated the two jobs:

| Configuration | English | Hebrew | Russian |
|---|---|---|---|
| Caspi audio tower + base decoder | clean | **romanized** | broken |
| Caspi audio tower + λ=0.3 decoder | clean | correct script | Hebrew-letter translit |

"Romanized Hebrew" is the key observation: with a tower that hears Hebrew and a decoder that
doesn't know the script, you get Hebrew words in Latin letters. **Script selection is a decoder
job.** So:

- LoRA on the decoder only, audio tower frozen and untouched → the acoustic path for Russian and
  English is bit-identical to base. The failure mode that killed every merge is unreachable.
- Train only on sequences carrying the `language Hebrew` tokens → the learned delta is
  conditioned on Hebrew being in context.
- Mix in English/Russian rehearsal data → explicit gradient pressure for the adapter to be a
  no-op elsewhere.

---

## What the Caspi model card tells us

Read 2026-10-04. Four things, two of which change this plan.

**1. Its multilingual claim is provably false — and that is the strongest argument for Gate 1.**
The card's support table lists all 31 languages, Russian included. We empirically destroyed
Russian with Caspi's weights and watched forced-English still emit Hebrew. They published a
multilingual claim they evidently never tested. Treat "the card says it still works" as worth
nothing; the byte-identical check in Gate 1 is what separates this effort from theirs.

**2. No recipe is disclosed** — no learning rate, epochs, data hours, or full-FT-vs-LoRA. We know
from the delta map it was a full fine-tune (all 707 tensors moved). Nothing here is copyable.

**3. Caspi's audio-tower delta is the main evidence against decoder-only.** If Hebrew needed a 52 %
change to `proj2`, freezing the tower may cap our ceiling hard. The counter-argument: a full
fine-tune has no pressure to leave the tower alone, so a large delta doesn't prove a large delta
was *necessary*. Unresolved — Phase 0.3 is the arbiter, and tower LoRA is now a planned branch
rather than a footnote.

**4. It gives us public benchmarks and a published baseline.** `ivrit-ai/eval-d1`,
`ivrit-ai/eval-whatsapp` and `imvladikon/hebrew_speech_kan` all exist on the Hub, with Caspi's
numbers to compare against (4.2 / 6.0 / 7.1 %, avg 4.96 % — beating `ivrit-ai` Whisper-v3 at
5.6 %). Gate 3 now uses these instead of a self-made split.

---

## The inference contract (training must match this exactly)

From [Qwen3ASREngine.swift](../../Whisperer/Transcription/Qwen3ASR/Qwen3ASREngine.swift):

```
prompt = promptPrefix ++ audio_embeddings ++ promptSuffix [++ forcedLanguageTokens ++ <asr_text>]

promptPrefix = [151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669]
               <|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>
promptSuffix = [151670, 151645, 198, 151644, 77091, 198]
               <|audio_end|><|im_end|>\n<|im_start|>assistant\n
<asr_text>   = 151704
eos          = {151643, 151645}
```

Verified against the checkpoint vocab: `11528` = `language`, `36266` = `ĠHebrew`
(cf. `6364` = `ĠEnglish`, `8522` = `ĠRussian`). Hebrew is a clean single token, same shape as the
30 supported languages.

**Unforced** (`languageCode == nil`): model generates `language Hebrew` `<asr_text>` `body` `<eos>`.
The `language X` header is what drives the two-pass ratchet in `Qwen3ASRBridge`.

**Forced** (`languageCode == "he"`): header is supplied in the prompt; model generates only `body`.

A single training target covers both, because a causal LM doesn't distinguish prompt tokens from
previously-generated ones:

```
input_ids = [prefix] [audio placeholders] [suffix] [11528, 36266, 151704] [body…] [eos]
labels    = [-100 …………………………………………………………………] [11528, 36266, 151704] [body…] [eos]
```

Supervising the header teaches detection (unforced path); supervising the body teaches
transcription (forced path).

---

## Phase 0 — Pre-flight (local, free, ~1 h) — **GO/NO-GO**

Decides whether decoder-only is viable before spending a cent.

**0.1 Restore the clean base.** The live model dir currently holds the λ=0.2 Caspi merge
(`_whisperer_merge: "global-0.2"` in `config.json`). Back it up, then verify what you're testing:

```bash
LIVE=~/Documents/huggingface/models/mlx-community/Qwen3-ASR-1.7B-8bit
cp $LIVE/model.safetensors ~/Documents/huggingface/_merge/m_g0.2_backup.safetensors
python3 -c "import json;print(json.load(open('$LIVE/config.json')).get('_whisperer_merge'))"
```

**0.2 Accept the dataset terms.** Both ivrit-ai datasets are `extra_gated_fields` — click through
on the HF page while signed in, then `huggingface-cli login`. Downloads 401 until you do.

**0.3 Does the base hear Hebrew?** Run clean base (`~/Documents/huggingface/_merge/base/`) over
~20 Hebrew clips with `he` forced. Read the output:

| Output | Meaning | Action |
|---|---|---|
| Romanized / phonetically plausible Latin | Tower hears Hebrew, decoder lacks the script | **Decoder-only LoRA. Proceed as planned.** |
| Correct Hebrew, mediocre quality | Better than expected | Decoder-only, fewer steps needed |
| Unrelated words or noise | Tower does not encode Hebrew phonetics | Add `r=4` audio-tower LoRA; keep rehearsal data |

**0.4 Baseline numbers.** WER on held-out EN / RU / HE with the clean base. Without this you
cannot later prove "no damage" — you'll only have opinions.

---

## Phase 1 — Data (~3 h, mostly unattended)

**Source.** `ivrit-ai/crowd-transcribe-v5` — 203,827 train clips, ~20 GB. **Stream it**
(`load_dataset(..., streaming=True)`); do not download the whole archive.

Filters, using the dataset's own `extra_data` struct:

```python
keep = (not x["extra_data"]["noisy"]
        and not x["extra_data"]["foreign_language"]
        and not x["extra_data"]["multiple_speakers"]
        and not x["extra_data"]["unintelligible"]
        and not x["extra_data"]["skipped"]
        and not x["extra_data"]["too_long"]
        and 3.0 <= x["extra_data"]["duration"] <= 25.0)
```

Use the `sentence` field (human-corrected), **not** `orig_sentence` (raw ASR output — training on
it would distill Whisper's mistakes).

**Budget — two rounds, not one.** `crowd-transcribe-v5` holds 203,827 train clips; at ~103 KB/clip
that is roughly **200–350 h**, and Caspi consumed that plus `crowd-recital`. An earlier draft of
this plan proposed 30 h, which is ~10 % of what the reference model used. Revised:

| Round | Hebrew | Purpose |
|---|---|---|
| **Pilot** | 30 h | Validate the pipeline end-to-end and run every gate. Cheap to throw away. |
| **Full** | 100–150 h | Only after the pilot clears Gates 1–4. Quality run. |

LoRA needs less data than a full fine-tune because it isn't relearning the model — but Hebrew is
absent from `support_languages`, so this is closer to teaching a new language than refining an
existing one. Don't assume the pilot's quality is the ceiling, and don't assume 30 h is enough.

Add `ivrit-ai/crowd-recital-whisper-training` for the full round — read speech, cleaner but less
conversational.

**Rehearsal.** ~10 h (pilot) / ~35 h (full) from Common Voice `en` + `ru` (CC-0), same duration
filter, labelled with their own language tokens. Target mix ≈ **75 % he / 15 % en / 10 % ru**.

**Held-out eval.** 300 clips each for en/ru, frozen before training and never trained on. Hebrew
uses the public sets in Gate 3 — do not build a private Hebrew split, it destroys comparability.

---

## Phase 2 — Train (A100 40 GB, ~4–6 h, ~$20)

```
transformers==4.57.6   # Qwen3ASRForConditionalGeneration lands here
peft datasets soundfile librosa accelerate
```

**Gate 2.1 — prompt parity (do this first, it's the cheapest way to lose a day).** Build a prompt
with the official `Qwen3ASRProcessor`, tokenize, and assert the ids match the Swift constants:

```python
assert ids[:9]  == [151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669]
assert suffix   == [151670, 151645, 198, 151644, 77091, 198]
assert tok.convert_tokens_to_ids("<asr_text>") == 151704
```

If these diverge, the adapter trains against a prompt the app never sends and will appear to do
nothing at inference.

**LoRA config:**

```python
LoraConfig(
    r=16, lora_alpha=16, lora_dropout=0.05, bias="none",
    target_modules=[  # decoder attention only
        "q_proj", "k_proj", "v_proj", "o_proj",
    ],
    layers_to_transform=None,
)
```

Then explicitly exclude the tower — PEFT's suffix matching will otherwise catch attention
projections inside `audio_tower` too:

```python
for n, p in model.named_parameters():
    if "audio_tower" in n:
        p.requires_grad = False
assert not any(p.requires_grad for n, p in model.named_parameters() if "audio_tower" in n)
```

This assert is load-bearing — it is the thing that makes regression structurally impossible.

**Hyperparameters:** 2–3 epochs, lr 1e-4 cosine with 3 % warmup, effective batch 16
(per-device 4 × grad-accum 4), bf16, `group_by_length=True`. Loss masked to `-100` over prompt and
audio positions.

**Checkpoint every 500 steps** and keep them — Gate 3.2 may send you back to an earlier one.

---

## Phase 3 — Export to MLX 8-bit (~45 min)

1. `merge_and_unload()` → bf16 HF checkpoint.
2. Convert to the mlx-community layout. Two transforms, both already solved in
   `~/Documents/huggingface/_merge/build_merge.py`:
   - strip the `thinker.` prefix
   - transpose `audio_tower.conv2d{1,2,3}.weight` NCHW → NHWC
3. Quantize **exactly the tensors the existing base quantizes** — use the current
   `model.safetensors` key list as the oracle (a `foo.scales` sibling means quantize;
   `group_size=64, bits=8`). The audio tower stays bf16. `Qwen3ASRMLXModel.load` keys off
   `.scales` presence, so a mismatch here silently loads garbage.
4. Stamp `config.json` with `_whisperer_merge: "he-lora-r16-<date>"`.

Memory: keep the streaming pattern (`mx.load` mmaps, arrays are lazy, `mx.eval` and release one
tensor at a time). The eager version held ~21 GB and froze the machine.

---

## Phase 4 — Verification

Ordered so the cheap gates fail first. Every gate is pass/fail, not vibes.

### Gate 1 — adapter is a no-op on non-Hebrew *(bf16, pre-quantization)*

The strongest check available, and nearly free. Run the same EN and RU clips through base and
through base+adapter, greedy, forced language:

- **Output strings must be byte-identical.** Not "similar" — identical.
- Any divergence: report the count and inspect max logit drift before continuing.

A handful of differing clips out of 300 is tolerable if WER is unchanged; systematic divergence
means the conditioning didn't take and you should drop `r` or raise the rehearsal fraction.

### Gate 2 — WER regression, EN/RU

Held-out sets vs the Phase 0.4 baseline. **Pass: within ±0.5 % absolute.** Anything worse is a
real regression regardless of how good Hebrew looks.

### Gate 3 — Hebrew gain, on public benchmarks

Use the sets Caspi published against, so the numbers mean something:
`ivrit-ai/eval-d1`, `ivrit-ai/eval-whatsapp`, `imvladikon/hebrew_speech_kan`.

| Reference | eval-d1 | eval-whatsapp | kan | avg | Role |
|---|---:|---:|---:|---:|---|
| Clean base | ? | ? | ? | ? | Measure in Phase 0.4. Must beat decisively |
| λ=0.2 merge (current ship) | ? | ? | ? | ? | Must beat, or keep what's installed |
| **Caspi** (published) | 4.2 % | 6.0 % | 7.1 % | **4.96 %** | Upper bound — full FT on ~10× the data |

Realistic expectation: the pilot will not approach 4.96 %. Caspi is a full fine-tune of every
tensor on several hundred hours; this is a rank-16 decoder adapter on 30. The bar that actually
matters is **beating the λ=0.2 merge by enough to justify shipping**, with Gates 1, 2 and 4 clean.

**Fix the normalization policy before measuring** — the card explicitly warns that comparisons
are meaningless otherwise. Decide once, apply to every model in the table: niqqud stripping,
final-form letter folding, punctuation, digit handling. Decoding is **greedy** (that is what
[Qwen3ASREngine](../../Whisperer/Transcription/Qwen3ASR/Qwen3ASREngine.swift#L159) does via
`argMax`); never compare against a beam-search number.

### Gate 4 — short-window language ratchet — **the one that caught λ=0.9**

The mistake that cost the most time last round: a 6 s English clip was perfect at λ=0.9 while
sub-second prefixes detected `he` and pinned Hebrew for the whole dictation.

Cut each eval clip to prefixes of **0.35 / 0.7 / 1.5 / 3.5 s**, run with `languageCode = nil`
(auto), and record the `language X` header:

- English prefixes → `en`; Russian prefixes → `ru`. **Pass: ≥ 98 % at every window length.**
- Simulate the two-pass ratchet: any two consecutive passes agreeing on `he` for non-Hebrew audio
  is a hard fail.

### Gate 5 — re-verify after quantization

**Do not skip.** The adapter delta is small and 8-bit quantization is lossy — it can round the
delta away (Hebrew gain disappears) or inject noise that reintroduces drift. Re-run **Gate 2 and
Gate 4** against the final MLX 8-bit file. Results from the bf16 checkpoint do not transfer.

### Gate 6 — in-app smoke

Install, dictate EN / RU / HE for real. Watch `~/Library/Logs/Whisperer/` for per-pass detected
language. Confirm no HUD stalls and no `stuck-*.dump`.

**Rollback:** `cp ~/Documents/huggingface/_merge/m_g0.2_backup.safetensors $LIVE/model.safetensors`

---

## Budget

| Phase | Wall time | Cost |
|---|---|---|
| 0 — pre-flight | 1 h | $0 |
| 1 — data | 3 h (unattended) | $0 |
| 2 — training | 4–6 h | ~$20 |
| 3 — export | 45 min | $0 |
| 4 — verification | 2 h | ~$2 |

**~$25, one working day.**

---

## Open risks

1. **Base tower may not encode Hebrew phonetics — now the leading risk.** Hebrew is absent from
   `support_languages`, and Caspi needed a 52 % change to `audio_tower.proj2` to get there. That
   is suggestive, not conclusive (a full FT rewrites the tower whether or not it needs to), but
   it moves tower LoRA from fallback to **likely branch**. Phase 0.3 settles it before any spend.
   If taken: `r=4` on the tower, rehearsal data unchanged, and Gate 1 becomes mandatory rather
   than reassuring — a trained tower *can* regress other languages, so byte-identical output is
   no longer guaranteed by construction and must be measured.
2. **`Seq2SeqTrainer` may not accept `Qwen3ASRForConditionalGeneration`** — it's a custom
   architecture with no `library_name` tag. Fallback is a manual training loop (~50 lines); the
   model's `forward` already takes `input_features` + `labels`.
3. **Quantization eating the delta** — Gate 5 catches it. If it fires, the fix is raising `r`
   (larger delta survives rounding) rather than skipping quantization.

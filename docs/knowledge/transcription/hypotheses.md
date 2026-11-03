# Transcription hypotheses

- **Omnilingual LLM-ASR (7B) might match ivrit-v3-turbo on Hebrew.** (Partly tested 2026-11-03: the 300M/1B GGUFs do not, see `omnilingual-llm-benchmark-2026-11-03.md`; 7B LLM still untested.) The paper's Hebrew CER for LLM-7B is 6.7 (eval set not named); ivrit-v3-turbo measured 6.7 CER on FLEURS-he here and CTC-7B 9.1, so at best a tie, and the LLM variant is ~17 GB at fp16. Cannot test until speech-swift ports the LLM module. Needs: one run on `Tools/omni-eval` manifests.
- **Omni CTC at 3B handles Hebrew-only dictation acceptably but not mixed-script windows.** Seen on 40 synthetic mixes (2026-11-03); needs real mixed-language dictation clips to confirm, since the synthetic switches are sentence-level.

- **The Omni LLM failure on he/ru is the CrispASR/GGUF port, not the model.** Space-less output, CJK punctuation and ignored language ids are port-shaped symptoms; unconfirmed without a run of Meta's reference PyTorch model on ~10 clips.

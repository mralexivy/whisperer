# Privacy Shield — hypotheses (need more data)

- Adding a non-Whisper CTC model (wav2vec2) to the training ensemble improves transfer to Parakeet-style
  and cloud recognisers. Test: evaluate main-run checkpoints with Parakeet/Apple Speech as held-out ASR.
- A per-band masking penalty (δ ≥ 10 dB under speech per mel band) keeps intelligibility acceptable at
  ≥ 30% drift. Test: STOI/ESTOI and a listening check on the final checkpoint.
- Speech-shaped scaling of a fixed pattern does not beat a flat pattern at equal loudness (one white-box
  sanity run). Needs a fair, longer comparison.

# Privacy Shield — rules (apply by default)

1. Measure after a conferencing path. A perturbation that only works on the raw signal is not a privacy
   feature; the bench's "call" column is the one that matters.
2. Train with the real codec and denoiser in the loop (straight-through gradient). Without it the effect
   does not survive Opus/RNNoise.
3. Never evaluate on a model or voice used in training.
4. Dither every signal entering a differentiable ASR front-end and never take abs() of a complex STFT:
   exact-zero stretches give 0/0 gradients (NaN) on MPS.
5. Ship only what is measured: evaluate through the native C++ path (`--processor native:`), and keep
   the native/PyTorch parity test green.
6. Fail closed: without the trained network the shield refuses to start rather than run the baseline.
7. Never claim "blocks transcription". Claim "makes transcription much harder" with measured numbers.

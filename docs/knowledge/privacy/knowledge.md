# Privacy Shield — knowledge (facts and measurements)

- Bench: `Tools/privacy-shield/eval/run_eval.py`. "Drift" = WER of the shielded transcript against the clean
  transcript in the same condition; the "call" condition is Opus VoIP 24 kbps then RNNoise (arnndn,
  GregorR somnolent-hogwash model). Eval ASR: whisper.cpp large-v3-turbo-q5_0, never trained against.
- AM + noise baseline (strength 0.35, SNR 17.7 dB): drift 0.0% direct and after the call. ASR ignores
  non-adversarial noise, and conferencing noise suppression removes it anyway (2026-11-07).
- Universal looped perturbation (one 1 s buffer): ε 0.03 → 1.6% drift; ε 0.1 → 21.7% drift but 0.4 dB SNR
  (as loud as the voice). It does transfer to an unseen Whisper and survives Opus + RNNoise (2026-11-07).
- Predictive causal network (pnet.py, 747k params): pilot of 200 steps on 200 synthetic clips gave 11.9%
  drift after the call at 6.2 dB SNR, key facts 69% (clean 89%). Effect was larger after the call than
  direct (1.7%) because training sees the call path (2026-11-07).
- Native C++ network equals the PyTorch reference to 3e-8 including resampling; median 0.062 ms, p99
  0.095 ms per 10 ms block on M2 Pro; clean under ASan/UBSan.
- Off the Record (Weird Machines) terms forbid reverse engineering, model inspection and using its output
  to develop or evaluate models. Clean-room only.

## Identity protection (voice reshaping + learned signal) — 2026-11-07

- **Approach.** Reshape the voice with a causal two-tap delay-line pitch/formant shifter (ratio 1.15;
  `reshape.py`, native in `ShieldPNet`), then add the learned perturbation on top. The ratio travels in
  the WSPN header (`reshape`), so one weights file selects it; native == `reshape.py` to 6e-8.
- **Why.** Speaker-identity and transcription are different representations (VoicePrivacy, AntiFake). A
  quiet additive signal alone leaves speakers recognisable; reshaping is what moves the formants ASV keys on.
- **Eval.** `speaker_eval.py`: 24 held-out LibriSpeech dev-clean speakers; one clean enrollment + one test
  utterance per speaker, both through the call proxy (Opus 24k + RNNoise). ECAPA (trained against) and
  WavLM-SV (held out). "still_you" = fraction accepted at the clean-pair equal-error-rate threshold.
- **Result (step 800 combined, after call):** ECAPA still_you 0.0 (clean 1.0), WavLM still_you 0.0
  (clean 1.0, never trained), mean sim ECAPA 0.25 vs clean 0.73 (threshold 0.44). Words survive:
  WER vs clean 3.5%. Reshape alone: ECAPA 0.083, WavLM 0.0, WER 2.3%. The learned signal on top of
  reshape closes ECAPA from 8% to 0%.
- **Claim this supports:** "AI can't identify or clone your voice; your words stay clear." NOT
  "AI can't transcribe you."
- `--keep-words` + `--identity-weight` (ECAPA embedding pushed off the clean voice) in `train_pnet.py`;
  `--reshape` applies the shifter first and the net perturbs the reshaped voice; `--ahead 1` lets the
  10 ms block see itself (no added latency, our audio path is block-based anyway).

## Anti-transcription efficacy ceiling (honest finding) — 2026-11-07

- At an inaudible loudness (~5–6 dB or quieter under the voice) the transcription-resistance generator
  changes only ~2–7% of words on held-out ASR after the call; meaningful jamming needs an audible signal.
  Modern ASR is highly noise-robust: plain noise as loud as the voice changes ~4% of words on whisper V3.
- Train only on OPEN surrogate ASR (open Whisper small/medium, wav2vec2); hold out the app's own model
  (turbo) and Parakeet for honest evaluation. Never target a specific commercial endpoint.

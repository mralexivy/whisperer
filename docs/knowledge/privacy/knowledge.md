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

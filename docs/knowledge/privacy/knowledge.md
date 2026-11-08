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
- **Dedicated jammer run (`pnet-jam`, 600 steps, finished 2026-11-07 22:43).** Held-out eval after the
  call, whisper turbo: words changed 10.9% / 17.8% / 16.5% at steps 200 / 400 / 600; key facts still
  recoverable 72% / 67% / 67%. Perturbation sits only ~5 dB under the voice (clearly audible). More
  training past step 400 did not help. Even an audible learned signal leaves two-thirds of the facts
  readable, so do not market this as anti-transcription. Identity protection is the shippable claim.

## Transcription jammer: local time reversal — 2026-11-08

- **What works.** Play the voice in ~70 ms frames, each time-reversed (frame length randomised +-20%,
  3 ms power-complementary crossfades). Native: `ShieldJammer.hpp`, parity with
  `transform_processor.revfade` (< 1e-5, any block size). Fixed delay ~87 ms. Runs after the identity
  network (`PrivacyAudioProcessor`, `jamTranscription:`), setting `privacyShieldJamTranscription`.
- **Measured (shipped chain, native path, after Opus 24 kbps + RNNoise, `jam_eval.py`).** Real speech,
  24 held-out LibriSpeech speakers, content-word recall clean -> jammed: whisper turbo 97% -> 12.5%,
  Parakeet 99% -> 13%, Qwen3-ASR 98.5% -> 9%. TTS corpus key facts: 89% -> 3% / 86% -> 8% / 94% -> 8%.
  Author's own 31 s recording: whisper output is fluent nonsense; Parakeet changes 56% of words.
- **What the reversal needs.** Sharp in-frame reversal: Hann 50%-overlap reversal (`revola`) at the
  same frame length barely hurts ASR (5-26% words changed), and the same frame grid with no reversal
  (`gridfade`, `splice`) changes 0-11%. Reversing only one band (above/below 1-2 kHz) changes 10-20%.
- **Frame length is the dial.** Words changed on the author's voice (whisper): 50 ms 21%, 60 ms 49-54%,
  70 ms 82-92%, 85 ms 66% (Parakeet keeps rising: 50% / 61% / 71%). Human intelligibility of locally
  reversed speech also falls with frame length (literature: near-perfect <= ~50 ms, falling through
  ~60-130 ms); the listener check decides the shipped value.
- **What failed (all after the call, whisper turbo held out).** Competing talker / babble under the
  voice: 2-26% words changed even at equal level. Noise-vocoding at 12 bands 4% (6 bands 28%, poorly
  intelligible). Periodic noise interruption 2-3%. Frequency shift 60 Hz 0%. Learned continuous signal
  (UAP, predictive net, jammer net): <= 22% even at voice level. Learned mute burst before speech
  (`train_burst.py`): learns without the codec (p(EOT) 0 -> 12% in 60 steps) but only to ~4% through Opus.
- **Live, in the app (2026-11-08).** Clips played through the speakers -> physical mic -> shield (identity
  + jammer) -> Whisperer Virtual Mic, recorded through Core Audio: after the call proxy whisper turbo kept
  2.8% of key facts (physical mic transcript: all of them). `live_test.py` now records through the HAL
  (PortAudio); ffmpeg's AVFoundation capture received only ~30% of the virtual mic's buffers (6.0 s of
  samples in 20 s; a 1 kHz tone arrived at the right pitch, so buffers were dropped, not resampled),
  which made earlier live runs look like silence.

## Listener verdict and the naturalness frontier — 2026-11-08

- **Listener check (author).** The shipped chain and every reversal setting (60-85 ms, any crossfade,
  with or without identity reshaping) sound robotic; the original and the identity shield alone sound
  natural. The jammer is therefore opt-in and off by default, and its copy says it sounds robotic.
- **Machine listener (`listener.py`, torchaudio SQUIM).** Estimated STOI reproduces the verdict: natural
  0.97-0.99, robotic 0.56-0.62. Mild reversal 30-50 ms scores 0.53-0.57: every local reversal is robotic.
- **Frontier (STOI vs whisper turbo words changed after the call, TTS corpus).** Everything with STOI >= 0.9
  changes <= 2% (frequency shift 0.99/0%, quiet UAP 0.97/2%). The most damaging candidates sit far below:
  learned jammer net 0.85/16.5%, competing talker at voice level 0.82/26%, UAP at voice level 0.70/22%,
  6-band vocoder 0.58/28%, reversal jammer 0.63/90%. No tested method is both natural and disruptive.
- **Hybrid (learned signal over 45 ms reversal, small+medium, codec in the loop):** mute loss flat at ~8.4
  for 200 steps; stopped. Mild reversal alone (real speech): content words kept 88% / 82% / 76% at
  40 / 45 / 50 ms.

## Competitor mechanism (static analysis supplied by user, 2026-11-08)

- A competitor desktop app ("Test App 1.13") uses the SAME virtual-mic route we do (Core Audio
  AudioServerPlugIn + hidden feed, libASPL, ~20-80 ms bounded ring). It does NOT deny mic access; a call
  app choosing the physical mic bypasses it. Its own Terms call the effect best-effort and say some
  systems may still transcribe — so the honest product target is "natural voice, transcription harder,"
  not guaranteed blocking.
- Its disruption is a MODEL-ASSISTED, TIME-VARYING SPECTRAL transform at 16 kHz, 400-sample periodic Hann,
  160 hop, 201 bins, overlap-add normalised by sum of squared windows:
  `Y[m,k] = (1 + g[m,k]) * X[m,k] * exp(i*phi[m,k])`. A per-frame gain field and phase field, produced by
  an MLX model path (plus a seeded RNG and an encrypted 2-layer GRU audio profile whose runtime role was
  not established). Bounds/clamps on g and phi were not identified in the static dump.
- Takeaway for us: the win over our earlier time-domain added-signal (UAP/pnet) is the PHASE term. The ear
  is insensitive to absolute phase, but a recogniser recomputes magnitude on its own STFT grid, so a
  time-varying phase field becomes magnitude error downstream while staying natural. A fixed g(f)/phi(f)
  is just EQ+all-pass (ASR-robust); the field must change frame-to-frame. `train_spectral.py` learns this.
- Probe (random smooth phase/gain, no training): STOI 0.98-0.99 at |phi| up to 6 rad / |g| 6 dB, but 0%
  words changed — confirms random is natural-but-useless; the field must be ADVERSARIALLY TRAINED.

## Spectral (phase+gain) jammer: trained result — 2026-11-08

- Trained a time-varying spectral field `Y=(1+g)Xe^{iphi}` (`train_spectral.py`, 24-frame loop, bound 4 dB
  / 2 rad) adversarially against Whisper small+medium with Opus+RNNoise in the loop. true_ce stayed flat
  at 0.13-0.16 across 120 steps while |phi| grew to 1.41 rad: no disruptive direction found.
- Held-out eval (real speech, 16 LibriSpeech speakers, after the call proxy): content words kept
  whisper turbo 97% -> 96.4%, Parakeet 99.3% -> 99%. STOI 0.99, PESQ 3.45 (identical to clean) on the
  author's voice. => perfectly natural, ~0% effect. The competitor's own mechanism, measured on our
  bench, lands in the natural-but-useless corner, which is why their Terms say best-effort.
- Why phase does not survive: 2.5x overlap-add (400-win / 160-hop) averages adjacent frames' phase
  rotations back out during reconstruction, and the recogniser's magnitude front-end is robust to the
  rest. Result is consistent with the random-field probe (STOI 0.98, 0% changed).
- **Three independent mechanisms now hit one wall** (time-domain learned signal, local time reversal,
  spectral phase+gain): on this bench every output that a listener/SQUIM calls natural (STOI >= 0.9)
  changes <= ~3% of words after a codec on held-out recognisers; only robotic outputs (STOI ~0.6) disrupt.
  No tested method delivers natural voice + reliable transcription blocking. The robotic reversal jammer
  remains the only working disruptor and ships opt-in/off by default.

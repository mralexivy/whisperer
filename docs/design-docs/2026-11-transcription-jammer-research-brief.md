# Deep research brief: a real-time, on-device "transcription jammer" for macOS

## Your role and what I need back

You are a research engineer reviewing a design before we build it. Below is our current direction,
what we have measured so far, and what we believe is the winning approach. Your job is to:

1. **Challenge it.** Find where the published evidence contradicts it, where it is naive, and where
   a better-supported alternative exists. Say plainly when we are wrong.
2. **Improve it.** Replace guesses (marked *[guess]*) with values backed by literature or credible
   open-source implementations.
3. **Fill the gaps.** Add whatever a team needs to implement and ship it that this brief leaves out.

**End result:** one complete, implementation-ready guide (structure in the final section). Every
non-obvious claim must carry a citation (paper, repo, or official documentation) and a confidence
level. Prefer work from 2022 onward. Where sources disagree, show both and recommend one.

## Product

A macOS menu-bar app that sits between the user's real microphone and any app that records it
(Zoom, Meet, Teams, browser, AI notetakers). It publishes a **virtual microphone**, a Core Audio
HAL plug-in. With protection on, it adds an adversarial perturbation to the user's live voice so that:

- **people on the call still understand the user naturally**, and
- **automatic speech recognition (ASR) produces badly wrong transcripts**: Whisper (all sizes,
  including whisper.cpp large-v3 / turbo), NVIDIA Parakeet / Conformer-CTC, wav2vec2-style CTC
  models, Apple Speech, and cloud ASR used by meeting notetakers.

A secondary goal is resisting **speaker identification and voice cloning** from the same audio.

**Hard constraints**
- Runs fully on device on Apple Silicon (M1 base model upward), in real time.
  - Added latency of ≤ 40 ms *[guess]*.
  - Real-time factor ≤ 0.3 on an M1.
  - Must not compete for the GPU with an on-device whisper.cpp (Metal) running in the same app, so we
    want the network on the **Apple Neural Engine via Core ML**, with a CPU (Accelerate) fallback.
- It must work **after a real conferencing path**: loudspeaker/room, Opus at 16–32 kb/s, WebRTC
  noise suppression / AGC / echo cancellation, RNNoise-style denoisers, packet-loss concealment.
- **Clean-room:** use only public research and our own measurements. A competing product exists
  (described below at product level only). **Do not use, seek, describe or speculate about its
  internals, code, models or output.**

## What the market already claims (product level only)

A shipping macOS competitor advertises: "reshapes your voice so AI can't transcribe it… people hear
you, AI gets nothing". Its fine print says it "makes AI transcription much harder, but can't promise
to stop it every time". It offers **three user-selectable protection levels**, from "most natural
sound" to "most protection; processing easiest to hear". It runs on device, removes speaker echo
using a system-audio reference, and installs a virtual microphone. Treat this only as evidence that
the product category is viable. Assume nothing about how it works.

## Our current design (the direction we think is winning)

**Core idea:** a small **causal predictive perturbation network**. Every 10 ms it predicts a
perturbation for the *next* block from the *past* audio, and adds it to the voice under a
**per-band loudness ceiling tied to the voice's own spectrum**. It is trained with
**Expectation over Transformation** across the call path, against an **ensemble of differentiable
ASR models**, and evaluated only on held-out ASR models and speakers.

Primary references we are building on (verify, extend, or replace):
- Chiquier, Mao & Vondrick, *Real-Time Neural Voice Camouflage*, ICLR 2022 (predictive attacks)
- Schönherr et al., *Adversarial Attacks Against ASR Systems via Psychoacoustic Hiding*, NDSS 2019
- Qin et al., *Imperceptible, Robust, and Targeted Adversarial Examples for ASR*, ICML 2019
- Athalye et al., *Synthesizing Robust Adversarial Examples* (EOT), ICML 2018
- Universal adversarial perturbations for audio (Neekhara et al. 2019 and successors)

**Signal path (per 10 ms block at 48 kHz)**
```
mic → AEC (WebRTC AEC3, reference = Core Audio process tap of system output; bypass on headphones)
    → 16 kHz decimate → STFT (25 ms window / 10 ms hop) → 64-band log-mel → voice envelope E(f,t)
    → causal network (0–3 frames look-ahead) → z ∈ (−1,1) via tanh
    → bound: δ = z · B_level(f) · E(f,t)            (per-band multiplier table per level)
    → randomisation (per-session seed) → iSTFT / overlap-add → 48 kHz
    → y = x + δ → speech-gated AutoGain (peak ceiling −1 dBFS) → virtual mic
```

**Network (current and target)**
- **Current prototype:** conv front end over the past 25 ms (400 samples at 16 kHz, 64 channels) →
  LayerNorm → 2-layer GRU (hidden 64) → linear head emitting 160 waveform samples → tanh.
  747k parameters. Runs in plain C++ at a median 0.062 ms and p99 0.095 ms per 10 ms block on an
  M2 Pro. It matches the PyTorch reference to within 3e-8.
- **Target:** 30–80k parameters *[guess]*, possibly 4 causal dilated conv blocks (width 64,
  kernel 3, dilations 1-2-4-8) for clean Core ML / ANE conversion, distilled from the larger model.

**Levels** *[guess, needs evidence]*

| Level | Ceiling below the voice, 300–3400 Hz / outside | Look-ahead |
|---|---|---|
| 1 (default, natural) | −14 dB / −10 dB | 0 |
| 2 | −10 dB / −7 dB | 1 frame |
| 3 (maximum) | −6 dB / −4 dB | 2 frames |

One network is trained with the bound as a differentiable stage, sampling the level per batch.

**Training**
- **Data:** consented speech, split by speaker. LibriSpeech, Common Voice and FLEURS in English,
  Hebrew and Russian, plus our own recordings.
- **White-box ensemble:** Whisper tiny, base and small; wav2vec2-base CTC; one Conformer-CTC.
- **Held out for evaluation only:** whisper.cpp large-v3 and turbo, Parakeet, Apple Speech, one
  cloud ASR.
- **Loss:**
  - untargeted: maximise the ensemble's CTC / seq2seq loss on the true transcript
  - plus a penalty on band energy above the bound
  - plus a multi-resolution STFT distance between output and input
  - plus total variation on z
- **EOT, sampled per batch:**
  - room impulse responses and loudspeaker band-limit
  - Opus at 16–32 kb/s, with a straight-through gradient
  - RNNoise plus a WebRTC NS/AGC stand-in
  - ±6 dB gain, ±2-sample clock drift, packet-loss concealment
- **Optimiser:** AdamW, lr 3e-4 with cosine decay, 20–50k steps, fixed-length buckets (for the MPS
  backend).
- **Lessons already learned:**
  - dither all signals entering a differentiable ASR front end
  - never take `abs()` of a complex STFT (0/0 gradients give NaN on MPS)
  - select checkpoints on held-out drift **after the call path**, not on training loss

## What we have measured so far

"Drift" is the WER of the shielded transcript against the clean transcript in the same condition.
The "call" condition is Opus at 24 kb/s followed by RNNoise. The evaluation ASR is whisper.cpp
large-v3-turbo-q5_0, never trained against.

| Approach | Loudness | Drift, direct | Drift, after call |
|---|---|---|---|
| Amplitude modulation + noise | SNR 17.7 dB | 0.0 % | 0.0 % |
| Universal looped perturbation, ε = 0.03 | quiet | 1.6 % | — |
| Universal looped perturbation, ε = 0.1 | SNR 0.4 dB (as loud as the voice) | — | 21.7 %, transfers to unseen Whisper and survives Opus + RNNoise |
| Predictive causal net, pilot (200 steps, 200 synthetic clips) | SNR 6.2 dB | 1.7 % | **11.9 %** (key facts kept: 69 % vs 89 % clean) |

**What we conclude:**
- non-adversarial noise does nothing
- fixed universal patterns only work at unacceptable loudness
- training through the call path is essential: the effect was larger after the call than direct
- the predictive network is the most promising direction, but the pilot is far from a usable level

**Our tentative ship gate:**
- median after-call drift ≥ 30 % on held-out ASR
- ESTOI ≥ 0.85 at level 1
- listener MOS "sounds natural" ≥ 4.0 at level 1
- RTF ≤ 0.3 on an M1
- no unprotected blocks in a 60-minute soak (except an explicitly marked overload fallback)

**Product copy rule:** claim only measured numbers ("makes transcription much harder"), never
"AI can't transcribe you".

## Questions to research, challenge and answer

**A. Is this the right attack family?**
1. Compare our approach with every serious alternative for *real-time, over-the-air, model-agnostic*
   ASR disruption:
   - predictive / streaming attacks
   - universal perturbations (including speech-shaped and psychoacoustically masked ones)
   - generator-based black-box attacks
   - time-frequency masking attacks
   - voice-conversion / anonymisation approaches (VoicePrivacy Challenge systems)
   - "speech jamming" and audio-cloaking work (2022–2026)

   Which has the best published **transfer to unseen ASR** and **survival over codecs and noise
   suppression** at a quality people accept? Is a perturbation-only approach fundamentally capped,
   given that strong ASR models are robust to noise?
2. How well do attacks optimised on Whisper-small and wav2vec2 transfer to **Whisper large-v3**,
   Parakeet, and cloud ASR? Which ensemble members or surrogates give the most transfer per unit of
   compute? Is there evidence that Whisper's encoder is a better surrogate than CTC models, or the
   reverse?
3. What do robustness studies say about **defences** a notetaker could apply: denoising,
   resampling, adversarial purification with diffusion, input transformation, or retraining on
   perturbed audio? How quickly would our approach be neutralised, and what design choices extend
   its lifetime (randomisation, per-user or per-session variation)?

**B. Perception and the loudness bound**

4. What is the best-supported perceptual constraint for this use: a psychoacoustic masking
   threshold (MPEG-style), per-mel-band ratio to speech, or a learned perceptual loss? Give concrete
   numbers: dB below speech per band at which listeners stop noticing, and at which intelligibility
   (ESTOI/STOI) starts to drop.
5. Replace our level table with evidence-based values, or a method to calibrate it.
6. Which objective metrics best predict listener acceptance for added perturbations (PESQ, ViSQOL,
   DNSMOS, NISQA, ESTOI)? What listening-test protocol is credible (MUSHRA, ITU-T P.808)?

**C. Robustness over the real call path**

7. Which transformations must be in the EOT loop to survive Zoom, Meet and Teams? Cover their codecs
   (Opus variants, SILK/CELT modes), their ML noise suppression (e.g. Krisp-like, NVIDIA Broadcast,
   built-in Zoom and Teams suppression), AGC, echo cancellation, and bandwidth limits. Are there
   differentiable or well-approximated versions? How should non-differentiable stages be handled
   (straight-through, BPDA, learned proxy)?
8. Does the perturbation survive the **speaker → room → mic** path when the *other* participant
   records locally? Does it matter for our threat model?

**D. Speaker identity and cloning**

9. Does an ASR-targeted perturbation also degrade speaker-verification embeddings (ECAPA-TDNN,
   WavLM-SV, Resemblyzer) and zero-shot voice cloning (XTTS-class, VALL-E-class)? Or is a separate
   objective needed? Cite anti-cloning work (e.g. AntiFake, VoiceGuard, SafeEar) and its measured
   robustness.

**E. Architecture and on-device runtime**

10. The smallest architecture with published evidence of real-time predictive perturbation: GRU vs
    causal dilated conv vs a small causal transformer. What is the right look-ahead and context
    length? What parameter count is realistic for effective attacks?
11. **Core ML / Apple Neural Engine specifics:**
    - which ops and shapes stay on the ANE
    - stateful models (`MLState`, macOS 15+) vs an explicit context cache
    - fp16 accuracy impact
    - per-call latency for 10 ms blocks
    - batching several blocks to amortise ANE dispatch overhead
    - how to verify ANE residency (Instruments, `MLComputePlan`)

    Is a 10 ms call cadence on the ANE viable, or must it be 20–40 ms chunks?
12. Real-time audio engineering on macOS:
    - HAL plug-in virtual mic (libASPL / AudioServerPlugIn)
    - process taps for the echo reference (`AudioHardwareCreateProcessTap`, macOS 14.4+)
    - lock-free rings, clock drift between devices, overload handling without dropouts
    - bypass behaviour when no app is recording

**F. Training recipe**

13. A concrete, reproducible recipe: datasets and licences (including Hebrew and Russian), clip
    lengths, how to pick ensemble members, loss weights, learning-rate schedule, steps, compute
    estimate on one Apple Silicon Mac vs one cloud GPU, and early-stopping metrics.
14. Untargeted vs targeted objectives, and attacking the encoder representation vs the decoder loss.
    For Whisper specifically, which works best: decoder cross-entropy, encoder feature distortion,
    or forcing language/no-speech tokens? Is there published work on attacking Whisper's
    language-ID or no-speech head as a cheap, transferable lever?

**G. Evaluation, claims and law**

15. A rigorous evaluation protocol: held-out speakers, held-out ASR (including cloud), languages,
    conditions (direct, after call, over the air), metrics (WER drift, key-fact survival, ESTOI,
    MOS, speaker-verification EER), and statistical reporting.
16. What can be honestly claimed in marketing, given the measured results? What do consumer
    protection norms (FTC, EU) require for privacy-effect claims?
17. Legal and ethical review: jamming recording or transcription in the US, EU and Israel;
    wiretap or consent law interplay; App Store vs direct distribution; misuse risk; responsible
    disclosure to ASR vendors.

## Required output: the implementation guide

Produce a single guide with these sections. Use tables and concrete numbers. Mark every
recommendation with a confidence level (high / medium / low) and its sources.

1. **Executive verdict:** is our direction the best bet? What would you change first, and what
   ceiling should we realistically expect (drift at acceptable quality, after the call)?
2. **Threat model and claims:** what the product can and cannot promise.
3. **Recommended approach:** the attack family and objective, with a justification against the
   alternatives.
4. **Signal chain:** an exact per-block pipeline, with sample rates, window and hop, look-ahead,
   latency budget, and the order of AEC, perturbation and AGC.
5. **Model architecture:** layer by layer, with parameter count, receptive field, and Core ML / ANE
   conversion notes.
6. **Perceptual bound and protection levels:** the method and calibrated starting values.
7. **Training recipe:** data, ensemble, losses and weights, EOT transform list with parameters,
   schedule, compute, and checkpoint selection.
8. **Robustness plan:** codecs, noise suppression, over-the-air conditions, and defences, with the
   expected lifetime of the approach.
9. **Speaker identity and cloning:** a combined or separate objective, and its metrics.
10. **On-device runtime:** Core ML / ANE, CPU fallback, threading, overload behaviour, power and
    thermal budget.
11. **macOS audio integration:** virtual mic, process tap, echo cancellation, device and clock
    handling, permissions.
12. **Evaluation protocol and ship gates:** with thresholds.
13. **Milestone plan:** ordered steps, each with an exit criterion and the risk it retires.
14. **Risks, open questions and kill criteria:** when to stop pursuing anti-transcription and pivot
    to identity-only protection.
15. **Annotated bibliography:** each source in one line, saying what it contributes.

Explicitly list every place where you **disagree with our current design** and why. Also list every
*[guess]* above, replaced by your recommended value and its source.

# Voice-Privacy App — Proposed Implementation

**Document type:** Proposed implementation / design specification
**Product (working title):** *Voice Privacy* — a macOS voice-reshaping privacy utility
**Status:** Proposal — not yet built; all identifiers, keys, hosts and UUIDs below are **placeholders** to be assigned during implementation.

---

## Table of contents
1. [Concept](#1-concept)
2. [Design assumptions](#2-design-assumptions)
3. [Proposed bundle layout](#3-proposed-bundle-layout)
4. [App identity & metadata](#4-app-identity--metadata)
5. [Security & integrity design](#5-security--integrity-design)
6. [Permissions & privacy posture](#6-permissions--privacy-posture)
7. [Architecture overview](#7-architecture-overview)
8. [Proposed component map](#8-proposed-component-map)
9. [The voice-protection engine](#9-the-voice-protection-engine)
10. [Machine-learning models](#10-machine-learning-models)
11. [The virtual audio driver](#11-the-virtual-audio-driver)
12. [The Bluetooth "stick" hardware](#12-the-bluetooth-stick-hardware)
13. [Stick firmware image format](#13-stick-firmware-image-format)
14. [Onboarding UI & native bridge](#14-onboarding-ui--native-bridge)
15. [Licensing, billing & device auth](#15-licensing-billing--device-auth)
16. [Auto-update](#16-auto-update)
17. [Telemetry](#17-telemetry)
18. [Third-party software bill of materials](#18-third-party-software-bill-of-materials)
19. [Network endpoints](#19-network-endpoints)
20. [Open design questions](#20-open-design-questions)
21. [Build & validation plan](#21-build--validation-plan)
22. [Proposed configuration reference](#22-proposed-configuration-reference)

---

## 1. Concept

A macOS **menu-bar privacy utility** that sits between the microphone and any app that records
from it, and **reshapes the user's voice on-device** so that a human still understands them, but
**AI voice-recognition / cloning systems cannot identify or clone the speaker**.

The proposed product is composed of several subsystems:

- A **real-time audio pipeline**: capture → **echo cancellation** → **neural voice reshaping on the GPU (MLX/Metal)** → output as a **virtual microphone** (a dedicated CoreAudio driver).
- An optional **"Voice Check"** feature: an on-device CoreML classifier that labels a voice as **human / AI / not speech**.
- A companion **Bluetooth hardware "stick"** (an **ESP32-class** device) that carries phone calls to/from the Mac, has a physical protect button, and whose **firmware the app flashes over USB or BLE**.
- A **subscription / team-licensing system** with device-bound challenge-response auth, Keychain-stored tokens, and an offline grace period.
- A **WebKit onboarding wizard**, **signed auto-updates**, and **opt-in anonymous telemetry**.

**Protection posture goal:** strong *distribution & licensing integrity* (Developer-ID signing,
hardened runtime, signed updates, server-verified entitlements, integrity-checked firmware), with
no requirement for anti-reverse-engineering obfuscation.

---

## 2. Design assumptions

| Area | Assumption |
|---|---|
| Target platform | macOS 15.0+, Apple Silicon (arm64) |
| Language / UI | Swift + SwiftUI / AppKit, menu-bar agent (no Dock icon) |
| On-device ML | MLX + Metal for the reshaper; CoreML for classification |
| Audio stack | CoreAudio HAL plug-in for the virtual mic; system-audio tap for the echo reference |
| Distribution | Direct download (Developer ID + notarization), not the App Store |
| Hardware | Optional ESP32-class BLE/USB accessory with updatable firmware |
| Monetization | Freemium + paid team seats, browser checkout, server-issued entitlements |

---

## 3. Proposed bundle layout

```
VoicePrivacy.app/Contents
├── Info.plist                         app metadata (§4)
├── MacOS/VoicePrivacy                 main executable — Swift, arm64
├── _CodeSignature/CodeResources       sealed resource hashes
├── Frameworks/
│   └── Sparkle.framework              auto-update framework + sandboxed Updater.app
└── Resources/
    ├── AppIcon.icns
    ├── Credits.rtf                    third-party licenses (§18)
    ├── lock.mp3                       "lock" sound effect
    ├── install-driver.sh              privileged driver (un)installer
    ├── VoicePrivacyAudio.driver/      virtual-microphone CoreAudio HAL plug-in (§11)
    ├── VoiceCheck.mlmodelc/           CoreML human/AI/not-speech classifier (§10)
    ├── audio-model.dat                voice-reshaping model weights, packed/encrypted (§10)
    ├── mlx_backend.bundle/            MLX GPU backend + Metal shader library (§10)
    ├── stick-firmware.bin             ESP32 firmware image for the stick (§13)
    ├── accessory.usdz                 3-D model of the stick (SceneKit, shown in pairing)
    └── Onboarding/                    WebKit onboarding wizard (index.html/js/css + assets) (§14)
```

---

## 4. App identity & metadata

| Field | Proposed value (placeholder) |
|---|---|
| Display / bundle name | Voice Privacy |
| Bundle identifier | `com.example.voiceprivacy` |
| Short version / build | 1.0 / 1 |
| Category | Productivity |
| Minimum macOS | 15.0 |
| UI type | Menu-bar agent — `LSUIElement = true` |
| Custom URL scheme | `voiceprivacy://` — for team invitation links |
| Architecture | arm64 (Apple Silicon) |

> Companion bundle identifiers (placeholders): accessory `com.example.voiceprivacy.accessory`,
> driver `com.example.voiceprivacy.driver`, billing `com.example.voiceprivacy.billing`
> (+ a `.billing.preview` staging variant).

---

## 5. Security & integrity design

Protections should target **software-distribution integrity and paid licensing**, not obfuscation.

### 5.1 Code signing & runtime hardening
- Ship under a **Developer ID Application** certificate; notarize for Gatekeeper.
- Enable the **Hardened Runtime**.
- Hash the Code Directory with **SHA-256**.
- Author a **Designated Requirement** that pins both the bundle ID **and** the signing team OU, e.g.:
  ```
  identifier "com.example.voiceprivacy" and anchor apple generic
    and certificate 1[field.1.2.840.113635.100.6.2.6]       /* Developer ID CA */
    and certificate leaf[field.1.2.840.113635.100.6.1.13]   /* Developer ID leaf */
    and certificate leaf[subject.OU] = <TEAM_ID>
  ```
- Do **not** ship `get-task-allow` in the release build (no trivial debugger attach).

### 5.2 Signed auto-updates
- Use **Sparkle** with an HTTPS appcast feed.
- Require a **signed feed** (`SURequireSignedFeed = true`) and **verify before extraction** (`SUVerifyUpdateBeforeExtraction = true`).
- Sign the appcast with **EdDSA (Ed25519)**; embed only the public key (`SUPublicEDKey`).
- Disable system profiling on update checks (`SUEnableSystemProfiling = false`); schedule hourly checks.

### 5.3 Device-bound licensing
- Implement a **challenge-response device auth**: fields such as `deviceToken`, `sessionToken`, `deviceNonce`, `macNonce`, `challenge`, `offeredKey`.
- Store secrets in the **Keychain** (dedicated service, e.g. `voiceprivacy.billing-keychain`).
- Use **CryptoKit** for key-pair signing, **Security** for Keychain, and optionally **LocalAuthentication** for biometric gating.
- Server issues a signed entitlement ("access certificate"); the client verifies it before unlocking paid features. (See §15.)

### 5.4 Firmware integrity
- Ship the stick firmware with a **per-region checksum** (e.g. MD5) manifest and verify each region before/after flashing. (See §13.)

> **Anti-reversing:** not required. The build can be a normal stripped release Swift binary with no
> packer or string obfuscation; integrity and trust are enforced by signing + server verification.

---

## 6. Permissions & privacy posture

**Entitlement:** request only `com.apple.security.device.audio-input` (microphone). Keep the
security surface minimal.

**Usage-description strings** to declare in Info.plist:
- **Microphone** — explain that the app republishes the user's voice as a virtual microphone and, when the "lock" is on, reshapes it locally.
- **Audio capture (system audio)** — explain it listens to what the Mac plays only to remove echo before protection, and (if Voice Check is on) to classify voices; **nothing is recorded or sent anywhere**.
- **Bluetooth** — explain it connects to the paired stick only after pairing.

**TCC / behavior:**
- Use the system-audio-capture service (`TCCServiceAudioCapture`) for the echo reference.
- Include a `RecordingWatcher` that detects when another app is actively recording from the mic, to activate protection.

**Privacy stance:** all audio processing is **on-device**; telemetry is opt-in and excludes
audio/content/identity (§17).

---

## 7. Architecture overview

```
                 ┌──────────────────────── Voice Privacy (menu-bar app · Swift / SwiftUI) ──────────────────────────┐
  Real mic  ─────┼─▶ InputTap ─┐                                                                                     │
                 │             │                                                                                     │
  System audio ──┼─▶ SystemAudioTap ─▶ Echo cancel ─▶ ProtectEngine ─▶ MLX/Metal + audio-model.dat ─▶ reshaped voice ┼─▶ virtual mic
  (what Mac      │   (echo reference)   (AEC)          (orchestration)   (neural voice reshaping on GPU)             │   (CoreAudio driver)
   plays)        │                                                                                                   │        │
                 │   VoiceCheckController ─▶ VoiceCheck.mlmodelc (CoreML): human / AI / not-speech                   │        ▼
                 │   AccessoryManager ─ CoreBluetooth / USB ─▶ companion "stick" (ESP32)  (Opus audio, calls)        │   Zoom / Meet / Teams …
                 │   OnboardingWindow (WebKit)  ·  BillingModel (CryptoKit + Keychain)  ·  Updater (Sparkle)          │
                 └───────────────────────────────────────────────────────────────────────────────────────────────┘
       install-driver.sh → copies the driver to /Library/Audio/Plug-Ins/HAL/ as root, restarts coreaudiod
```

### System frameworks the design relies on
| Framework(s) | Role |
|---|---|
| CoreAudio · AudioToolbox · AVFAudio · AVFoundation | Audio capture/playback, driver glue, taps |
| *(embedded WebRTC AEC3)* | Acoustic echo cancellation |
| CoreML · Metal · Accelerate · *(embedded MLX)* | On-device ML: classifier + neural reshaper |
| CoreBluetooth · IOKit | Pairing/communication with the stick; USB access for flashing |
| CryptoKit · Security · LocalAuthentication | Licensing crypto, Keychain, optional biometrics |
| WebKit | Onboarding wizard |
| ServiceManagement | Privileged driver install + launch-at-login |
| SceneKit · ModelIO | Render the 3-D stick model during pairing |
| SwiftUI · AppKit · Combine · Observation | Menu-bar UI, popover, settings |

---

## 8. Proposed component map

Suggested Swift types, grouped by subsystem:

**App shell / UI**
- `AppDelegate`, `Router`, `SettingsWindow`, `SettingsNav`, `AppSettings`
- `MenuBarIcon`, `MenuAnchor.Box`, `PopoverPanel`, `WidgetModel`, `GlassView`, `GaugeView`, `WaveStream`, `LeanMotion`, `ActionItem`, `LockSound`, `HiddenIconNotice`

**Audio & protection engine**
- `InputTap`, `SystemAudioTap` — microphone & system-audio capture
- `ProtectEngine`, `LiveProtection`, `StreamProtector` — the reshaping pipeline (limiting via WebRTC AGC2; see §9)
- `EngineBridge`, `BlockProcessor`, `ComputePipeline`, `MachineLearningPipeline`, `PullModel`, `VoiceModel` — ML orchestration
- `RecordingWatcher` — detects when another app is recording from the mic

**Voice Check**
- `VoiceCheck`, `VoiceCheckController`, `VoiceCheckLiveView`, `VoiceCheckWindow`, `VoiceCheckFeed`, `ToggleVoiceCheck`

**Accessory (the stick)**
- `AccessoryManager`, `AccessorySession`, `DeviceWatcher`, `NearbyStick`
- `AccessoryBLE`, `AccessoryBLEPairing`, `AccessoryUSB` — BLE + USB transports
- `AccessoryAudio`, `AccessoryOpus` — audio to/from the stick, Opus-encoded
- `StickScreen`, `StickModel`, `StickModelView`, `AccessoryWindow`, `BluetoothStickLinkSheet`
- `StickFlasher` (ROM-port) — flashes firmware via the ESP32 ROM bootloader over USB

**Platform services**
- `BillingModel`, `Terms`, `UsageStats`, `Updater`, `OnboardingWindow`, `OnboardingDragArea`

---

## 9. The voice-protection engine

Proposed real-time path:
1. **Capture** — `InputTap` takes the real microphone; `SystemAudioTap` captures what the Mac plays (the echo reference).
2. **Echo cancellation** — **WebRTC AEC3** (§18) removes the other party's voice that the mic picks up from the speakers *before* protection.
3. **Reshaping** — `ProtectEngine` runs a **neural model on the GPU via MLX + Metal** (with Accelerate on CPU). Model weights ship as **`audio-model.dat`** (§10). Processing is block-based (`BlockProcessor`, `ComputePipeline`). Expose a **strength setting**.
4. **Output** — the reshaped stream is published as the **virtual microphone** (§11) that conferencing apps select as input.
5. **Lock UX** — a "lock" metaphor toggles protection (`PressLock`, `LockSound`/`lock.mp3`, an animated shackle in the popover and onboarding).

`LiveProtection` is the live-session controller. For clipping/overdrive in the processed signal, use the
WebRTC gain controller's limiter (`AutoGain` / AGC2); `SaturationProtector` is a WebRTC AGC2 internal
(`webrtc::SaturationProtector`), not a component of the reshaper. The earlier draft listed it as one.

### 9.1 Reference: how Off the Record 1.13 works (static findings, 2026-11-07)

> **Provenance and caveat.** Findings come from the shipped bundle in `~/Downloads/myapptest`:
> *Off the Record* 1.13 (build 15), bundle ID `ai.weirdmachine.offtherecord`, Developer ID
> *Breakpoint Technologies LTD (V855XU94CX)*, signed 18 Oct 2026. The sources were REA
> (`inspect-desktop-application`, `analyze-javascript-application` on the onboarding,
> `inspect-byte-entropy`), `Info.plist`, `install-driver.sh`, and the executable's strings and Swift
> reflection metadata (class and field names, in declaration order).
> **Nothing was executed, disassembled or decrypted, and no weights were read.**
> Off the Record's terms of use forbid reverse engineering, model inspection, and using its output to
> develop or evaluate models (`docs/knowledge/privacy/knowledge.md` on
> `feature/privacy-shield-adversarial`). This section describes *what* the product does, for
> positioning. §9.2 is written from public research and our own measurements, and must not depend on
> anything here beyond product-level behaviour.
>
> Tags: **[observed]** read directly from the bundle · **[inferred]** reasoned from observed names
> and sizes · **[unknown]** not determinable statically.

#### 9.1.1 Does it prevent Whisper / AI transcription?

- **It claims to: yes, with a hedge.** [observed]
  - Feature line in the app: *"Reshapes your voice so AI can't transcribe it."*
  - Onboarding headline: *"People hear you. AI gets nothing."*
  - Microphone permission text: *"…so people hear you and AI can't."*
  - Fine print in onboarding: *"It makes AI transcription much harder, but can't promise to stop it
    every time."*
- **Its internal name for the feature is `transcription jammer`** (a literal string in the executable).
  [observed] The design goal is defeating speech recognition, not changing the voice.
- **Whether it actually defeats Whisper is not established.** [unknown]
  - No before/after audio ships in the bundle: onboarding holds only icons and fonts.
  - The effect exists only in the app's live virtual-mic output.
  - Measuring that output against ASR is exactly what its terms forbid.
  - So our own copy must never assert that it works, or that it doesn't.

#### 9.1.2 Engine structure

The engine is a separate Swift module, `ProtectEngine`. Its classes and their fields, as recorded in
reflection metadata [observed]:

| Class | Fields (declaration order) | What it means [inferred] |
|---|---|---|
| `AudioEncoder` | `table`, `finalNorm`, `blocks`, `width`, `leftOnly`, `mixed` | Stack of `blocks` of a given `width`, a final normalisation; `leftOnly` = **causal** (sees only the past); `mixed` = a variant with some look-ahead |
| `VoiceModel` | `encoder`, `variant`, `aheadFrames`, `boundA`, `boundB`, `dsp`, `compiled`, `shiftOverride`, `compiledForward`, `accelerated`, `acceleratedFrames`, `acceleratedCalls`, `fallbackCalls`, `stageTimes`, `stageCalls` | The network plus its two loudness bounds; MLX `compile`d forward pass; an **"accelerated"** path with an MLX fallback |
| `CoreMLBox` | `error` (+ strings `weights/weight.bin`, `accelerated model: unexpected inputs`) | The accelerated path is a **Core ML model**. The `ane=%d` counter in the stats line means it targets the **Neural Engine** |
| `DSP` | `forwardBasis`, `inverseBasis`, `melFilters`, `envelopes`, `frameIndex` | STFT/iSTFT done as **matrix multiplies against precomputed bases**, plus a mel filterbank and spectral envelopes |
| `FrameStage` | — | One per-frame processing stage |
| `StreamProtector` | `config`, `modelSettings`, `loudness`, `pendingLoudness`, `stats`, `hop`, `keepSamples`, `modelFrames`, `clean`, `cleanOrigin`, `received`, `nextChunk`, `emitSample`, `fieldOrigin`, `phase`, `fieldFrames`, `open`, `rng`, `budgetNow`, `profile` | Streams audio in chunks, generates a perturbation **"field"** per chunk using a **random generator**, cross-fades it into the clean signal (`keepSamples`/`emitSample`), tracks loudness, and has a per-call compute budget |
| (config parser) | error `bad bound shape … (want hz:mult,...)` | The loudness bound is specified **per frequency**, as `hz:multiplier` pairs |
| `AudioProfileWorker` | `resource`, `queue`, `started`, `enabled`, `busy`, `nextRun`, `network`, `summaryBits`, `runs` (+ `audio-profile:v1`) | A background job that periodically runs a network and stores a compact **voice/audio profile**, probably to tailor the bound or field to this user |
| `SceneAsset` | `data`, `master` | A bundled audio asset with its own level, possibly a background-scene layer. [unknown purpose] |
| `AutoGain` | `targetDB`, `maxGainDB`, `minGainDB`, `peakCeilingDB`, `gainDB`, `levelDB`, `speechRunFrames`, `settleAboveNoiseDB`, `hangoverFrames`, `prerollFrames`, `easePauses`, `noiseDB`, `speechFrames`, `voiceRun`, `attack`, `release`, … | Speech-gated automatic gain with a peak ceiling, settling above the noise floor |
| `EchoCanceller`, `SystemAudioTap` | `aec`, `render`, `capture`, `tapID`, `aggregateID`, `procID`, … | WebRTC **AEC3**, fed by a Core Audio **process tap** of what the Mac plays |
| `LiveProtection` | `protector`, `chained`, `ringIn`, `toEngine`, `fromEngine`, `autoGain`, `echoActive`, `recentLoadBits`, … | The live session: lock-free rings (`SPSCRing`), engine thread, echo state |
| `HALInput`, `HALOutput`, `StreamClock`, `StreamResampler`, `PassThrough` | `prefill`, `highWater`, `maxDrop`, `underruns`, … | Audio I/O and clock bridging to the virtual mic |

Runtime stats line [observed]: `rounds=%4d steps=%d rtf=%.2f overruns=%d ane=%d silent=%d skipped=%d
backlog=%4.0fms buffer=%4.0fms underruns=%d trimmed=%d in_overflows=%d`. It tracks the real-time factor,
how many inferences ran on the Neural Engine, and how many silent stretches were skipped.

#### 9.1.3 Model and parameters

| Aspect | Finding | Tag |
|---|---|---|
| Weights file | `audio-model.dat`, **167,020 bytes**: at most ~42k float32 or ~84k float16 parameters | observed |
| Protection at rest | Entropy **7.999 bits/byte** (REA `ev_452486da…`): encrypted or compressed, decoded at runtime | observed / inferred |
| Size implication | Far too small to resynthesise a voice. It fits a **small network that emits a bounded additive perturbation** | inferred |
| Ops linked | MLX `FFT`, `Convolution`, `LayerNorm`, `Tanh`, `ArcTanh`, `compile` | observed |
| Output bounding | `tanh` output scaled by per-frequency bounds (`boundA`/`boundB`, `hz:mult`) relative to the voice's spectral `envelopes` | inferred |
| Look-ahead | `aheadFrames`, `prerollFrames`; `leftOnly` vs `mixed` encoder variants | observed (names) |
| Hop | `hop`, `hopMs`, `appliedHop`, `secondsByHop`: hop length is a runtime setting and is telemetered | observed |

#### 9.1.4 Product behaviour

| Aspect | Finding | Tag |
|---|---|---|
| Protection levels | **Three**: *"Strong protection with the most natural sound"* · *"More protection; your voice sounds a little more processed"* · *"The most protection; the processing is easiest to hear."* Settings copy: *"Stronger levels protect more but sound more processed."* | observed |
| Level ↔ engine | Levels most likely select a bound set (multipliers) and possibly a hop. Telemetry records `secondsByLevel` and `secondsByHop` | inferred |
| Load handling | *"May stutter on this Mac"*, *"This Mac is too busy to keep up with protection right now"*; `ProtectionAllowance`, `budgetNow`, `skipped`, `silent` | observed |
| Pipeline order | process tap → **AEC3** → `StreamProtector` (jammer) → `AutoGain` → virtual mic | observed components / inferred order |
| Echo removal | On with speaker output, *"paused (headphones)"*; needs Screen & System Audio Recording permission, asked during onboarding | observed |
| Virtual mic | libASPL HAL plug-in `ai.weirdmachine.offtherecord.driver` 1.1. Installed as root by `install-driver.sh` into `/Library/Audio/Plug-Ins/HAL`, then `coreaudiod` is restarted. Removes a pre-release *"Protected Audio"* BlackHole build | observed |
| Voice Check | Separate Core ML classifier, input 1 s at 48 kHz, output {human, AI voice, not speech} | observed |
| Unknown | Default level · exact architecture and widths · training objective and target ASRs · what the profile changes · `SceneAsset` content | unknown |

**Summary.** It is a **real-time "transcription jammer"**:
- a small, encrypted, causal perturbation network
- running on the Neural Engine, with an MLX/GPU fallback
- producing a randomised additive "field" per chunk
- limited per frequency band relative to the user's own voice
- shipped with three strength levels, echo removal before it, and auto-gain after it.

It is the same family as our `feature/privacy-shield-adversarial` predictive network.


#### 9.1.5 REA output on `myapptest`, and what each finding rests on

REA 6.8.0 ran as a CLI (`npx rea-agents@6.8.0`), with no MCP session and no native decompiler
installed. It ran three static operations; none executed the app. These are the records it returned:

**1. `inspect_desktop_application`**: evidence `ev_0d68a9f3…0552`, provider `rea-artifact-graph`, authority `shipped-artifact`, confidence `observed`
- **Target:** directory snapshot SHA-256 `001b9c84efa92bd5cd9a283dab074f10d302df988a97e1116cdba085f8390c29`
- **Coverage:** `complete-within-scan`. 187 entries examined, 6 files probed, 444 bytes read, 8 symlinks not followed.
- **Probed headers:**
  - `MacOS/OffTheRecord` and `OffTheRecordAudio.driver/Contents/MacOS/OffTheRecordAudio`: Mach-O thin (`cffaedfe`)
  - Sparkle `Autoupdate`, `Sparkle` and `Updater`: Mach-O universal (`cafebabe`)
  - `install-driver.sh`: examined
- **Runtime candidates / components / next probes:** none reported.
- **REA limitations (verbatim):**
  - *"Runtime candidates and component markers do not establish loaded code, execution, or build correspondence."*
  - *"The directory SHA-256 commits only to retained paths … not to every file's contents. Unread bytes are unknown."*
  - *"Child symlinks are not followed. … encrypted contents remain unexamined."*

**2. `analyze_javascript_application`** on `Resources/Onboarding`: evidence `ev_b534fba0…8384`
- **Statistics:** 2 relevant files, 1 JavaScript file parsed, 0 parse failures, 154,073 text bytes,
  11,422 AST nodes, 11 findings.
- **Summary:** 0 browser windows, preload entry points, context-bridge APIs, IPC operations or native
  add-on bindings. It is a WebKit page, not an Electron app, so the Electron-shaped counts are zero.
- **Endpoints:**
  - the one real one: `fetch("../Resources/terms.json")` (AST-static), which is the bundled offline Terms copy
  - six candidates (`month`, `weekday`, `day`, `advance`, `state`, `slide`) are `URLSearchParams` /
    date getters that REA labelled `interpretation: candidate`; they are not network endpoints
- **REA limitations (verbatim):**
  - *"JavaScript and HTML were parsed as inert text; bundle bootstrap code was never executed."*
  - *"Graph coverage is incomplete; unavailable facts remain explicit and must not be read as absence."*

**3. `inspect_byte_entropy`** on `Resources/audio-model.dat`: evidence `ev_452486da…3883`
- **Artifact:** 167,020 bytes, SHA-256 `7ea14d3fe6240b2e506a4665f962255edbf458ab8693f27ac8f3caf47657cc91`
- **Measurement:** file entropy **7.999 bits/byte**, classified `high` (threshold 7.2), with 4096-byte blocks.
- **REA limitation (verbatim):** *"Entropy does not prove encryption; compressed and encrypted bytes
  cannot be distinguished by this measure."*

**What rests on what**

| Claim in §9.1 / §9.2 | Source |
|---|---|
| Bundle identity, file inventory, which files are native code, driver binary present | REA #1 |
| Onboarding has no network calls except the bundled Terms; onboarding copy (*"People hear you. AI gets nothing."*, the fine-print hedge, the install and echo screens) | REA #2 (structure); the copy itself read from `index.html` |
| Model is 167 KB and high-entropy (encrypted or compressed) | REA #3 |
| `transcription jammer`; `ProtectEngine` classes and fields; `hz:mult` bound; the three level texts; *"Reshapes your voice so AI can't transcribe it"*; the stats line; echo on/paused messages | `strings` on `MacOS/OffTheRecord` (Swift reflection metadata and literals), **not REA** |
| Bundle ID, signer, permission texts, Sparkle feed | `Info.plist` and `codesign -dv`, **not REA** |
| Driver install as root, `coreaudiod` restart, legacy BlackHole removal | `install-driver.sh` (REA #1 probed it; content read directly) |
| The architecture interpretation (causal encoder, ANE path, per-band bounded perturbation) | **Inference** from the names above. No REA operation decompiled or traced code |
| Everything in §9.2 (how to recreate it) | **Our design**, from the cited papers and the `feature/privacy-shield-adversarial` branch. REA does not produce recreation guidance |

**Not run, deliberately:**
- native decompilation (REA `open_binary` / `decompile` with Ghidra, Hopper or IDA)
- disassembly of `ProtectEngine`
- decrypting `audio-model.dat`
- runtime capture of the app's output

Those would recover exact layer widths and the training-independent signal chain, but they fall
under the terms' prohibition on reverse engineering and model inspection, and the branch's
clean-room rule. Any exact-architecture claim therefore stays **[unknown]**.

---

### 9.2 Recreation guide: building our own transcription jammer (clean-room)

This guide uses **only** published research and our own measurements. Where it reaches the same
design as §9.1, that is because the published literature leads there, not because it was copied. Build
on the existing branch `feature/privacy-shield-adversarial`:
- training and evaluation: `Tools/privacy-shield/eval/` (`pnet.py`, `train_pnet.py`, `run_eval.py`,
  `export_pnet.py`)
- native runtime: `Whisperer/PrivacyShield/Native/ShieldPNet.hpp`
- live processing: `PrivacyAudioProcessor.swift`

The branch's `docs/knowledge/privacy/rules.md` stays binding: measure after the call path, put the
codec and denoiser in the training loop, never evaluate on training models, fail closed, and never
claim "blocks transcription".

#### 9.2.1 What to build

A causal network that, every 10 ms, predicts a perturbation δ for the *next* block from the *past*
audio. The perturbation is added to the voice, and stays under a per-band ceiling tied to the voice's
own spectrum.

- People hear the voice, with faint, voice-shaped texture.
- ASR models are pushed toward wrong tokens.

This is the *predictive attack* from **Chiquier, Mao & Vondrick, "Real-Time Neural Voice Camouflage"
(ICLR 2022)**, with the masking constraint from **Schönherr et al., "Adversarial Attacks Against ASR
Systems via Psychoacoustic Hiding" (NDSS 2019)**, made robust over the call path via
**Expectation over Transformation (Athalye et al., ICML 2018)**.

#### 9.2.2 Signal path (per 10 ms block, 48 kHz)

```
mic ─▶ AEC3 (system-audio tap reference; off on headphones)
    ─▶ analysis: 16 kHz decimate · STFT (win 25 ms, hop 10 ms) · 64-band log-mel · spectral envelope E(f)
    ─▶ network (causal, 0–3 frames look-ahead) ─▶ raw field z(f,t)  ∈ (-1,1) via tanh
    ─▶ bound: δ(f,t) = z(f,t) · B_level(f) · E(f,t)        (B = per-band multiplier table, "hz:mult")
    ─▶ + random phase / per-session seed  ─▶ iSTFT, overlap-add, 48 kHz interpolate
    ─▶ y = x + δ  ─▶ AutoGain (speech-gated, peak ceiling −1 dBFS) ─▶ virtual mic
```

- **Domain:** generate δ in the STFT domain (magnitude mask × random phase), or directly as a waveform
  as the branch's current GRU head does. Start with the existing waveform head, which has already
  measured 11.9 % drift. Add the spectral bound as a post-stage, so loudness is controlled per band
  rather than only overall.
- **STFT as matrix multiplies:** precompute DFT and inverse-DFT bases. This keeps the whole stage
  inside one Core ML / Accelerate graph with no FFT plan objects on the audio path.
- **Latency budget:** look-ahead frames × 10 ms + one block. Keep total added latency ≤ 40 ms, which
  conferencing apps tolerate.

#### 9.2.3 Network

| Item | Starting point | Why |
|---|---|---|
| Front end | 1 conv over the past 25 ms (400 samples at 16 kHz) → C = 64, then LayerNorm | Matches `ShieldPNet` today |
| Body | 2-layer GRU (H = 64) **or** 4 causal dilated conv blocks (width 64, kernel 3, dilations 1-2-4-8) | GRU is what we have. Dilated conv converts cleanly to Core ML and runs on the ANE |
| Head | linear → 160 samples (or 64 mel-band gains), `tanh` | Bounded output, so the ceiling is exact |
| Size target | **30–80k parameters** (current branch: 747k) | Fits ANE residency and a ≤ 0.1 ms/block budget at low power. Distil from the 747k model if quality drops |
| Variants | causal-only and causal + 2-frame look-ahead | Trade latency against strength; expose look-ahead only on the strongest level |

#### 9.2.4 Loudness bound and levels

- Compute E(f,t) as the smoothed (≈ 50 ms) log-mel envelope of the voice. When there is no speech
  (VAD off), E falls to a floor, so δ ≈ 0 in pauses and there is no audible hiss between words.
- The bound table `B_level(f)` is a small per-band multiplier list, stored as `hz:mult` pairs in the
  model header so it can be tuned without retraining:

| Level | Copy | Bound (below voice, per band) | Look-ahead |
|---|---|---|---|
| 1 Natural (default) | "Strong protection with the most natural sound" | −14 dB in 300–3400 Hz, −10 dB outside | 0 |
| 2 Stronger | "More protection; sounds a little more processed" | −10 dB / −7 dB | 1 frame |
| 3 Maximum | "The most protection; the processing is easiest to hear" | −6 dB / −4 dB | 2 frames |

- These are **starting values to tune** against intelligibility (ESTOI ≥ 0.85 at level 1) and drift.
  The branch's open hypothesis (δ ≥ 10 dB under speech per mel band) is the level-1 test.
- Train **one** network with the bound applied as a differentiable stage, so the same weights serve all
  levels. During training, sample the level uniformly per batch.

#### 9.2.5 Training

1. **Data:** consented speech only: our own recordings plus public corpora with compatible licences
   (LibriSpeech, Common Voice he/ru/en, FLEURS). Split by **speaker**; the evaluation speakers are
   never seen in training.
2. **Target ensemble (white-box, differentiable):** Whisper tiny, base and small (Hugging Face
   PyTorch), wav2vec2-base CTC, and one Conformer-CTC. **Held out for evaluation only:** whisper.cpp
   large-v3 and turbo, Parakeet, Apple Speech, and one cloud ASR.
3. **Loss:**
   - Untargeted: maximise the CTC / seq2seq loss of the true transcript, averaged over the ensemble.
   - Plus a **perceptual penalty**: band energy of δ above the bound, plus a small multi-resolution
     STFT distance between y and x.
   - Plus a **total-variation term on z**, to suppress musical-noise artefacts.
4. **EOT over the call path** (rule 2), sampled per batch:
   - room impulse response and loudspeaker band-limit
   - Opus at 16–32 kb/s (straight-through gradient)
   - RNNoise, plus a WebRTC NS/AGC stand-in
   - random gain of ±6 dB, ±2 sample-clock drift, packet-loss concealment
5. **Randomness:** a per-session seed feeds dropout-like noise into the head at inference. This keeps
   the perturbation from being one learnable pattern; the universal-perturbation runs showed fixed
   patterns are weak at safe loudness.
6. **Schedule:** AdamW, lr 3e-4 → cosine, fixed-length buckets (already done for MPS), 20–50k steps.
   Checkpoint on held-out drift **after the call**, not on training loss.
7. **Stability:** dither every signal entering a differentiable ASR front end, and never take `abs()` of
   a complex STFT (rule 4).

#### 9.2.6 Runtime on the Mac

- **Primary path:** convert to **Core ML** (ML Program, fp16), with fixed input shapes per block
  (stateful GRU through `MLState` on macOS 15+, or the conv variant with a cached context window).
  Prefer the ANE with `MLComputeUnits.cpuAndNeuralEngine`; this leaves the GPU free for whisper.cpp's
  Metal encoder, avoiding the GPU contention described in CLAUDE.md.
- **Fallback:** the existing allocation-free C++ `ShieldPNet` on Accelerate. Keep the native/PyTorch
  parity test at ≤ 1e-6 and ASan/UBSan clean.
- **Threading:** the Core Audio callback only copies into an SPSC ring; inference runs on one worker
  thread. If the worker falls behind by more than 2 blocks:
  - emit the block **unprotected but marked**, and drop to a cheaper hop or level
  - surface "This Mac is too busy to keep up" in the UI
  - never block the audio callback, and never output silence.
- **Fail closed:** if the model fails to load or verify, protection does not start (rule 6).
- **Weights at rest:** sign the model file and verify a SHA-256 in the app bundle. Encryption is
  optional; it protects nothing from a determined user but deters casual copying.

#### 9.2.7 Echo removal and gain

- **AEC3** (WebRTC, BSD) before the network, with the reference taken from a Core Audio process tap
  (`AudioHardwareCreateProcessTap`, macOS 14.4+).
- Bypass AEC3 when the output route is headphones (no acoustic echo, and it saves CPU).
- Without the system-audio permission, run without AEC and say so. The jammer still works; the other
  person just hears a little of themselves.
- **AutoGain after** the jammer, so the bound relationship stays intact: it is a ratio to the voice,
  and gain scales both.

#### 9.2.8 Evaluation and ship gate

- **Bench:** `Tools/privacy-shield/eval/run_eval.py` on the held-out speakers and ASRs. Report per
  level, both direct and after the call:
  - WER drift
  - key-fact survival
  - ESTOI
  - speaker-verification cosine (ECAPA), for the identity claim
- **Listening check:** 10 listeners MOS-style; level 1 must score ≥ 4.0 on "sounds natural".
- **Gate to ship a level:**
  - after-the-call drift ≥ 30 % median on held-out ASR
  - ESTOI ≥ 0.85 at level 1
  - real-time factor ≤ 0.3 on an M1 base model
  - zero unprotected blocks in a 60-minute soak, except the marked overload path
- **Copy:** state measured numbers only ("makes transcription much harder: a median of N % of words
  wrong in our tests"). Never say "AI can't transcribe you" (rule 7). Never compare against Off the
  Record's output, which its terms forbid.

#### 9.2.9 Milestones

1. Add the spectral bound stage and three level tables to the current GRU network. Re-measure.
2. Train the small (30–80k) dilated-conv variant with the full EOT call path and the multi-ASR
   ensemble. Distil from the 747k model if needed.
3. Core ML export, an ANE residency check, and native parity. Integrate behind
   `PrivacyAudioProcessor` with fallback to the C++ path.
4. AEC3 with a process tap; headphone bypass; AutoGain after.
5. Run the full bench, listening test and soak. Set the level-1 default from the measurements.
6. Update the product copy from the measured numbers.
---

## 10. Machine-learning models

### VoiceCheck.mlmodelc (classifier)
| Property | Proposed value |
|---|---|
| Format | CoreML **ML Program**, spec v9 (iOS18/macOS15 op set) |
| Input `x` | Float32 **[1, 48000]** → **1 second of 48 kHz mono audio** |
| Output `p` | Float32 **[1, 3]**, softmax → **{human, AI voice, not speech}** |
| Topology | small CNN (~18 conv + 17 relu, reductions, final linear + softmax) |
| Training/export | PyTorch → coremltools (TorchScript source), Float32 weights |

### audio-model.dat (reshaping model)
- Weights for the reshaper, shipped as an opaque blob.
- Recommend **packing or encrypting at rest** (high entropy), expanded/decrypted at runtime for MLX. If encrypted, manage the key via the licensing/Keychain layer.

### MLX backend bundle
- The **MLX** compute backend (ml-explore) + a compiled **Metal shader library** (`default.metallib`).
- Code-sign the bundle independently.

---

## 11. The virtual audio driver

`Resources/VoicePrivacyAudio.driver`
- A **userspace CoreAudio HAL plug-in** (AudioServerPlugIn): `CFPlugInFactories` → a factory entry point, plug-in type `443ABAB8-E7B3-491A-B985-BEB9187030DB`. Mach-O arm64, bundle type `BNDL`, `sandboxSafe = true`.
- Link only CoreAudio + CoreFoundation; keep all app logic out of the driver.
- Build on **libASPL (MIT)** — an open-source AudioServerPlugIn helper. (A simpler starting point is a **BlackHole**-based loopback driver during prototyping.)

**Installation** via `Resources/install-driver.sh` (runs as root; the app requests the password, or uses ServiceManagement):
- Copy the driver to **`/Library/Audio/Plug-Ins/HAL/VoicePrivacyAudio.driver`**, `chown root:wheel`, `chmod 755`, then restart `coreaudiod` (`launchctl kickstart -k system/com.apple.audio.coreaudiod`).
- Support `--uninstall`, and clean up any prototype/legacy driver from an earlier identifier during migration.

---

## 12. The Bluetooth "stick" hardware

- A physical accessory streaming audio and carrying **phone calls to/from the Mac over Bluetooth**; a **front button toggles protection**, and **holding it moves a call** between Mac and phone.
- **Transports:** `AccessoryUSB` and `AccessoryBLE`. BLE linking should require a minimum firmware version and **on-device confirmation** via **numeric comparison** (compare a code shown in the macOS Bluetooth dialog with the stick).
- **Audio codec:** **Opus** (`AccessoryOpus`).
- **Custom GATT service/characteristic UUIDs:** assign during implementation (placeholders `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`).
- **Firmware flashing:** `StickFlasher` flashes via the **ESP32 ROM bootloader over USB**; support BLE DFU as well. Use a small binary command protocol (write-at-offset, verify, status).
- Suggested UX states: *Looking for nearby unpaired sticks · Connected, not paired · New stick connected · Checking your stick · Forget This Stick · A new version for your stick · Firmware installed, waiting for restart.*

---

## 13. Stick firmware image format

Proposed container for `Resources/stick-firmware.bin`:

**Layout:** a **4-byte little-endian length prefix** + a **plaintext JSON manifest**, followed by the concatenated (compressed) region payloads.

```json
{"version":1,"chip":"ESP32-PICO-D4","flash":4194304,"regions":[
  {"name":"bootloader","offset":4096,  "size":26960,  "md5":"<hex>","start":0,     "length":16876, "installOnly":false},
  {"name":"partitions","offset":32768, "size":3072,   "md5":"<hex>","start":16876, "length":105,   "installOnly":false},
  {"name":"settings",  "offset":36864, "size":28672,  "md5":"<hex>","start":16981, "length":51,    "installOnly":true},
  {"name":"app",       "offset":65536, "size":1187968,"md5":"<hex>","start":17032, "length":771851,"installOnly":false}]}
```

Semantics:
- **MCU:** an **ESP32-PICO-D4** (4 MB flash) — standard ESP32 layout: *bootloader → partition table → NVS "settings" → application*.
- `offset` = flash address; `start` + `length` = byte span inside `stick-firmware.bin`; `size` = uncompressed flash size (> stored `length` ⇒ regions are **compressed**); `md5` = per-region integrity check.
- **`settings` is `installOnly:true`** → written on first install but **preserved across updates** (keeps saved pairings/settings).
- Track a monotonically increasing firmware **version**; support a USB fallback for an interrupted update and BLE DFU above a minimum version.

---

## 14. Onboarding UI & native bridge

`Resources/Onboarding/` — a **WebKit** wizard (`index.html`, `onboarding.js`, `onboarding.css`, bundled fonts, conferencing-app SVGs).

**Eight steps:** `welcome → terms → how → install → mic → echo → use → done`.

**JavaScript ⇄ native bridge** — `window.webkit.messageHandlers.<name>`:

| Direction | Messages |
|---|---|
| **Page → native** (`post`) | `ready`, `acceptTerms{version}`, `declineTerms`, `install`, `requestMic`, `requestSystemAudio`, `skipSystemAudio`, `setLaunchAtLogin{on}`, `setShareStats{on}`, `openSettings{pane}`, `finish`, `close` |
| **Native → page** | a single `update(state)` callback where `state = {driver, driverError, mic, systemAudio, launchAtLogin, terms, termsAccepted, setupDone, device, realMic, start, skippedEcho}` |

Behavior:
- `driver` state machine: `missing → installing → installed` (also `update`, `failed`, `cancelled`).
- `mic` / `systemAudio`: `unknown → denied/granted`; a denied permission routes the user to System Settings via `openSettings{pane}`.
- **Terms** fetched live from a versioned JSON endpoint with a bundled offline fallback; re-acceptance forced when the terms `version` increments.
- Provide a browser-preview fallback that simulates the native side (`?state=`, `?slide=`, `?advance=` dev params) when `window.webkit` is absent.

---

## 15. Licensing, billing & device auth

- Core type **`BillingModel`**; supporting types `BillingEntitlement`, `BillingEnvelope`, `BillingFailure`.
- **Team / seat model**: Free plan + paid **seats**; email **invitations** with join links (`InviteSheet`, `JoinTeamSheet`, `InviteLink`, "Copy Invite Link"); "Add or remove seats in Manage Subscription"; an organization-plan contact path.
- **Checkout in the browser**; the app reflects the new plan once payment completes.
- **Offline grace**: cache the entitlement and time-box it (e.g. ~7 days offline) before reverting to Free.
- **Device auth (challenge-response)**: client holds a device key (CryptoKit); server issues a signed entitlement/"access certificate"; a nonce exchange (`deviceNonce`/`macNonce`/`challenge`/`offeredKey`) yields a `sessionToken`. Store `deviceToken`/`sessionToken` in the Keychain.
- Device-management endpoints: `/v1/account/devices/remove`, `/v1/device/unlink`, `/v1/team/invitations/revoke`.

---

## 16. Auto-update

- **Sparkle** embedded at `Frameworks/Sparkle.framework`, with its sandboxed **Updater.app** and XPC services. Wrap it in an `Updater` type.
- HTTPS appcast feed, hourly checks, automatic checks enabled.
- **Security:** Ed25519-signed appcast required; update verified before extraction; system profiling disabled. (Keys in §5.2.)

---

## 17. Telemetry

- Setting: **"Share anonymous usage stats"** — opt-in, **off by default**.
- If enabled, send **once a day**: how long protection runs, which strength is used, and whether the Mac keeps up. **Never audio, content, or anything identifying.**
- Separate endpoints for usage stats and user feedback; a `UsageStats` type handles aggregation.

---

## 18. Third-party software bill of materials

| Component | Role | License |
|---|---|---|
| **MLX / MLX Swift / MLX C** | Runs the voice-reshaping model on the GPU | MIT |
| **metal-cpp** | Part of MLX | Apache 2.0 |
| **{fmt}** | Part of MLX | MIT |
| **JSON for Modern C++** (nlohmann) | Part of MLX | MIT |
| **Swift Numerics** | Used by MLX Swift | Apache 2.0 |
| **WebRTC audio processing (AEC3)** | Removes speaker echo from the mic | BSD 3-Clause |
| **libASPL** | Powers the virtual audio driver | MIT |
| **Sparkle** | Auto-update | Sparkle license |

---

## 19. Network endpoints

All hosts/paths are **placeholders** to be assigned:

| URL (placeholder) | Purpose |
|---|---|
| `https://updates.example.com/appcast.xml` | Sparkle update feed (Ed25519-signed) |
| `https://billing.example.com` | Billing/licensing API |
| `…/v1/account/devices/remove` | Remove a device from the account |
| `…/v1/device/unlink` | Unlink this device |
| `…/v1/team/invitations/revoke` | Revoke a team seat invitation |
| `https://example.com/terms.json` | Live Terms of Use (versioned) |
| `https://example.com/terms` · `/privacy` | Terms / privacy pages |
| `https://example.com/api/stats` | Opt-in anonymous usage stats |
| `https://example.com/api/feedback` | User feedback |

---

## 20. Open design questions

- **Reshaping model:** architecture, latency budget per block, and whether `audio-model.dat` is compressed, encrypted, or both (and how the key is provisioned).
- **Licensing crypto:** exact key type and signing scheme; whether to bind to the Secure Enclave and/or gate with `LocalAuthentication` biometrics.
- **Stick protocol:** final GATT service/characteristic UUIDs and the binary command set for flashing and call control.
- **Echo cancellation:** AEC3 configuration/tuning for the speaker→mic path at 48 kHz.
- **Endpoint surface:** finalize the billing/stats API contract and auth headers.

---

## 21. Build & validation plan

**Static checks**
- Verify signing, entitlements, hardened runtime, and the Designated Requirement before release.
- Confirm the appcast is Ed25519-signed and that the client refuses unsigned/altered feeds.

**Dynamic checks**
- Exercise the live audio path (mic → AEC → reshaper → virtual mic) and measure end-to-end latency.
- Validate Keychain/CryptoKit usage and the billing challenge-response against the staging environment.
- Fuzz/verify the stick flashing path and per-region checksum enforcement.

**Firmware**
- Carve the four regions out of `stick-firmware.bin` by their `start`/`length`, decompress, and verify against the listed checksums before flashing.

---

## 22. Proposed configuration reference

| Item | Proposed value (placeholder) |
|---|---|
| Main binary | `MacOS/VoicePrivacy`, Mach-O arm64 |
| Team ID | `<TEAM_ID>` — Developer ID Application |
| Authorities | Developer ID Application → Developer ID CA → Apple Root CA |
| Entitlements | `com.apple.security.device.audio-input = true` |
| Hardened runtime | enabled |
| Sparkle | embedded; feed `updates.example.com/appcast.xml` |
| Sparkle Ed25519 pubkey | `<SUPublicEDKey>` |
| Billing host | `https://billing.example.com` (+ `…billing.preview`) |
| Keychain service | `voiceprivacy.billing-keychain` |
| Stick MCU / firmware | ESP32-PICO-D4, 4 MB flash, versioned firmware |
| Stick GATT UUIDs | `<SERVICE_UUID>`, `<CHARACTERISTIC_UUID>` |
| Stick audio codec | Opus |
| `audio-model.dat` | packed/encrypted weights blob |
| `VoiceCheck.mlmodelc` | in `[1,48000]` f32 → out `[1,3]` softmax (human / AI / not-speech) |
| Driver | `VoicePrivacyAudio.driver` (libASPL, MIT) → `/Library/Audio/Plug-Ins/HAL/` |

---

*This is a proposed implementation/design document. All names, identifiers, keys, hosts and UUIDs are
placeholders to be finalized during development.*

# Privacy Shield (experimental)

This branch implements local microphone processing and a virtual microphone. It
**does not contain a trained anti-transcription model or establish efficacy**.
The bundled DSP is a reproducible amplitude-modulation/noise baseline, deliberately
labelled unvalidated. A compatible compiled Core ML model can be loaded explicitly.
No competitor binary, code or model is reused. libASPL is MIT-licensed upstream code.

## Build and use

The existing Xcode `whisperer` scheme builds the native transport and embeds the
audio driver in Debug/Release. It needs CMake (`brew install cmake`), Xcode, and the
project's normal dependencies. The AppStore configuration excludes the driver and
installation controls. The external CMake build runs in its own aggregate target;
the app target retains its existing script-sandbox settings. The project currently targets macOS 26.2, inherited unchanged.

1. Build and launch the direct-download app.
2. Open the **Privacy Shield** app menu → **Privacy Shield Settings…**, or the menu-bar popover settings. Finish active calls before clicking **Install
   driver (restarts audio)…**. macOS requests administrator authorization. The
   driver installs under `/Library/Audio/Plug-Ins/HAL/WhispererAudio.driver`.
3. Refresh devices, select a physical microphone and confirm headphones are in use.
4. Choose the baseline strength or load a compatible `.mlmodelc` package.
5. Enable processing, then select **Whisperer Virtual Mic** as the microphone in the
   calling application. Keep normal headphones selected as the speaker output.
6. Enable/disable from the popover strip, right-click menu, app menu, or settings.
   When finished, turn processing off. The virtual mic becomes silent. Select your
   physical microphone in the call to resume unprocessed audio. Removal is available
   while off and also restarts system audio.

The first implementation intentionally requires headphones. System playback tap /
WebRTC speaker echo cancellation is **not implemented**. This is a visible unsupported
configuration, not a silent fallback. Do not use speaker mode to evaluate efficacy.

Do not interpret “active” as verification that a meeting app selected the virtual
mic. Apps can independently switch their input, and all claims are confined to our
virtual route. Processing does not prevent recording or later transcription.

Manual driver build and removal:

```sh
Tools/privacy-shield/build-driver.sh
sudo Tools/privacy-shield/install-driver.sh "$PWD/build/privacy-shield/WhispererAudio.driver"
sudo Tools/privacy-shield/install-driver.sh --uninstall
```

`SHIELD_ARCHS` defaults to `arm64;x86_64`; Xcode uses its target architectures.
`SHIELD_SIGN_ID` defaults to ad-hoc for local development. Distribution must use the
release signing identity and the application's existing notarization workflow.
No driver installation or system-audio restart is performed by a build.
For CI or an already-built driver, set `SHIELD_PREBUILT_DRIVER` to the full signed
`.driver` bundle path in the Xcode build settings/command. Its identifier and signature
are verified before embedding. This avoids rebuilding the external CMake target.

## Signal path and failure contract

A dedicated AUHAL captures mono float32 at the physical device's native rate. Its
callback only renders into preallocated memory and a bounded SPSC queue. A separate
worker performs a 32-tap windowed-sinc resample using precomputed/interpolated phase filters, 480-frame/48 kHz processing and an
output limiter. A separate AUHAL output feeds the virtual device. A small bounded
rate correction follows queue depth to accommodate clock drift. No file writer,
transcriber or history service participates in this path.

The virtual device has input and output streams on **one shared device clock**;
this intentionally implements the planned feed endpoint as the output side of a
single duplex device. It is not a second independently clocked device. Choose its
input in the meeting app, not its output as your speakers. It cannot become the
system default through the driver's default-device eligibility flag.

The libASPL driver accepts output only from a client identifying itself as the
Whisperer bundle, and only one producer client at a time. Bundle-ID filtering is
accidental-routing prevention, **not a security boundary against malicious local
software**. Timestamp-tagged atomic frames let multiple microphone clients read
without consuming each other's audio. Missing frames are silence. Driver loopback
delay is 1,024 frames (~21.3 ms). Initial producer buffering is at least 1,440 frames
(30 ms), increased to cover hardware input/output buffer periods. Configurations
requiring more than 80 ms of initial buffering are rejected.
These are design parameters, not a measured end-to-end latency result.

Starting, muted/faulted, and stopping states all block new Whisperer recording.
Enabling is refused during active recording, transcription, or pending meeting
startup. The user must stop those first. Driver installation also blocks recording until it finishes. A lock-free guard blocks the existing
recorder's sample delivery and disk-write path. Existing historical file processing
is not automatically cancelled. Input loss, overflow, underrun, NaN output or a
worker block exceeding 100 ms latch a fault; no raw passthrough fallback exists.
Retry creates fresh buffers/model state. An app crash leaves no new driver frames.
There can still be already-processed audio in the driver's finite presentation
window. Other apps' independent microphone fallback remains outside our control.

The control queue joins the worker on shutdown. Core ML inference is synchronous;
a hung system inference call cannot be forcibly cancelled safely in-process. Output
is silenced before joining, but stop completion may wait for that call. A production
model should receive a separate-process watchdog before broader deployment.

## Model contract

Use a trusted, compiled Core ML `.mlmodelc` package with exactly one input named
`audio`, float32 `[1, 480]`, and an output named `processed`, float32 `[1, 480]`.
Samples are mono, 48 kHz, roughly [-1,1]. A block represents 10 ms. The processor
must be causal and work without undisclosed future context. This adapter currently
supports stateless block models only; stateful/context-window models need a versioned
adapter extension and are not assumed compatible. Warmup validates the schema and
output before opening capture. Errors do not fall back to another algorithm.

Runtime validates finiteness and applies a ±0.98 limiter. Include that limiter,
resampling and conferencing processing during training/evaluation. Model inference
is local and never runs in the Core Audio callback. Loading a model is not evidence
of robustness, human intelligibility or actual call latency.

## Native and app tests

```sh
SHIELD_ARCHS=$(uname -m) Tools/privacy-shield/build-driver.sh
Tools/privacy-shield/validate.sh

# Individual checks:
clang++ -std=c++17 -fsanitize=address,undefined -g \
  Tools/privacy-shield/native-tests.cpp -o /tmp/shield-native-tests
/tmp/shield-native-tests
python3 -m unittest discover -s Tools/privacy-shield -p 'test_*.py'
Tools/privacy-shield/test-standalone.sh
xcodebuild -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
  -destination 'platform=macOS' -only-testing:WhispererTests/PrivacyShieldTests \
  -only-testing:WhispererTests/PrivacyShieldControllerTests test
```

The native tests exercise queue bounds, concurrent producer/consumer order,
timestamp wrap/stale rejection, output bounds and rate conversion. They do not
substitute for installed-driver, microphone, sleep/wake, Bluetooth, or receiver-side
call testing. App tests cover gating, baseline output and invalid-model rejection.

## Offline evaluation

Build the exact same baseline used by the app:

```sh
Tools/privacy-shield/build-benchmark.sh
python3 Tools/privacy-shield/benchmark.py process original.wav processed.wav \
  --library build/privacy-shield/libShieldBenchmark.dylib --strength 0.35
```

Inputs must be mono 48 kHz PCM16 WAV; outputs preserve duration. This command writes
only the requested processed file and refuses to overwrite the original. Use consented
audio. To measure real calls, record separate clean and processed receiver-side WAVs
for the same script, identify their channel condition, and align the reference.

A paired manifest is JSONL; filenames are relative to its directory:

```json
{"id":"he-01","speaker":"speaker-01","language":"he","condition":"meet-receiver-headphones","split":"evaluation","reference":"human reference transcript","key_facts":["a name","a number"],"clean_audio":"clean.wav","processed_audio":"processed.wav"}
```

Engine configuration is JSON. Commands are explicit argument arrays executed without
a shell. A text adapter writes UTF-8 to `{output}`. The `whisper_json` adapter reads
`{output}.json` generated by whisper.cpp. Use fixed model versions and diverse families:

```json
{"engines":[{"name":"whisper-large-v3","family":"whisper","version":"record model hash and binary revision","role":"holdout","remote":false,"format":"whisper_json","command":["/path/to/whisper-cli","-m","/path/to/model.bin","-f","{audio}","-l","{language}","-oj","-of","{output}"]}]}
```

```sh
python3 Tools/privacy-shield/benchmark.py run corpus.jsonl --engines engines.json \
  --work-dir /path/to/private/evaluation-work --output evaluation.json
```

Use an empty private work directory. Adapter scratch transcripts are deleted after
successful parsing, but failed runs may leave files there. Adapter logs are suppressed;
external programs still control their own side effects. Remote adapters are refused
unless `--allow-remote` is supplied; declaring an adapter local is a trust contract,
not an OS network sandbox. The runner itself makes no network calls.

For existing transcripts, replace the two audio fields with `clean` and `processed`
text fields and add `engine`, then run:

```sh
python3 Tools/privacy-shield/benchmark.py score pairs.jsonl --output evaluation.json
```

Reports contain counts, not raw transcripts; identifiers should still be pseudonymous.
Metrics include S/D/I breakdown, baseline and processed WER, mean utterance CER,
literal key-fact recovery, and paired WER-delta confidence intervals bootstrapped
by speaker. WER may exceed 100%. Results are stratified by engine, language and
condition. A single speaker produces no misleading confidence interval. Normalization
is versioned NFKC/casefold/punctuation removal; document any language-specific changes.
Literal matching misses paraphrases: blinded human semantic recovery, comprehension,
naturalness and fatigue evaluation remain mandatory. No automatic release verdict or
“protection percentage” is generated.

Use English, Hebrew, Russian and code-switching; isolate speakers and scripts between
training and evaluation. A final holdout must not be used repeatedly to select models.
The runner checks split labels, not the provenance of your entire training set. Record
human listening results and runtime latency separately. Proposed targets from the plan
(95% human word accuracy, ≤3-point loss; p95 latency ≤60 ms/p99 ≤100 ms) remain unmeasured.
Fix a justified maximum key-fact recovery before final evaluation. Reject the product
claim if the effect disappears on unseen ASR or receiver-side audio.

## Remaining empirical work

A trained model, consented multilingual corpus, blinded listeners, independent ASR
runs, real Zoom/Teams/Meet round trips, minimum-device latency/thermal measurements,
and release signing/notarization are not produced by this implementation. No benchmark
numbers are fabricated. The research gate in the revised plan remains open.

## Validation performed on this branch (2026-10-17)

- Full Debug app build and launch succeeded. The app-menu Enable action was exercised:
  missing setup opened the settings window with a clear explanation.
- Xcode-hosted tests now run successfully; the earlier library-loading stall did not
  recur. Feature tests include a real, locally compiled Core ML model processing 100
  alternating float32 blocks, capture gating and setup/stop behavior. The deterministic
  test model halves samples; it is not a protection model.
- Audio recovery, stall policy and session-file regression suites are included in the
  validation run: 48 app-hosted tests passed, with zero failures.
- Native queue/DSP, production-worker, and production-driver callback tests run with
  AddressSanitizer and UndefinedBehaviorSanitizer. Driver callbacks include client ID
  zero, multiple readers, producer filtering/removal/replacement and invalid timestamps.
- The 120-second synthetic worker run completed 12,004 blocks with zero underruns,
  3.32 ms maximum block time under sanitizers, and 42.67 ms final queued audio.
  Timed synthetic worker runs verify priming and delivery; fault
  injection covers invalid output, processor failure, excessive processing time,
  missing input and latched underruns. These runs do **not** go through installed HAL.
- Offline 10,000-block benchmarks at each of 16/44.1/48/96/192 kHz measured median
  resampling plus baseline time around 0.016 ms (previously 0.13 ms), roughly 8× faster.
  These optimized-build numbers exclude HAL scheduling, conferencing and Core ML.
- Seven standalone Swift tests and six Python evaluation-harness tests pass.
- **Negative efficacy smoke test:** whisper.cpp large-v3-turbo-q5_0 transcribed both
  the bundled JFK sample and a newly generated English speech sample identically
  before/after baseline processing at strength 0.35. The generated sample's name,
  time, budget and deadline remained recoverable. Two local English clips with one
  recognizer are not a multilingual or receiver-side evaluation, but they directly
  fail to demonstrate the proposed protection. No anti-transcription claim is justified.
- Driver installation, live microphone routing, actual call reception, device changes,
  sleep/wake, Bluetooth and end-to-end latency still require system-level validation.
  No administrator authorization or headphone confirmation has been supplied for it.

The test harness does not use existing private recordings. `make-model-fixture.py`
regenerates the embedded model fixture if coremltools is installed; normal test runs
need no Python ML package. An unexpected test-host crash was isolated to destruction
of temporary MainActor controller instances in synchronous XCTest methods; tests now
use the actual singleton, and its initializer is private to enforce that lifecycle.

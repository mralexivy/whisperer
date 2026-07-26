# Agent 8 — Audio Pipeline & Real-Time Safety Reviewer

## Inputs
- `.claude/review-state/diff.patch`
- `.claude/review-state/changed-files.txt`
- `.claude/review-state/context.json`
- `.claude/review-state/knowledge-snapshot.md`
- Full source of every changed file in `Whisperer/Audio/`, `Whisperer/Transcription/StreamingTranscriber.swift`
- Reference: `CLAUDE.md` Critical Rules, `ARCHITECTURE.md` §Audio Pipeline, `docs/references/whisper-cpp-integration.md`

## Output
Write to `.claude/review-state/findings/agent-08.md`
Return: `Agent 8 (Audio & Real-Time): X P0, Y P1, Z P2`

## Preamble

Run only when `changed-files.txt` contains files from `Audio/`, `Whisperer/AppState.swift`, or `StreamingTranscriber.swift`. Always run.
Read `docs/knowledge/audio/rules.md` if it exists.

## Focus Checklist

### Audio Engine Actor Isolation

**BUG-A12 (P0)**: `AVAudioEngine`, `AVAudioInputNode`, `AVAudioMixerNode`, and all audio tap operations must live inside the `AudioEngineLifecycle` actor (or its equivalent owning actor). Pattern: any file OUTSIDE `AudioEngineLifecycle` that holds a reference to `AVAudioEngine` or calls `engine.inputNode.installTap(...)`, `engine.removeTap(...)`, `engine.start()`, `engine.stop()`. Flag each as P0.

### ObjCTry Wrapping

**BUG-A09 (P1)**: These `AVFoundation`/`AVAudioEngine` calls throw `NSException`, not Swift `Error` — Swift `try/catch` cannot intercept them:
- `inputNode.installTap(onBus:bufferSize:format:block:)`
- `inputNode.removeTap(onBus:)`
- `engine.start()`
- `engine.stop()`
- `AudioUnit` property-set calls

Any invocation of these NOT wrapped in `ObjCTry { }` is P1. Pattern: grep the diff for these call sites and verify `ObjCTry` wrapping.

### HAL Concurrency During Engine Start

**BUG-A01 (P0)**: Any HAL reconfiguration (audio muting, aggregate device creation, audio device switching) that runs concurrently with `engine.start()` causes silent recording (`kAudioUnitErr_NoConnection` / error `-10877`). Pattern: check that `AudioMuter`, `AudioDeviceManager`, or any aggregate-device setup is strictly sequenced to complete BEFORE `engine.start()` is called. Flag any `Task { AudioMuter.mute() }` or concurrent HAL call that could overlap with engine startup.

### Speech/Energy Check Before Transcription

**BUG-A02 / BUG-A13 (P1)**: Audio sent to Whisper or any `TranscriptionBackend` without a prior energy/VAD check produces hallucinations ("Thank you", "Soustitrage ST 501", phantom words). Both checks are required before calling `transcribeAsync()`:
1. **Energy check**: RMS > 0.003 (or equivalent `hasSpeech()` probability check)
2. **VAD check**: `sileroVAD?.containsSpeech()` if VAD is loaded

Pattern: any code path in `StreamingTranscriber` that calls `transcribeAsync()` without first checking both conditions. VAD is optional (`vad != nil`), but energy check is unconditional.

### AudioDevice Equality

**BUG-A03 (P1)**: `AudioDevice` equality must include both `uid` AND `id`. After sleep/wake, macOS can reassign runtime `AudioDeviceID` values — devices matched only on UID may map to the wrong hardware. Pattern: `AudioDevice` `Equatable` conformance that compares only `uid`. Fix: compare `uid && id`.

### Tap Format Direction

**BUG-A04 (P2)**: `inputNode.inputFormat(forBus:)` vs `inputNode.outputFormat(forBus:)` — these are NOT interchangeable. The tap format must match the actual data flow direction. Flag any change that switches between `inputFormat` and `outputFormat` on `inputNode` without a clear justification comment.

### Volume Save/Restore Correctness

**BUG-A05 (P1)**: Volume restore must skip channels that were at 0 volume before muting — do NOT save `0.0` volumes and do NOT use `1.0` as a "last resort" fallback. Pattern: any `newlySaved[element] = 1.0` fallback line in the mute/volume-saving code. A channel at 0 before muting must remain at 0 after unmuting. Fix: `guard volume > 0.001 else { continue }`.

**BUG-A06 (P1)**: `savedVolumes` dict and the boolean `isMutedByUs` flag must stay in sync — both must be reset together. Pattern: `isMutedByUs = false` without clearing `savedVolumes`/equivalent.

### Device Change Listener Completeness

**BUG-A07 (P1)**: Per-device HAL listener alone is insufficient — system-level `kAudioHardwarePropertyDefaultInputDevice` change events must also be monitored to handle device connect/disconnect (AirPods, USB audio, etc.). Pattern: `AudioObjectAddPropertyListener` registered for per-device scope only, with no `kAudioHardwarePropertyDefaultInputDevice` listener at the system scope.

### Startup Grace Period

The 1.5-second startup grace period (ignores `AVAudioEngineConfigurationChange` notifications during engine startup) must remain intact. Pattern: any removal or shortening of the startup grace window.

### Recovery Mutual Exclusion

**BUG-A09 (P1)**: Every audio engine recovery entry point must begin with `guard !isRecovering else { return }`. Recovery attempt counter must only be reset when confirmed non-silent audio is received (RMS > threshold for at least one callback). Flag: any `isRecovering = false` on the first audio callback regardless of content.

**BUG-A14 (P1)**: Recovery counter reset on silent callbacks — `consecutiveSilentCallbacks` must not be reset unless the current callback has RMS > threshold.

### Recovery Task Teardown Order

**BUG-A10 (P0)**: `recoveryTask?.cancel()` must be called BEFORE `cleanupEngineState()`. Pattern: any `cleanupEngineState()` call in `stopRecording()` or `teardown()` that is not immediately preceded by `recoveryTask?.cancel()`.

### Queue Buildup

**BUG-A11 (P1)**: Serial lifecycle queue (`lifecycleQueue` or equivalent) that receives blocking configure tasks: any new `configure()` call must create a fresh serial queue, replacing the old one (which may be blocked). A 15-second watchdog must exist for `recorderState` stuck in `.starting`. Pattern: `lifecycleQueue.async { buildGraph() }` without queue replacement on retry.

### Silence Threshold Comparison

**BUG-A08 (P1)**: Any threshold-based silence counter MUST use `>=`, not `==`. Pattern: `if consecutiveSilentCallbacks == silenceThreshold`. The counter can be incremented past the threshold by a guard that fires during an increment — `==` would then permanently never trigger recovery.

### 5-Minute Recording Cap

The 4,800,000-sample (~5-minute, ~19MB at 16kHz mono Float32) cap must remain intact. Pattern: any change to `maxRecordingSamples` or the cap enforcement logic. Never remove this without implementing streaming-to-disk.

### Audio Format Requirements

All samples passed to `WhisperBridge.transcribe()` must be:
- Sample rate: 16,000 Hz
- Channels: 1 (mono)
- Format: Float32 (-1.0 to +1.0)

The `AVAudioConverter` from the system format (typically 48kHz stereo) must be applied before any whisper transcription call. Flag: any path where samples reach `transcribeAsync()` without format conversion.

### Tap Callback Zero-Allocation

The AVAudioEngine tap callback fires in a real-time audio thread. Pattern: any heap allocation (array creation, string formatting, class instantiation) inside the tap callback body. Acceptable: appending to a pre-allocated buffer, reading from atomic properties. Unacceptable: `Array(...)`, `String(...)`, `Logger.*` (string formatting allocates), `DispatchQueue.async` (allocates a work item).

### CoreML / ANE Serialization

**BUG-C06 (P0)**: Any `TranscriptionBackend` using CoreML (ANE) must await the previous model's `finish()` / `stop()` before starting the next inference. Pattern: `Task { model.finish() }` (fire-and-forget) followed by `model2.start()`. ANE access is not multiplexed — concurrent CoreML models corrupt each other's output.

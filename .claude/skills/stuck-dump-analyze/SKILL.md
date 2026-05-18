---
name: stuck-dump-analyze
description: >
  Analyzes Whisperer stuck-state dump files in ~/Library/Logs/Whisperer/
  to find the root cause when the HUD gets stuck in "Listening…", the recording
  waveform is flat (no audio flowing), or the recording state machine refuses to
  recover. Use when the user reports HUD stuck, "Listening forever", "recording
  won't stop", "can't dismiss overlay", "stuck in recording state", "app hung",
  "stale recording", "flat waveform", "no waveform", "same issue again", or pastes
  a log fragment containing -10877 / kAudioUnitErr_NoConnection / "Recording stalled"
  / "Stuck state dump written" / "consecutiveSilentCallbacks" / "Audio quality watchdog".
metadata:
  version: 2.0.0
  category: debug
  tags: [debug, audio, state-machine, recording, hud, audio-devices, memory]
---

# stuck-dump-analyze — Diagnose stuck/silent recording from auto-captured dumps

The Whisperer Debug build writes a full state snapshot to
`~/Library/Logs/Whisperer/stuck-<UTC-timestamp>.dump` on three triggers:
1. **Audio quality watchdog** — callbacks flowing but all-silent for 5s (broken audio pipeline, typically `-10877`)
2. **Recovery exhausted** — audio engine rebuilt N times, all produced silent/no audio
3. **Manual ladybug button** — user clicked the ladybug icon in the recording HUD

Each dump is the definitive evidence. Read it before guessing.

## When to invoke

Trigger automatically when the user mentions any of:

- "HUD stuck" / "HUD won't dismiss" / "overlay stuck"
- "Listening… stuck" / "Listening forever" / "stuck on listening"
- "Recording won't stop" / "stuck in recording" / "can't stop recording"
- "App hung" / "app stale" / "app frozen"
- "Flat waveform" / "no waveform" / "not picking up audio" / "silent recording"
- "Same issue again" (after a prior stuck-HUD or silent-audio report)
- Any log fragment containing: `-10877`, `kAudioUnitErr_NoConnection`,
  `Recording stalled`, `Stuck state dump written`, `Audio recovery exhausted`,
  `consecutiveSilentCallbacks`, `Audio quality watchdog`

## Procedure

1. List dumps newest-first:
   ```bash
   ls -lt ~/Library/Logs/Whisperer/stuck-*.dump 2>/dev/null | head
   ```
2. Read the most recent dump file in full.
3. Extract the **three definitive state fields** and flag any disagreement:
   - `AppState.state` (expected `.recording` during a stuck or silent incident)
   - `AudioRecorder.recorderState` (`.recording` / `.recovering` / `.idle` / `.starting` / `.stopping`)
   - `AudioRecorder` `audioEngine.isRunning` (true / false)
4. Check **amplitude timing** (audio quality watchdog fields):
   - `lastAmplitudeUpdateTime` — when the last audio callback fired (Δ shows staleness)
   - `lastNonSilentAmplitudeTime` — when last non-silent sample arrived; `nil` = ALL callbacks returned zero-filled buffers from recording start
   - `hasTriggeredSilentAudioDump` — true if the quality watchdog fired (silent-audio path)
   - Pattern: `lastAmplitudeUpdateTime` recent + `lastNonSilentAmplitudeTime` nil/stale = broken audio pipeline (likely `-10877`)
5. Check **AudioRecorder error state**:
   - `lastEngineStartError` — the exact Swift error thrown when `AVAudioEngine.start()` failed, retained for the dump. `-10877` (kAudioUnitErr_NoConnection) here = AUHAL bus not connected, typically caused by device enumeration race during engine creation.
   - `recoveryAttemptCount` — how many times the engine was rebuilt this session
6. Inspect **Audio Devices** section:
   - Find the device marked `← default` — this is what CoreAudio thinks is the system input
   - Check `alive=true/false` on that device — `alive=false` = CoreAudio considers it dead
   - Check for `[INPUT]` tag on the expected microphone — absence means the device has no input streams visible to CoreAudio at dump time
   - Cross-reference `engineDeviceID` (from AudioRecorder section) vs the `← default` device ID — mismatch = engine bound to a device that's no longer default
   - Transport type anomalies: `Virtual` or `Aggregate` on the default input can cause routing instability
   - If `-10877` was thrown: look for a device that WAS the default at engine start but is now gone or has `alive=false`
7. Inspect **Memory Usage** section:
   - `process.physFootprint` — actual RAM committed (physical footprint). Compare against available RAM. >4GB on a 16GB machine = memory pressure likely.
   - `whisper.mainModel` — confirms which model binary is loaded and file size on disk
   - `coreMLEncoder` — `present`/`absent` for the encoder `.mlmodelc`. Absence on a model that should have ANE = encoder not downloaded.
   - `whisper.tinyBridge` — tiny preview bridge status and whether it's loaded in the pool
   - `modelPool.previewBridge` / `modelPool.fallbackProfile` — confirm ModelPool state
   - `sileroVAD` — loaded or nil
   - `llm.*` — if LLM is enabled and loaded, it consumes significant RAM (0.4–5.5GB depending on variant). High physFootprint + large LLM = likely memory pressure contributing to audio failures
8. Inspect the **Thread Sample** section. Classify what the main thread is doing:
   - Idle in `nextEventMatchingMask` → state-machine leak (no work running)
   - Blocked in `engine.start` / `AVAudio*` / CoreAudio → CoreAudio hang
   - Blocked on a lock / semaphore → deadlock; name the lock
   - Spinning in SwiftUI body re-evaluation → render loop
9. Inspect **Recent Logs (last 200 lines)** for the trigger sequence in the
   ~10 seconds before the dump timestamp. Search for:
   - `throwing -10877` / `kAudioUnitErr_NoConnection`
   - `Audio recovery exhausted`
   - `Mid-recording recovery attempt`
   - `AVAudioEngineConfigurationChange`
   - `consecutiveSilentCallbacks`
   - `StartupFailure`
   - `Audio quality watchdog` (new — confirms silent-audio dump trigger)
10. Report the diagnosis using the format below. Cite the specific dump field
    or log line that supports each conclusion. Do not propose fixes without evidence.

## Output format

```
## Stuck-Dump Analysis

**Dump:** `<filename>` (<file size>, pid <pid>)

**Trigger:** <one-line summary derived from dump reason + log section>

**State at freeze:**
- AppState.state = <value>
- AudioRecorder.recorderState = <value>
- audioEngine.isRunning = <true|false>
- lastEngineStartError = <error or "nil">
- lastAmplitudeUpdateTime = <Δ ago>
- lastNonSilentAmplitudeTime = <Δ ago or "nil — all buffers zero-filled">
- Discrepancy: <yes/no — describe if yes>

**Audio device analysis:**
- System default input: id=<X> name=<Y> alive=<true|false> transport=<Z>
- engineDeviceID: <matches default? yes/no>
- Input-capable devices: <list names or count>
- Anomalies: <dead device, transport mismatch, no input devices, or "none">

**Memory analysis:**
- physFootprint: <X MB/GB>
- Main model: <name> (<size>) coreML=<present|absent>
- LLM loaded: <yes/no — variant and disk size if yes>
- Memory pressure: <yes/no — reasoning>

**Thread analysis:** <where main thread sat; any blocked background threads>

**Root cause:** <evidence-backed conclusion citing dump fields / log lines>

**Recommended fix:** <only what evidence supports; cite the specific gap>
```

## Common patterns

### Pattern: -10877 zero-filled buffers
- Trigger: "Audio quality watchdog: callbacks flowing but all silent for Xs"
- `lastNonSilentAmplitudeTime: nil` (never received non-silent audio)
- `lastEngineStartError` may or may not be set (error is often logged but lost before dump)
- Audio Devices: look for the expected mic with `alive=false` or missing `[INPUT]`
- Fix direction: understand WHICH device was used vs WHICH is now alive; the engine was likely bound to a stale device ID

### Pattern: State machine stuck (true HUD freeze)
- Trigger: "Recording stalled — no audio buffers for 15s"
- `lastAmplitudeUpdateTime` stale by 15s+
- `audioEngine.isRunning = false` while `recorderState = .recording`
- `hasTriggeredSilentAudioDump = false` (watchdog fired on no-callbacks, not silent-callbacks path)

### Pattern: Recovery exhausted
- Trigger: "Audio recovery exhausted — engine rebuilt N times, all produced silent/no audio"
- `recoveryAttemptCount` >= 3
- Each recovery attempt rebuilt the engine but `-10877` recurred
- Check Audio Devices: if the default device keeps changing during recording (AVAudioEngineConfigurationChange), the engine binds to a different device each time

### Pattern: Memory pressure causing audio instability
- `process.physFootprint` > 8GB
- Large LLM loaded (9B = ~5.5GB on disk, more in RAM with MLX activation)
- macOS audio daemon under memory pressure can produce zero-filled buffers
- Fix direction: add memory pressure check before engine start; unload LLM during recording

## When no dumps exist

If no `stuck-*.dump` files exist in `~/Library/Logs/Whisperer/`:

- The build is probably Release (dumper is `#if DEBUG`) — ask the user to reproduce in a Debug build.
- Or the watchdog hasn't fired yet — the audio quality watchdog triggers after 5s of silent audio while callbacks are flowing; the state-machine watchdog triggers after 15s with no callbacks.
- The user can manually trigger a dump by clicking the ladybug icon in Diagnostics settings (menu bar → Settings → Diagnostics, DEBUG only).
- As a fallback, offer to inspect today's `whisperer-YYYY-MM-DD.log` in `~/Library/Logs/Whisperer/` and the live process via `sample <pid>`.

## Notes

- Three dump triggers: (1) `startRecordingWatchdog()` → silent-audio path (5s no non-silent callbacks); (2) `startRecordingWatchdog()` → stall path (15s no callbacks at all); (3) `handleAudioFlowTimeout()` → recovery exhausted; (4) manual ladybug button in Diagnostics settings (menu bar → Settings → Diagnostics).
- The quality watchdog fires ONCE per session (`hasTriggeredSilentAudioDump` flag) to avoid spam.
- A state-machine stuck dump is followed by `forceIdleFromWatchdog()` → app recovers to `.idle` before the user sees the file.
- Never delete dump files unless the user explicitly asks — they are the primary record.
- `lastEngineStartError` is only populated in DEBUG builds and only when `AVAudioEngine.start()` throws. If the error was `-10877` during engine construction (not start), it may appear only in logs.

---
name: stuck-dump-analyze
description: >
  Analyzes Whisperer stuck-state dump files in ~/Library/Logs/Whisperer/stuck-dumps/
  to find the root cause when the HUD gets stuck in "Listening…" or the recording
  state machine refuses to recover. Use when the user reports HUD stuck, "Listening
  forever", "recording won't stop", "can't dismiss overlay", "stuck in recording
  state", "app hung", "stale recording", "same issue again", or pastes a log
  fragment containing -10877 / kAudioUnitErr_NoConnection / "Recording stalled" /
  "Stuck state dump written".
metadata:
  version: 1.0.0
  category: debug
  tags: [debug, audio, state-machine, recording, hud]
---

# stuck-dump-analyze — Diagnose stuck recording HUD from auto-captured dumps

The Whisperer Debug build writes a full state snapshot to
`~/Library/Logs/Whisperer/stuck-dumps/stuck-<UTC-timestamp>.txt` every time
the audio-progress watchdog detects a stuck `.recording` state. Each dump is
the definitive evidence for that incident. Read it before guessing.

## When to invoke

Trigger automatically when the user mentions any of:

- "HUD stuck" / "HUD won't dismiss" / "overlay stuck"
- "Listening… stuck" / "Listening forever" / "stuck on listening"
- "Recording won't stop" / "stuck in recording" / "can't stop recording"
- "App hung" / "app stale" / "app frozen"
- "Same issue again" (after a prior stuck-HUD report)
- Any log fragment containing: `-10877`, `kAudioUnitErr_NoConnection`,
  `Recording stalled`, `Stuck state dump written`, `Audio recovery exhausted`

## Procedure

1. List dumps newest-first:
   ```bash
   ls -lt ~/Library/Logs/Whisperer/stuck-dumps/ 2>/dev/null | head
   ```
2. Read the most recent dump file in full.
3. Extract the **three definitive fields** and flag any disagreement:
   - `AppState.state` (expected `.recording` if HUD was stuck)
   - `AudioRecorder.recorderState` (`.recording` / `.recovering` / `.idle` / `.starting` / `.stopping`)
   - `AudioRecorder` `audioEngine.isRunning` (true / false)
4. Inspect the **Thread Sample** section. Classify what the main thread is
   doing at the moment of capture:
   - Idle in `nextEventMatchingMask` → state-machine leak (no work running)
   - Blocked in `engine.start` / `AVAudio*` / CoreAudio → CoreAudio hang
   - Blocked on a lock / semaphore → deadlock; name the lock
   - Spinning in SwiftUI body re-evaluation → render loop
5. Inspect **Recent Logs (last 200 lines)** for the trigger sequence in the
   ~10 seconds before the dump timestamp. Search for:
   - `throwing -10877`
   - `Audio recovery exhausted`
   - `Mid-recording recovery attempt`
   - `AVAudioEngineConfigurationChange`
   - `consecutiveSilentCallbacks`
   - `StartupFailure`
6. Report the diagnosis using the format below. Cite the specific dump field
   or log line that supports each conclusion. Do not propose fixes without
   evidence.

## Output format

```
## Stuck-Dump Analysis

**Dump:** `<filename>` (<file size>, pid <pid>)

**Trigger:** <one-line summary derived from log section>

**State at freeze:**
- AppState.state = <value>
- AudioRecorder.recorderState = <value>
- audioEngine.isRunning = <true|false>
- Discrepancy: <yes/no — describe if yes>

**Thread analysis:** <where main thread sat; any blocked background threads>

**Root cause:** <evidence-backed conclusion citing dump fields / log lines>

**Recommended fix:** <only what evidence supports; cite the specific gap>
```

## When no dumps exist

If `~/Library/Logs/Whisperer/stuck-dumps/` is empty or absent:

- The build is probably Release (dumper is `#if DEBUG`) — ask the user to
  reproduce in a Debug build.
- Or the watchdog hasn't fired yet — ask the user to reproduce and wait the
  full 15s after the freeze before grabbing the file.
- As a fallback, offer to inspect today's `whisperer-YYYY-MM-DD.log` in
  `~/Library/Logs/Whisperer/` and the live process via `sample <pid>`.

## Notes

- The dumper is wired in `AppState.startRecordingWatchdog()` →
  `handleStuckRecording(reason:)` → `StuckStateDumper.dump(reason:)`.
- A dump is followed automatically by `forceIdleFromWatchdog()`, so by the
  time the user reads the file the app has already recovered to `.idle`.
- Never delete dump files unless the user explicitly asks — they are the
  primary record of stuck-state incidents.

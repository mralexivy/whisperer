---
name: stuck-dump-analyze
description: >
  Analyzes Whisperer stall dump files in ~/Library/Logs/Whisperer/
  to find the root cause when the HUD gets stuck in "Listening…", the recording
  waveform is flat (no audio flowing), transcription stalls, or the recording
  state machine refuses to recover. Use when the user reports HUD stuck,
  "Listening forever", "recording won't stop", "can't dismiss overlay",
  "stuck in recording state", "app hung", "stale recording", "flat waveform",
  "no waveform", "same issue again", or pastes a log fragment containing
  -10877 / kAudioUnitErr_NoConnection / "Recording stalled" / "stall-latest.dump"
  / "⚠️ Stall:" / "ROOT CAUSE:" / "consecutiveSilentCallbacks" / "Audio quality watchdog".
metadata:
  version: 3.0.0
  category: debug
  tags: [debug, audio, state-machine, recording, hud, audio-devices, memory, health-manager]
---

# stuck-dump-analyze — Diagnose stalls from health-manager dump files

Whisperer writes a full state snapshot on any significant stall (Debug **and** Release builds):
- `~/Library/Logs/Whisperer/stall-latest.dump` — always overwritten by the most recent stall
- `~/Library/Logs/Whisperer/history/stall-<UTC-timestamp>.dump` — capped at 10 files, written only on critical threshold breach (>10s stall)

Dumps are triggered by HealthManager when a component exceeds its critical threshold (10s). Format v2, structured sections.

## When to invoke

Trigger automatically when the user mentions any of:
- "HUD stuck" / "HUD won't dismiss" / "overlay stuck"
- "Listening… stuck" / "Listening forever" / "stuck on listening"
- "Recording won't stop" / "stuck in recording" / "can't stop recording"
- "App hung" / "app stale" / "app frozen"
- "Flat waveform" / "no waveform" / "not picking up audio" / "silent recording"
- "Transcription stalled" / "stuck transcribing"
- "Same issue again" (after a prior stuck-HUD or silent-audio report)
- Any log fragment containing: `-10877`, `kAudioUnitErr_NoConnection`,
  `⚠️ Stall:`, `ROOT CAUSE:`, `stall-latest.dump`, `Recording stalled`,
  `Audio recovery exhausted`, `consecutiveSilentCallbacks`, `Audio quality watchdog`

## Procedure

1. Check for dump files:
   ```bash
   ls -lt ~/Library/Logs/Whisperer/stall-latest.dump ~/Library/Logs/Whisperer/history/stall-*.dump 2>/dev/null | head
   ```
2. **Check the dump format version** (line 1 of any dump):
   - `Format: v2` — use this procedure
   - Older `# Whisperer Stuck-State Dump` without Format line — use legacy analysis (check dump fields for AppState, AudioRecorder, Thread Sample directly)
3. Read `stall-latest.dump` in full.
4. **Read the versioned header first** — `Reason:` field names what triggered the dump.
5. **Read Component Health section** — find which component is `.stalled` vs `.busy`.
6. **Read the Dependency Chain** in the Reason or stall log line — identifies ROOT CAUSE automatically:
   ```
   ROOT CAUSE: AudioRecorder → WhisperBridge (waiting) → StreamingTranscriber (waiting)
   ```
   The leftmost component with no dependencies is the root cause.
7. **Read Health Timeline** — reconstructs the degradation sequence (status transitions with timestamps).
8. **Read Ring Buffer Events** — the last 200 events with relative timestamps (`+12.3s`). Look for:
   - The last event before the stall (what was happening?)
   - Whether `audioProgressCounter` stopped incrementing (audio stalled)
   - `skipNonSpeech` events (whisper got audio but discarded it as noise)
   - `chunkQueued` → no `transcribeStarted` (chunk queued but Whisper never ran)
9. **Read AppState section** — cross-check state machine fields:
   - `state` (expected `.recording` during stuck incident)
   - `streamingTranscriber: alive/nil`
   - `liveTranscription` — char count shows whether text was flowing
10. **Read AudioRecorder section** — check:
    - `recorderState` — `.recording` / `.recovering` / `.idle`
    - `audioEngine.isRunning` — true/false
    - `lastEngineStartError` — `-10877` = AUHAL bus failure
    - `recoveryAttemptCount` — if ≥3, recovery exhausted
    - `lastAmplitudeUpdateTime` / `lastNonSilentAmplitudeTime`
11. **Read System Snapshot section** — focused summary:
    - `Focused app` — where text injection was targeted
    - `AX permission` — relevant if TextInjector is the stalled component
    - `Recording: Xs elapsed` — how long recording ran before dump
    - `Audio device` — what mic was in use
    - `Model` + CoreML status
    - `Tiny bridge` / `VAD` / `LLM` loaded state
12. **Read Audio Devices section** — if AudioRecorder is stalled:
    - Find `← default` device — what CoreAudio thinks is system input
    - Check `alive=true/false` — false = CoreAudio considers device dead
    - Check `[INPUT]` tag — absence = no input streams
    - Cross-ref `engineDeviceID` vs default device ID — mismatch = bound to dead device
13. **Read Thread Sample** (Debug builds only) — classify main thread:
    - `nextEventMatchingMask` → state-machine leak (no work running)
    - Blocked in `AVAudio*` / CoreAudio → CoreAudio hang
    - Blocked on SafeLock / `withLock` → deadlock in whisper pipeline
    - Spinning in SwiftUI → render loop
14. **Read Recent Logs** — look for the trigger sequence in the ~10s before dump:
    - `throwing -10877` / `kAudioUnitErr_NoConnection`
    - `Audio recovery exhausted`
    - `Mid-recording recovery attempt`
    - `AVAudioEngineConfigurationChange`
    - `consecutiveSilentCallbacks`
    - `⚠️ Stall:` lines (the HealthManager alert that preceded the dump)

## Output format

```
## Stall-Dump Analysis

**Dump:** `stall-latest.dump` (or history file, <file size>)
**Format:** v2
**Trigger:** <one-line from Reason: header field>
**Timestamp:** <from header>

**Component Health at dump:**
- ROOT CAUSE: <component from dependency chain>
- <component>: stalled  op=#<id>.<name>  seq=<N>  elapsed=<Xs>
- <component>: busy  waitingOn=<stalled component>
- <component>: healthy

**Health Timeline (key transitions):**
- +Xs  <component>  healthy → busy
- +Xs  <component>  busy → stalled

**Ring Buffer — last events before stall:**
- +Xs  <component>  <operation>  [<kind>]  <metadata>
  ...

**State at freeze (AppState/AudioRecorder):**
- AppState.state = <value>
- AudioRecorder.recorderState = <value>
- audioEngine.isRunning = <true|false>
- lastEngineStartError = <error or "nil">
- lastAmplitudeUpdateTime = <Δ ago>
- lastNonSilentAmplitudeTime = <Δ ago or "nil — all buffers zero-filled">

**System Snapshot:**
- Memory: <X MB>
- Audio device: <name>
- Model: <name>  CoreML: <present|absent>

**Audio device analysis:** (only if AudioRecorder is root cause)
- System default input: id=<X> name=<Y> alive=<true|false>
- engineDeviceID: <matches default? yes/no>
- Anomalies: <describe or "none">

**Thread analysis:** (Debug builds only)
<where main thread sat; any blocked background threads>

**Root cause:** <evidence-backed conclusion citing specific dump sections/fields>

**Recommended fix:** <only what evidence supports>
```

## Common patterns

### Pattern: AudioRecorder stall (audio pipeline failure)
- `ROOT CAUSE: AudioRecorder` in dependency chain
- WhisperBridge status: `busy` or `healthy` (waiting for audio it never gets)
- Ring buffer: `audioProgressCounter` not incrementing in ring buffer events
- AppState: `lastAmplitudeUpdateTime` stale, `lastNonSilentAmplitudeTime` nil
- Audio Devices: likely `alive=false` on default device or missing `[INPUT]`
- Pattern: `-10877` zero-filled buffers or engine never started

### Pattern: WhisperBridge stall (GPU/Metal hang)
- `ROOT CAUSE: WhisperBridge`
- Ring buffer shows `transcribeStarted` but no subsequent `skipNonSpeech` or segment events
- Health timeline: WhisperBridge went `healthy → busy → stalled`
- Thread sample: background thread blocked in `whisper_full` or `ctxLock.withLock`
- StreamingTranscriber shows `.busy` with `waitingOn=WhisperBridge`

### Pattern: StreamingTranscriber stall (chunk backlog)
- `ROOT CAUSE: StreamingTranscriber`
- Ring buffer: many `chunkQueued` events, `backlog` counter growing
- WhisperBridge is healthy (processing) but chunks accumulate faster than they finish
- Typically not a true stall — WhisperBridge will eventually catch up

### Pattern: Main thread hang
- Dump Reason: "Main thread unresponsive for X.Xs"
- Thread sample: main thread blocked in AX calls, NSWorkspace, or AppKit
- All components show `healthy` (they're fine — main thread can't run the run loop)
- TextInjector is likely the cause if `status=busy` at time of hang

### Pattern: -10877 zero-filled buffers
- Trigger: silent-audio path (callbacks flowing but all zero for 5s+)
- Ring buffer: `audioProgressCounter` incrementing but amplitude near zero
- `lastNonSilentAmplitudeTime: nil`
- Audio Devices: mic has `[INPUT]` but `alive=false` or wrong transport
- AudioRecorder `lastEngineStartError`: `-10877`

### Pattern: Recovery exhausted
- Trigger: "Audio recovery exhausted — engine rebuilt N times"
- `recoveryAttemptCount` ≥ 3
- Audio Devices: default device kept changing (AVAudioEngineConfigurationChange loop)

## When no dumps exist

If `stall-latest.dump` does not exist in `~/Library/Logs/Whisperer/`:
- In v3+ (HealthManager era), dumps are written in **Release AND Debug builds** once a component stalls for >10s. Absence means:
  - The stall resolved within 10s (HealthManager didn't trigger critical threshold)
  - Or the app crashed before HealthManager could write the dump (check Console for crash reports)
- Look for `⚠️ Stall:` lines in the app log (`~/Library/Logs/Whisperer/whisperer-YYYY-MM-DD.log`) — these appear at the 5s warn threshold, before the 10s critical dump
- As fallback: `sample <pid>` for a live thread sample, or inspect the log file directly

## Notes

- Dump triggers (v2): HealthManager detects `ComponentStatus.stalled` for >10s → calls `StuckStateDumper.dump(reason:)` from any build config (not just DEBUG)
- The ring buffer captures up to 4096 events with relative timestamps. Events older than the ring capacity are lost. If an incident is old, the ring may contain only post-stall events.
- `stall-latest.dump` is overwritten on every stall — always grab it immediately after reproducing
- `history/` files are only written on critical breach (>10s) — warn-level stalls (5s) only produce a log line, not a dump file
- Do not delete dump files unless the user explicitly asks — they are the primary record
- `lastEngineStartError` in AudioRecorder section is only populated in DEBUG builds when `AVAudioEngine.start()` throws; Release builds may not have it

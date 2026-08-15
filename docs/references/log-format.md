# Log Format Reference

## File format

```
#fmt whisperer/2  off lvl sub evt k=v…
#lvl D I W E C   #sub app aud trn ui key txt prm mdl
#evt <area>.<verb>   #×N = N suppressed repeats   #warn+ carry @file:line
#t 2026-08-14T17:38:02.869+03:00
app.boot v=1.1/6 devs=4 mic=default hotkey=Fn mcp=8080 dict=3518 crashed=0
+12.4 E app mcp.listen err=NWError.61 @WhispererMCPServer.swift:117

>ses 7 dictation route=default backend=whisper lang=en
+0.070 I aud rec.start gen=15
+0.105 D aud audio.first
+8.650 I key shortcut.release
+8.951 I trn asr.done chars=88 words=16 lang=en
+10.93 I txt inject.ok via=clipboard ms=132
<ses 7 ok dur=8.9 chars=88 warn=0 err=0
```

Fields:
- **off** — seconds since session open (`>ses`), or since `#t` anchor outside a session
- **lvl** — D/I/W/E/C (debug/info/warning/error/critical)
- **sub** — subsystem code (see `#sub` legend)
- **evt** — stable event code from `LogEvent` namespace
- **k=v** — structured key-value pairs; values with spaces are quoted

## Event codes (LogEvent namespace)

| Code | Subsystem | Meaning |
|------|-----------|---------|
| `rec.start` | aud | Recording began |
| `rec.stop` | aud / trn | Recording stopped cleanly |
| `rec.fail` | aud | Recording failed to start or was aborted |
| `audio.first` | aud | First audio buffer received |
| `eng.build` | aud | Audio engine graph built |
| `eng.tap` | aud | Input tap installed |
| `eng.retry` | aud | Engine start retried |
| `eng.config_change` | aud | Audio engine configuration changed |
| `dev.change` | aud | Selected input device changed |
| `dev.fail` | aud | Device change failed |
| `asr.start` | trn | Transcription pass started |
| `asr.done` | trn | Transcription pass completed |
| `asr.fail` | trn | Transcription pass failed or empty |
| `model.load` | mdl | Whisper model loaded |
| `model.free` | mdl | Whisper model freed |
| `app.boot` | app | Application launched |
| `app.crash` | app | Previous session crashed |

## Session blocks

`>ses N <mode> [k=v…]` opens a block; `<ses N ok …` or `<ses N FAIL at=<evt> err=<code>` closes it.

On `FAIL`, the verdict line is followed by the `EventRingBuffer` snapshot (last 60 events in packed format), so every step demoted to `Logger.step()` is recoverable in the dump even though it never appears in the rolling log.

## APIs

```swift
// Write to file + os_log (use for deviations and outcomes)
Logger.event(.recStart, .audio, ["gen": .int(15), "route": .string("default")])

// Write to ring buffer + os_log only, never to file (use for narration)
Logger.step(.engTap, .audio, ["buf": .int(4096)])

// Redact user speech (gate: logShowTranscripts UserDefaults key)
Logger.redact(transcriptText)  // returns "‹92c/16w›" when gate is off
```

## Subsystem codes

| Code | Name |
|------|------|
| app | .app |
| aud | .audio |
| trn | .transcription |
| ui  | .ui |
| key | .keyListener |
| txt | .textInjection |
| prm | .permissions |
| mdl | .model |

# Logging — Rules

## R1: A log line must distinguish two different outcomes

If the same text always appears regardless of what happened, it is narration, not evidence.
Narration goes to `Logger.step()` (ring buffer + os_log, never file). Outcomes and deviations go to `Logger.event()` (file + os_log).

## R2: event() vs step() — the split

| API | File | os_log | Ring buffer | Use for |
|-----|------|--------|-------------|---------|
| `Logger.event()` | ✓ | ✓ | — | Deviations, failures, outcomes with measured values |
| `Logger.step()` | — | ✓ | ✓ | Narration of steps that always succeed |
| `Logger.redact()` | — | — | — | Wraps user speech before any Logger call |

## R3: Never log speech without redaction

Wrap any string derived from user speech with `Logger.redact()`. This returns `‹Nc/Nw›` unless `logShowTranscripts` UserDefaults key is `true`. Never log filenames whose names are derived from speech.

## R4: Crash traces go to crash.log only

`CrashHandler` emits one `app.crash` record (a single line with signal, frame count, and crash.log path) to the rolling log. The full backtrace goes to `crash.log` only. Never duplicate the full trace into the rolling log — at 14,044 lines/day it was 55% of the total volume.

## R5: Boot narration → step()

32+ near-identical lines per launch reporting that things which cannot fail didn't. Replace the block with one `app.boot` record (version, device count, hotkey, MCP port, dict size, crash flag). Individual steps go to `Logger.step()`.

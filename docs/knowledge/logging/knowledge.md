# Logging — Knowledge

## Measured volume (2026-08-14 session log, ~30 dictations)

| Category | Lines | % |
|---|---:|---:|
| Crash backtraces (duplicated) | 14,044 | 55% |
| Launch banner + blanks | 2,191 | 9% |
| MCP per-connection debug | 1,054 | 4% |
| Audio device re-enumeration | 847 | 3% |
| LLM/MTP per-generation internals | 708 | 3% |
| Nemotron partials | 616 | 2% |
| Boot narration | ~4,000 | 16% |
| Useful (deviations + outcomes) | ~1,000 | 4% |

Measured total: 2.9 MB / 25,446 lines/day for ~30 dictations. Target after cleanup: under 400 lines/day.

## Format: packed k=v with session blocks

```
#fmt whisperer/2  off lvl sub evt k=v…
>ses N dictation backend=whisper lang=en
+0.070 I aud rec.start gen=15
+8.951 I trn asr.done chars=88 words=16
<ses N ok dur=8.9 chars=88 warn=0 err=0
```

- Stable event codes (e.g. `rec.start`, `asr.done`) — greppable, countable
- Offsets relative to session open — `#t` anchors absolute time once per block
- `<ses N FAIL at=… err=…` verdict + ring-buffer dump on failure
- `file:line` on warn and above only

## Transcript leak sites

Six sites that write speech to disk (all closed as of the 2026-08-15 cleanup):
1. `AppState.swift` — final transcription and "Entering dictated text" → `Logger.step` + `Logger.redact()`
2. `AppState.swift` — LLM input/output → `Logger.step` + `Logger.redact()`
3. `StreamingTranscriber.swift` — "Recording copied to:" filename → `Logger.step` with no filename
4. `LLMPostProcessor.swift` — "MTP raw output" → `Logger.step` + `Logger.redact()`

Gate: `logShowTranscripts` UserDefaults key (default `false`) controls whether `Logger.redact()` shows or hides.

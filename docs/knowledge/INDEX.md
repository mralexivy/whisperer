# Knowledge Index

Domain folders are created on demand as insights emerge. Each folder contains:
- `knowledge.md` — facts and confirmed patterns
- `hypotheses.md` — need more data
- `rules.md` — confirmed, apply by default

## Domains

- [audio/](audio/knowledge.md) — Opus on macOS: which containers Core Audio can actually write, writing real Ogg `.opus` via swift-ogg (libogg/libopus), 16 kHz encoding, why a `.opus` reads back at 48 kHz and `AVAudioFile.read` won't convert for you, frame-exact seeking, crash-truncation survival, the CAF packet-table pad, retention and library compaction ordering ([rules](audio/rules.md))
- [ui/](ui/knowledge.md) — SwiftUI layout gotchas, AppKit (`NSViewRepresentable`) interop
- [transcription/](transcription/knowledge.md) — backend chunk cadence, audio-clock timestamps, silence detection ([rules](transcription/rules.md))
- [llm/](llm/knowledge.md) — on-device LLM prompting: output budgets, summary length, fabrication under conditional formats
- [meetings/](meetings/knowledge.md) — model contention at meeting stop, borrowed backends, LLM KV-cache warmups, session start races, orphaned CoreData rows, RAG index coalescing, post-stop transcript re-transcription (why a second decode beats an LLM rewrite), reading crash markers ([rules](meetings/rules.md), [hypotheses](meetings/hypotheses.md))
- [diarization/](diarization/knowledge.md) — Sortformer speaker attribution: accumulated-transcript diffing, finalized-vs-tentative timelines, burst release vs. speech timing, forced-backend lifecycle ([rules](diarization/rules.md))

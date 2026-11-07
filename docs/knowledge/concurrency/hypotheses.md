
- **`StreamingTranscriber` should be `nonisolated` with explicit main hops** (2026-11-06). Its
  detached VAD-scan / live-preview loops (~lines 1404–1476) call main-isolated
  `scanAndProcessChunks()` / `runLivePreviewPass()` and read `previewBridge`, `routeDecision`,
  `modelPool`, `languageRouter`, `modelRouter`, `nemotronIsPreviewOnly` unlocked while main writes
  them — the last 9 isolation warnings in the app. Untested: making the class nonisolated changes
  where every bare `Task {}` inside it runs; each needs auditing first.
- **The audio tap thread reads main-actor `AppState` fields unsynchronised** (2026-11-06):
  `onStreamingSamples` closures in `AppState` (~3888, ~4411) read `isMicMuted`, `isPaused`,
  `streamingTranscriber`, `interludeTranscriber`. The compiler does not flag it. Candidate fix:
  a lock-protected sink object main updates and the audio thread reads.

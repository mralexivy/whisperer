# Meetings — Rules (apply by default)

1. **Guard the whole async start, not the final state flag.** If a start method awaits before setting
   `isRecording` / `isActive` / etc., add a separate in-flight flag set on the first line and cleared in
   `defer`. Re-check the state flag after every long await. Any CoreData row created before the flag is
   set becomes an orphan that surfaces as "crash recovery".

2. **Destructive rebuilds must be coalesced at the owner, not the caller.** `MeetingRAGEngine.index()`
   deletes the `.wax` and closes the cached `Memory`. Concurrency control belongs in the actor that owns
   the file. Never rely on callers checking `isIndexed()` — a filesystem-existence check is false for the
   whole build window.
   *Historical — engine removed. See Rule 31.*

3. **When joining an in-flight build, loop — don't `if`.** Multiple waiters resume non-deterministically
   and a later one may already have installed its own task:
   ```swift
   while let inFlight = indexingTasks[id] { _ = try? await inFlight.value }
   ```
   *Historical — engine removed. See Rule 31.*

4. **Track what an index was built from.** Store the segment count alongside the handle so a joiner can
   tell "already covered" from "the running build predates my segments" — otherwise a small early build
   masks the full post-finalize one.
   *Historical — engine removed. See Rule 31.*

5. **Before calling a session a crash, look for the clean-exit lines in the previous session's log.**
   `code 9: killed` from Xcode leaves the crash marker behind and produces a false
   `Previous session crashed!` on next launch.

6. **Speaker names are printed per turn, not per segment.** `SelectableTranscriptView` emits the
   speaker paragraph only when `speakerIndex`/`speakerName` differ from the previous segment; a
   continuation card opens its own gap via `bodyStyle.paragraphSpacingBefore = groupedSegmentSpacing`.
   `speakerRanges` stays index-parallel with `segments` (`NSNotFound` = no line) — the metrics loop
   indexes all three arrays by position, so never `continue`/skip an append in the builder. Continuation
   cards fall back to `speakerY = cardTop - 1`, which keeps the hover region and the accessory row
   (`offset(y: speakerY - 3)`) anchored to the card edge instead of collapsing to zero. The live bubble
   applies the same rule against `segments.last`.

7. **Every heavy, deferrable model job goes through `ModelWorkQueue`.** ASR loads, LLM loads, Sortformer
   download/warm-up, RAG indexing. Never a blind `Task.sleep` to "let the other load finish" — that was
   `launchGraceSeconds` and it coordinated nothing. What must **not** be queued: live ASR, live
   diarizer `feed()`, and interactive dictation post-processing. Those are the latency path.

8. **A gate raised on one code path must be lowered from a `defer` on every exit of the other.**
   `setMeetingActive(false)` lives in a `defer` at the *top* of `stopInAppRecording()`'s Task, because
   the watchdog bail-out (`guard case .stopping = state else { return }`) returns before the end of the
   Task. `cancelRecording()` lowers it separately — it never reaches `stopInAppRecording()` at all. A
   stranded gate suspends background model work for the rest of the app session.
   Correspondingly, raise it only after the work actually started: `startInAppRecording()` bails out
   early when no backend is ready, so the raise is guarded on `if case .recording = state`.

9. **Meetings borrow a backend; they never write `selectedBackendType`.** Use `meetingOwnsNemotron` +
   `effectiveInAppBackend`. A `selectBackend()` round trip costs a full teardown and reload in each
   direction and persists to UserDefaults, so a crash mid-meeting leaves the user on a backend they
   never chose. Anything that tears down or cancels a load (`releaseCurrentBridge()`) must check the
   ownership flag first.

10. **Do not warm an LLM KV cache for a prompt that will never repeat.** The warmup contends for the
    same `ModelContainer` lock as the generation it is meant to help. One-shot prompts —
    anything with retrieved context or per-meeting content embedded in the system prompt — pass
    `reuseWarmCache: false`. Repeated prompts (dictation post-processing) keep it.
    Amendment: what matters is whether the prefix **repeats**, not whether it is per-meeting. A
    whole-transcript system prompt is per-meeting AND repeats across every question in that meeting —
    it should be cached. A one-shot prompt (title, overview) should not.

11. **A warning that fires on every retry needs a latch.** `CameraUsageMonitor.start()` logged the same
    "no CMIO devices" line 16× in one session because the monitor restarts on every device change.
    Latch with a `hasLoggedUnavailable` flag, reset when the condition clears. Likewise, only warn about
    an empty transcript when it is actually anomalous (`!segments.isEmpty || elapsedSeconds >= 2`) —
    otherwise a two-second accidental recording reads as a bug.

12. **Never mutate `segments` for progress.** The transcript is one `NSTextView`, and any
    content-signature change rebuilds the entire text storage and clears an in-progress selection. A
    background pass that rewrites text (polish, translation, re-diarization) shows progress with
    overlays computed from the published `segmentMetrics` — free, no text-storage work — and commits
    the new array **once** at the end. Persist per batch anyway, so a quit mid-run loses one batch,
    not the run.

13. **A "covered count" cache is wrong for any pass that rewrites text.** `MeetingRAGEngine.index`
    early-returns on `indexedSegmentCounts[id] >= segments.count`. Polishing changes text but not
    count, so the re-index is silently skipped and Ask AI keeps searching the raw text. Pass `force:`.
    Anything that defers an index (`finalizeSession(deferIndexing:)`) owes exactly one forced index on
    **every** exit of the deferring pass — success, failure, and cancellation.
    *Historical — engine removed. See Rule 31.*

14. **Batch size is set by the generation guards, not by taste.** `LLMPostProcessor`'s output-length
    guard is armed only when `maxTokensCap <= 256`; raising the cap to fit a bigger batch silently
    disarms the runaway-output guard. Size the batch to the cap instead. And pass an explicit
    `outputTokensHint` for Cyrillic or Greek — `containsNonLatinScript` doesn't cover them, so the
    built-in `chars/4` estimate truncates Russian mid-word.

15. **`TranscriptPreCleaner.protectTokens` restarts its counter at 0 on every call.** Protect a
    multi-line payload once, as a whole. Per-line protection reuses `__URL_0__` for two different URLs
    inside one request, and `restorePlaceholders` then swaps in the wrong one.

16. **RTL/layout decisions must sample the text actually on screen, never `meeting.language`.**
   `MeetingRecord.language` is `AppState.selectedLanguage.rawValue` captured at `beginSession()` — the
   user's configured shortlist entry, not what was spoken. A `he`-configured user dictating English got a
   right-aligned live bubble. Any content-derived property must also include the live sources
   (`session.currentSegmentText` + `session.livePreviewText`, gated on `isLive` so a background
   recording can't leak into another meeting's view). `segments` is empty until the first chunk
   commits, and **on the Nemotron backend that is the entire recording** — it emits one chunk at
   `finish()`, so the 5 segments in `Meeting session stop: segments=5` are all created by
   `stopRecording()` + `splitByDuration()`. Anything keyed off `segments` is dead for the whole
   live session on that path.

17. **Segment flush rules are per-backend, because chunk arrival means different things.**
    `MeetingSession.accumulate(idleFlushTracksSpeech:)` is the switch. whisper.cpp emits one
    chunk per voiced VAD segment, so an arrival gap is a real pause and the 2.5s idle timer is
    valid. Nemotron + Sortformer releases text on the diarizer's finalize schedule, so an
    arrival gap means "the speaker took a breath and the timeline committed" — the idle timer
    there split a 48s continuous recording into seven 2–9s cards whose timestamps were
    perfectly contiguous, the tell that no real silence existed anywhere in it.

18. **Contiguous card timestamps are the signature of a non-audio-clock split.** If card N ends
    exactly where card N+1 begins, the boundary came from arrival timing or from
    `flushCurrentSegment` setting `currentSegmentStartTimestamp = end` — not from silence. A
    genuine pause leaves a visible gap on the audio clock.

19. **Leaving a segment open is cheap; splitting it wrongly is not.** The live bubble renders
    `currentSegmentText` and every `accumulate` writes to `MeetingPendingStore`, so an open card
    is neither invisible nor at risk from a crash. There is no need for a timer whose only job
    is to close it — the 30s cap already bounds both card length and persistence latency.

20. **An admission-control gate must be waited on *before* the exclusive slot is taken, never
    while holding it.** `ModelWorkQueue.run()` did `acquireSlot()` then `while meetingActive { await }`.
    A job submitted during a meeting took the only slot and parked on the gate; everything behind it
    was starved for the rest of the app session, including the post-meeting polish, overview and RAG
    index. Order is gate → slot → re-check gate (a meeting can start during the handoff) → release and
    retry if it went back up. Both waits must be cancellable, the body needs a stall ceiling that can
    force the slot open, and long waits must log — a queue whose only log line is on *completion* goes
    silent precisely when it is broken.

21. **Two unstructured `Task`s in the same `defer` have no order.** `stopInAppRecording()` fired
    `Task { setMeetingActive(false) }` alongside `releaseMeetingNemotron()`, which itself submits a
    `ModelWorkQueue.run`. When the submission won, it landed on a still-raised gate. Anything that
    lowers a gate and then submits work through it belongs in one `Task` with an explicit `await`
    between the two.

22. **A CoreAudio property listener is bound to a device ID, not to "the microphone".**
    `MicrophoneUsageMonitor` installed `kAudioDevicePropertyDeviceIsRunningSomewhere` listeners once at
    `start()` and never removed or refreshed them: an unplugged iPhone Microphone produced 17 ×
    `AudioObjectGetPropertyData: no object with given ID 140`, a mid-recording aggregate device got no
    listener at all, and stale reads fired spurious `any input active=true` while nothing was
    recording. Own the full lifecycle — track installed IDs, add an independent
    `kAudioHardwarePropertyDevices` listener to rebuild on churn, remove every block in `stop()`, and
    call `stop()` from `deinit`. Note `AudioObjectPropertyAddress` is taken `inout`, so it cannot be a
    shared `static let`.

23. **If the source signal is still on disk, re-run the real model — don't ask an LLM to guess.**
    An LLM asked to fix "obvious mishearings" pattern-matches a plausible correction; it cannot hear.
    The meeting audio survives `stopRecording()`, so the post-stop pass re-decodes it with a larger
    Whisper model. This also deletes the entire prompt/parse/validate apparatus an LLM batch pass needs
    (see rules 12, 14, 15) — that machinery was a tax on the wrong instrument, not on the problem.

24. **Group work into the model's native window; submit one queue job per window.** Whisper's encoder
    cost is per 30s window and its accuracy is highest there, so group cards up to 30s and never split
    one. Submit each window as its own `ModelWorkQueue.run` job: a whole pass would blow the 120s
    `stallCeiling` and have its slot reclaimed mid-flight, and per-window submission re-checks the
    meeting gate so a new recording suspends the run at a boundary instead of racing it.

25. **A strict output validator written for an LLM must not be reused for a second decode.**
    `TranscriptPostValidator(.strict)` exists to catch a model drifting off a line it was told to
    preserve. A genuine re-decode legitimately differs far more. Validate only the failure modes a
    decode actually has: empty output, and a length ratio far outside the original (hallucination
    spiral or dropped utterance).

26. **Set `rawText` only when it is still nil.** It is the "what the live backend actually heard"
    record and the Original toggle's source. Overwriting it on a second refine run replaces the raw
    ASR text with the previous run's output, and the toggle silently starts comparing two refined
    versions.

27. **A preparation path per engine, not a check per engine.** Three call sites that read
    `AppState.shared.llmPostProcessor` and log 'skipped' are three checks and zero preparations. An
    engine a feature depends on needs an owner that can download it, load it, warm it, and say why it
    cannot.

28. **A silent skip needs a visible terminal state.** `Logger.warning` is not a user surface. A stage
    that declines to run must leave a reason the UI can render and an action that retries it —
    otherwise the feature reads as broken, not as unprepared.

29. **A queue job's length must be bounded by the model's work unit, not by the caller's convenience.**
    `rag-index` wrapped a whole 26-chunk embed in one job, ran 378s against the 120s `stallCeiling`,
    and had its slot reclaimed. Before batching such a job, ask whether it should exist: that one was
    deleted, not fixed (§4).

30. **Only the live path holds a model resident; every enhancement model loads per pass and frees on
    every exit.** Nemotron stays loaded for the duration of a meeting because it IS the live ASR.
    Whisperer V3 (547 MB) and Qwen3.5-4B (+781 MB / 2340 MB active) are post-stop work: load once per
    pass — not per window, not per segment — run the whole recording, free in a `defer` that covers
    success, failure and cancellation alike.

31. **Before optimising an engine, check whether the engine is the problem.** The Ask AI retrieval
    stack — a second model, a second file format, an SPM dependency, an index lifecycle, four rules
    (2, 3, 4, 13) and a `deferIndexing:` parameter threaded through finalize — existed to hand the
    LLM a *subset* of a transcript the same LLM already swallows whole for the overview. Removing it
    was also a speedup: retrieved context differs per question and forces `reuseWarmCache: false`,
    while a whole-transcript prefix is identical across questions and prefills once.

32. **Preparation is a feature surface, not a progress detail.** Four engines and 3.7 GB cannot be
    reported in a status pill. Give preparation its own screen, drive it from readiness state rather
    than a 'has onboarded' flag so it returns whenever a model is deleted, weight the progress bar by
    download size (a 4-step bar sits at 50% for twenty minutes and then jumps), and include the warm
    pass in it — the one-time ANE/MLX compile is the whole reason the later per-pass loads are cheap,
    so it belongs in the preparation the user is watching, not in the first pass they are waiting on.

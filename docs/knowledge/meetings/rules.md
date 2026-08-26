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
    Per-backend gating is necessary but **not sufficient**: the gap rule is arrival-derived on
    both paths, so it must also clear the text test in Rule 36.

18. **Contiguous card timestamps are the signature of a non-audio-clock split.** If card N ends
    exactly where card N+1 begins, the boundary came from arrival timing or from
    `commitSegment` starting the next card at the close timestamp (`end`, or the interpolated
    `cut` when a remainder carries forward) — not from silence. A genuine pause leaves a
    visible gap on the audio clock.

19. **Leaving a segment open is cheap; splitting it wrongly is not.** The live bubble renders
    `currentSegmentText` and every `accumulate` writes to `MeetingPendingStore`, so an open card
    is neither invisible nor at risk from a crash. There is no need for a timer whose only job
    is to close it — the 30s cap already bounds both card length and persistence latency.
    This is what makes Rule 36's "decline the break" branch safe: a soft break that cannot find
    an honest cut costs nothing by doing nothing.

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

33. **Readiness means "usable now", never "the file exists".** A model whose first load costs a
    one-time compile (Core ML / ANE, MLX graph) is not ready when it is downloaded — it is ready when
    that compile has been paid. Deriving `.ready` from `isModelDownloaded` made `prefetch()` skip the
    warm pass from the second launch onward and moved a 37s ANE compile onto the end of every meeting
    (`meeting-refine-load ran=39903ms` against `meeting-refine ran=1341ms`). The compiled artifact is
    in an OS cache we cannot query, so persist a marker of our own, key it to the model filename, and
    write it **only** on a successful warm.

34. **A new lifecycle state gets a new case — check what the existing ones already mean.**
    `.preparing` is skipped by `prefetch()`; `.needsDownload` drives both a "download it" message and
    the remaining-bytes footer. Reusing either for "on disk, not yet warm" starves the engine or lies
    to the user. Add the case and then read every exhaustive switch over the enum — the compiler finds
    the `switch`es, not the `if case` / `?? .needsDownload("")` defaults.

35. **A refcounted resource used by two calls in sequence needs an outer borrow.** Each
    `MeetingAIService` call borrows and releases on its own, and a release to zero arms a 60s idle
    unload — so the model can unload *between* title and overview. Hold one borrow across the whole
    sequence. Take it after any stage that gates on free memory (the refine pass loads its own
    multi-GB model), not before.

36. **A break derived from arrival timing is a hypothesis; validate it against the text before
    applying it.** A hole in Sortformer's finalized timeline is indistinguishable from silence on
    the audio clock — `MeetingSpeakerCoordinator.voicedRuns` reports it verbatim and `emit()`
    apportions the item's words across the runs proportionally, so the "gap" can land mid-word.
    That is how a single sentence became a `0:31 → 0:33` seven-word orphan card plus a
    continuation. The sentence boundary is the only signal that survives both backends:
    `closeSegment(endTimestamp:policy:)` makes a soft break (gap rule, idle timer) prove itself
    against `splitAtLastSentenceEnd` plus size floors (5s / 12 words), carry the trailing
    incomplete sentence forward as the new open card, and **decline** when no honest cut exists.
    Only the 30s cap is unconditional; a speaker change, the stop and the tail drain commit
    as-is because there is nowhere to carry to. Corollary for the search itself: a terminator
    counts only when followed by whitespace or end-of-string, or the `.` in "3.5 million" is a
    sentence end.

37. **A snapshot taken before an async pipeline has drained is not the transcript.** The
    backend's tail chunk arrives *after* `stopRecording()` returns, so `MeetingSession`'s AI Task
    computes everything — segments, transcript, `shouldRun`, the empty-transcript guard — only
    after `awaitTailDelivery()`. Defending inside one consumer is not enough:
    `MeetingTranscriptRefiner` re-read CoreData and compared counts, but the comparison **ties**
    when the read beats the tail's append, and the `polish disabled` / `model missing` paths skip
    the re-read entirely, so title and overview summarized a transcript missing its last card.
    Wait once, at the top, where every path sees it. Correspondingly, serialize the appends
    (`pendingPersistence`) — two unstructured `Task`s from consecutive flushes have no order
    between them (Rule 21), and a pass that rewrites the whole `segmentsJSON` blob needs one
    handle to wait on.

38. **A device-level "is it running" bit is a trigger; only a process-level read is attribution.**
    `kAudioDevicePropertyDeviceIsRunningSomewhere` says "some input is hot" and nothing more, so
    `MeetingDetector` had to *guess* the provider from what happened to be running — structurally
    impossible for a browser meeting or a Slack huddle, and unable to tell a real call from Cisco
    Proximity's room-pairing agent cycling the mic all day (30 spurious debounce cycles in one
    3-hour log). Enumerate `kAudioHardwarePropertyProcessObjectList` and read
    `kAudioProcessPropertyIsRunningInput` per process. It is read-only public API — no TCC grant,
    unlike process taps — which is what makes it the only attribution path that can exist in the
    sandboxed build. Then: resolve helper processes to the owning app through a parent-pid walk
    (capture is reported against `com.google.Chrome.helper`, not Chrome); keep an ignore list for
    agents that hold the mic without a meeting, including Whisperer itself; gate an app that is
    always running (Slack) on capture *only*, never on presence; and require a sustained unbroken
    capture run for a browser, or a two-second voice search prompts.

39. **Verify a build's sandbox from the signed artifact, never from the entitlements filename.**
    `ENABLE_APP_SANDBOX = YES` injects `com.apple.security.app-sandbox` regardless of what the
    `.entitlements` file you named contains, so Debug shipped `whisperer-nosandbox.entitlements` and
    ran sandboxed anyway — silently killing AX browser detection for every developer build. Check
    with `codesign -d --entitlements -`, or read the log path (`~/Library/Containers/…` is the tell).
    Corollary: **warn on every failure mode of a permission-gated read, not the ones you predicted.**
    `allWindowTitles` warned on `.apiDisabled`/`.notImplemented` and stayed silent on the
    `.cannotComplete` a sandbox actually returns — the one case that was happening.

40. **Never name a plausible cause in a log line; print the observed evidence.**
    `"resolve returned nil (score below threshold)"` was emitted on a path where the scorer was
    never called, and it cost real diagnosis time before the absence of any `score X < 0.45` line
    proved it false. A message that asserts a mechanism it did not verify is worse than no message.
    Print what was seen — which apps were capturing, the hardware state, whether AX was reachable —
    and let the reader conclude.

41. **Two firing paths must share one gate, or the backup path becomes the bug.** `MeetingDetector`
    fires through `resolve()` → `score()` (evidence object, 0.45 threshold) *and* through
    `fallbackPoll()` → `fireDirect()` (no evidence, no threshold). The scorer correctly rejected a
    browser-title-only candidate at 0.30; the poll fired it anyway, so the path meant to *back up*
    the resolver was strictly more trigger-happy than it. Any bypass of a scorer must re-implement
    the scorer's gates at the bypass site — or, better, push the gate down into the shared
    predicate both paths call (`detectBrowserMeeting` now requires the browser to be in
    `capturingApps`, so neither caller can skip it).

42. **A window title identifies the service; it does not establish that anything is happening.**
    `"Google Meet"` is precisely the title of `meet.google.com/home` — the state that proves there
    is *no* call — while a real call is `Meet – abc-defg-hij`, containing neither the product name
    nor the URL (a title is the page title; it never carries the URL, so `zoom.us/j/` matches
    nothing either). Matching the bare product name inverts the detector: it fires on the landing
    page and stays silent during the meeting. Pair every title match with an observed hardware
    fact — for a browser, that it is capturing audio — and exclude exact landing-page titles.
    When a service's in-call title cannot be verified, do not guess it: fall through to the generic
    sustained-capture path and say "Meeting in <browser>".

43. **A dismissal is user intent and outlives hardware state; a cooldown wipe is not a reset.**
    `hardwareWentIdle()` called `lastFiredDate.removeAll()` when clearing suppression, on the
    reasonable theory that a finished call should let the next one prompt. The effect was that any
    unrelated camera blip erased the 30-minute refire guard, and the dismissed toast returned ~40
    seconds later, forever. Clear the ledger for providers the user never answered; keep the full
    cooldown for names in `dismissedNames`, and expire that set together with the cooldown it is
    pinned to so a dismissal does not become permanent either.

44. **A suppressed detector is deaf, so a false positive costs you the true one.** The same log
    shows the prompt firing with zero hardware evidence, the user dismissing it, and then the
    genuine `camera active=true` eight seconds later being dropped because `isReadyToTrigger()`
    returns false in `.suppressedUntilHardwareIdle`. "It fires when it shouldn't" and "it does
    nothing when it should" were one defect reported from two sides — chase the false positive
    first, and re-test the negative afterwards rather than treating it as a separate bug.

45. **The overview is built from the transcription, not from who said it.** `generateOverview`
    fed the model `timestampedTranscript` — `[0s] Speaker 1: …` on every line — and got summaries
    organized around speakers rather than content. A meeting overview answers "what was this
    about"; attribution is Ask AI's job, and `parseCitations` still needs the `[Ns]` markers, so
    the split is `narrativeTranscript` (markers, no names) for the overview and
    `timestampedTranscript` (markers + names) for Ask AI. A note under 60 words gets
    `plainTranscript` — `notePrompt` has no seconds field to cite into, so the markers are pure
    noise in the prompt. Secondary effect worth keeping in mind: an identical `Speaker N:` prefix
    repeated on every line is the strongest repetition in the whole prompt, and the MTP decode
    path is greedy with no repetition penalty (see `docs/knowledge/llm/`), so it is exactly the
    token pattern a degenerate loop copies.

46. **A meeting records silently on both edges, independent of the Sound Effects picker.** The
    feature's entire value is that starting one costs nothing socially: a Tink mid-call announces
    to the room that you are recording, and the Pop at the end announces it to everyone still on
    the line. The picker (`SoundOption`, default Tink/Pop) governs *dictation* — "Default" there
    must not put a sound into a meeting, so the suppression cannot live in `SoundPlayer` or in a
    new setting. It lives in `AppState.suppressesFeedbackSound` (`isMeetingMode`), read at the two
    reachable sites: the start sound in `startInAppRecording()` and the stop sound in
    `stopInAppRecording()`. `stopRecording()`'s sound is already unreachable — that function
    returns early on `isMeetingMode` — and `startRecording()`'s is behind a `state == .idle`
    guard. `cancelRecording()` never had one. Nothing visual changes: the Studio window still
    opens and the transcript still fills in live. "Silent" means inaudible, not invisible.

47. **The stop-sound decision must be captured before the first `await`, not read at the call
    site.** The stop sound fires inside `stopInAppRecording()`'s Task, several awaits deep, and
    `activeMeetingSession` is nilled *in that same Task* so the tail chunk can still route to the
    session. Reading `isMeetingMode` at the sound site is therefore a race with teardown. Capture
    `wasSilentRecording = wasMeetingStop || suppressesFeedbackSound` synchronously alongside
    `wasMeetingStop`. Keep it a separate constant: `wasMeetingStop` also gates unmuting, the
    history save, nilling the session, and lowering the `ModelWorkQueue` meeting gate, so widening
    *it* would change four unrelated behaviours.

48. **Any path that ends a recording must route through `MeetingSession.stopRecording()`, never
    `AppState.stopInAppRecording()` directly.** The menu bar Status tab renders its in-app
    recording card on `isInAppMode && state.isRecording`, both true throughout a meeting, and its
    Stop button called `stopInAppRecording()` — so stopping a meeting from the menu bar ended it
    as a dictation: Pop sound, unmute of audio that was never muted, the meeting saved into
    transcription history, and the `MeetingEntity` never finalized (no title, no overview, no
    polish, audio stranded in `Sessions/`). Fixing this at the call site would only hold until the
    next Stop button; the guard belongs at the top of `stopInAppRecording()`, mirroring the one
    `stopRecording()` already has, with `isMeetingStopInFlight` distinguishing the legitimate
    re-entry from `stopMeetingRecording()`. General shape: when two entry points must converge on
    one teardown, enforce it in the function they both reach, not in each caller.

49. **A meeting drives `AppState`'s recording state, so every UI that reads that state renders the
    meeting unless told otherwise.** The menu bar Status tab's "Transcribe" card branches on
    `isInAppMode && state.isRecording` — both true for the whole meeting — so it showed the
    meeting's waveform, its live transcript, and a Stop button for it, in a window the user never
    associated with meetings. Reusing the in-app dictation path is what makes meetings cheap to
    build, and this is its standing cost: when adding a surface that reads `state`,
    `isInAppMode`, `liveTranscription` or `waveformState`, decide explicitly what it does during a
    meeting. Here the answer is nothing — the card is gated on `!isMeetingMode`, not given a
    meeting-flavoured variant, because a badge in the menu bar is exactly the indication silent
    recording exists to avoid. `lastInAppTranscription` was already safe: it is assigned under
    `!wasMeetingStop`, so the finished transcript never appears there either.

50. **A "don't fire twice" guard must be scoped to the event, not to the clock.** Meeting detection
    prompted for the first Google Meet of a session and never again — for any provider. The refire
    guard was a 30-minute wall-clock window keyed by display name, and only the *dismissal* path
    cleared it; accepting the toast, or letting it auto-dismiss, left the entry in place, and the
    entry is checked before any scoring or logging so the drop was completely silent. A wall-clock
    window can only ever be wrong in both directions: too short and one call prompts twice, too long
    and back-to-back meetings are lost. Ask instead whether the *event* the guard is scoped to has an
    observable end. Here it did — the provider stops holding the microphone, and `AudioProcessMonitor`
    already tracked unbroken capture runs — so `MeetingPromptLedger` releases on that, and the clock
    survives only as a ceiling for providers whose end genuinely cannot be seen (`.unobserved`:
    matched by virtual audio device or by being frontmost). Corollary: if the guard has a state that
    only one code path clears, enumerate every path that ends the guarded event before shipping it.

51. **A coarse signal is not evidence that the fine-grained event happened.** Hardware idle (no
    camera, nobody on the mic) reads *identically* to muting yourself with the camera off, so
    releasing the prompt guard on it re-toasts the meeting already in progress. Release on the
    signal that actually distinguishes the two — the provider's own capture run ending, plus a grace
    period (20s; 120s once dismissed, since a one-minute mute in a long call is ordinary). Reserve
    the coarse signal for the entries the fine-grained one can say nothing about.

52. **Bookkeeping runs before the gate; only the action runs after it.** `fallbackPoll()` returned
    early on `!isReadyToTrigger()`, which is false for the whole time a toast is up, a meeting is
    recording, or a dismissal is in force — so capture-run tracking went stale exactly during a
    meeting, the one window in which the end of the call was observable. The guard could only be
    released by an event the code refused to look at. Same failure shape as the latched
    `hardware.microphoneActive = true` in that poll: a level derived from a live source must be
    *assigned* from it (`syncMicrophoneWithCapture()`), never raised in one place and left for
    something else to lower.

53. **Extract the pure decision out of the `@MainActor` observer to test it.** The detector is
    hardware callbacks, timers, AX reads and a five-state machine — none of it reachable from a unit
    test. `MeetingPromptLedger` is a struct with injected `Date` and a `(String) -> MeetingCaptureStatus`
    closure, so every branch of "does this prompt fire" is a table test, and the detector keeps only
    the plumbing. The reported bug and each guard it must not break are pinned in
    `WhispererTests/MeetingPromptLedgerTests.swift`.

54. **A state test cannot detect a transition that has already completed.** The refire guard asked
    "is this provider quiet right now, and for how long" — a question whose answer is *no* by the
    time it matters. Two meetings back to back are separated by ~8s; the 5s poll that catches the
    gap open sees it as a few seconds old and declines against the grace period, and by the next
    poll the provider is capturing again, at which point the gap has left no trace at all. Record
    the transition itself (`AudioProcessMonitor.runPrecededByGap`) so it can be read *after* it
    closes. A closed gap is also stronger evidence than an open one, so it earns a shorter
    threshold: 5s for "went quiet and came back" against 20s for "still quiet".

55. **Silent rejections make the next bug invisible.** `recentlyFired` is checked before any scoring
    or logging, so a suppressed candidate produced the same `no candidate` line as no candidate at
    all — twice now, that ambiguity meant a log full of the failure said nothing about its cause. If
    a guard can drop a candidate, it must say so (throttled, with the state it decided on).

56. **Muting does not release the microphone.** Zoom, Teams and Chrome all hold the input device
    open while muted — the orange indicator stays lit. So a break in *per-process* capture is a
    genuine call end, while the *device-level* `IsRunningSomewhere` bit going quiet is not. The two
    signals warrant opposite amounts of trust; see rule 51.

57. **Sample at the rate of the event you are measuring, not the rate of the loop you already have.**
    A 5s poll quantizes *both* ends of a capture gap, so the same ±5s error makes an 8s turnaround
    read as 3s and a 2s device switch read as 7s — the two overlap, and no threshold can separate
    them however carefully it is picked. The fix is not a better threshold, it is a faster clock:
    `updateCaptureSampler()` refreshes attribution at 1 Hz, but only while the ledger holds an
    outstanding entry, so the cost exists only in the window where the measurement matters.

58. **An open app is not a meeting — gate on the call, once, for every vendor.** A meeting app is
    open most of the working day; only three things say a call is actually *happening*: observed
    per-process audio capture, the provider's in-call virtual audio device running, or an in-call
    browser window title (which already requires capture). Running, frontmost and recently-activated
    are *presence*, and presence must only ever break a tie between candidates that already cleared
    the gate — it can never assemble one. `MeetingEvidence.callIsLive` is the single expression of
    this and `score()` returns nil before any arithmetic when it is false, so a vendor added later
    inherits the rule instead of needing its own patch. Fixing this per provider is the failure mode
    it replaces: the Google Meet landing-page guard was written for Meet alone, and Zoom's sign-in
    screen then raised "Meeting detected — Zoom" with `us.zoom.xos` never once attributed a capture
    run. The asymmetry is deliberate — missing a call nobody can attribute is recoverable (the user
    starts the recording), a toast over an app they just opened is not.

59. **A view that renders a page must not be the source for "copy everything".** `MeetingDetailView`
    paginates at 20 segments and grows the window from `MeetingTranscriptView`'s scroll, so any
    consumer that does not scroll that view sees only the first page. A Full Text mode truncated at
    segment 20 and a Copy button that silently takes a fifth of the meeting both look like they
    worked — the failure is invisible at the call site and invisible in the output. Read
    `allSegments` (via `completeSegments`) for anything whole-document; `displayedSegments` is a
    rendering optimization, not the transcript.

60. **One function per rendering, shared by the screen and the clipboard.** Every transcript shape is
    produced twice — once to draw, once to copy — and two implementations of "the same" text drift
    the moment either is touched. `MeetingTranscriptText.plainProse` / `.labelled` are pure and
    UI-free, so both callers are literally the same code and the paragraph rules are testable
    without a UI harness. The same applies to `isRightToLeft(sample:)`: three views had grown
    identical private copies of the ratio test (one comment openly said so) before it was hoisted.

61. **Paragraph on the speech, not on the segment.** A segment boundary is a property of the ASR
    backend's chunking — whisper.cpp emits one per voiced VAD span, WhisperKit commits ~6s,
    Nemotron returns the whole session as one — so breaking prose per segment renders a monologue
    as a list of fragments and a Nemotron meeting as one unbroken block. Break on a speaker change
    or a >2.5s **audio-clock** gap. Two edge cases fall out of it: a dropped blank segment must not
    take its neighbours' break with it, and an overlapping/out-of-order span yields a negative gap,
    which is not a pause.

62. **A control that says "Export" must export.** The workspace's Export button wore a
    `square.and.arrow.up` share icon, wrote no file, showed no confirmation, and copied labelled
    text to the clipboard. Users read the icon and the label, not the implementation; a mislabelled
    control is worse than a missing one because it consumes the affordance its real version needs.
    Replaced with a Copy button that names what it does and confirms it happened.

63. **The surface that comes up is decided by where Start was pressed.** `startMeetingRecording`
    raised the floating rail unconditionally, so pressing Start inside Meeting Studio put a second
    copy of the transcript on top of the window the user was already reading it in. Thread the
    origin (`MeetingLiveSurface.floatingWindow` / `.workspace`) from the call site instead of
    inferring it: a detection toast has no workspace open and must not raise one over the call;
    the workspace's own Start controls need nothing raised at all. `meetingWindowIsVisible` is set
    either way — it means "a meeting surface owns the recording UI", and the workspace is equally
    that surface — so nothing may assume a meeting in progress implies a live window on screen.

64. **A meeting's language is decided by the whole meeting, and a wrong decision is worse than
    none.** Whisper handed a wrong forced language code does not fail — it emits fluent text in the
    language it was told, so a Hebrew meeting decoded as English comes back as plausible English
    prose that a character-count plausibility check waves straight through. The old rule ("detect
    on window #1, force it everywhere") therefore gave the pass one chance to be right and turned
    a partly-wrong transcript into a fully translated one when it wasn't. Detection is encoder-only
    (`whisper_pcm_to_mel` + `whisper_lang_auto_detect`, no decode) and returns the whole
    distribution, so probing a coarse grid across the recording costs a fraction of one window
    decode: 45 probes / 9.3s on an 80-minute meeting, 1–2 probes / <1s on a short one. Measured over
    the app's own history (`MeetingLanguageTimelineIntegrationTests`): 35/35 dominant languages
    correct — short 29/29, medium 2/2, long 4/4 — against 34/35 for the first-window rule it
    replaced. Below the confidence margin the timeline abstains to `.auto`, which is the old
    per-window behaviour and degrades rather than translating.

65. **Local smoothing cannot fix a locally-confident mistake; only the meeting can.** A flat
    Viterbi switch cost plus a ~15s dwell threshold stops a borrowed English word inside Hebrew from
    flipping the pin, and that is what those two knobs are for. They cannot stop a *run*: on a
    48-minute Hebrew meeting the tiny detector produced 73 consecutive seconds of Polish at 0.48,
    which cleared both bars and got a span of its own. The fix is a second, non-local rule —
    `minSwitchConfidence`: a minority run whose mean posterior is below it is re-labelled as the
    meeting's leader, not abstained (abstaining hands those windows back to the per-window
    detection that produced the Polish). **The whole-meeting veto must itself be gated on the
    meeting having an opinion**: `leadingLanguage` returns nil unless the leader beats its rival by
    `abstainMargin` across every probe. Without that gate a 50/50 en/nl meeting elects a leader by
    tie-break and converts an honest abstention into a coin-flip pin — the exact outcome the design
    treats as worse than no decision.

66. **Ground truth read off the stored transcript is provisional, and the suite has to say so.**
    The gold labels in `WhispererTests/TestData/meeting-language-gold.json` were derived from each
    meeting's stored text, which is the output of the very pass under test — a fully mis-decoded
    meeting is labelled with the language it was mis-decoded into, and the test then passes on it.
    Every entry carries that warning in its `note`. The dump samples the **start, middle and end**
    segments, not the first 200 characters: a meeting that switches language switches in the
    middle, and a leading-only excerpt writes the single-language assumption straight into the gold.

67. **An integration suite over the user's real recordings must not write to them.**
    `MeetingTranscriptRefiner.run` persists — `MeetingEntity.language`, `segmentsJSON`, and a
    `.meetingSegmentsDidRefine` post. The fixtures the history loader returns are the user's actual
    meetings, not copies, so `MeetingRefineLanguageIntegrationTests` reproduces the three steps
    (plan windows → build timeline → decode each window in its span's language) against the same
    bridge instead of calling `run`, and writes nothing.

68. **`xcodebuild` does not forward the invoking shell's environment to the test process.** A bare
    `MEETING_LANG_TESTS=1 xcodebuild test …` silently *skips* every opt-in test and reports success.
    The variable must be prefixed `TEST_RUNNER_`, which xcodebuild strips before the test sees it:
    `TEST_RUNNER_MEETING_LANG_TESTS=1`. A gate that fails open into a green run is indistinguishable
    from a passing suite.

69. **A destructive reset must be scoped to the unit of work that is about to redo it, not applied
    up front.** The refine's `redoAll`/forced-language path used to unwind every card to raw ASR
    text before the first window decoded, and the first completed window persists the whole array.
    A crash at window 44 of 88 therefore left the other 44 stripped of the polished text the
    overview and Ask-AI were built from, with no way back. Unwind each window immediately before
    its decode, after every `continue` that could skip it, so an interrupted run leaves
    not-yet-reached cards exactly as they were.

70. **Do not reset a borrowed bridge's abort flag.** The refine borrows the resident dictation
    bridge, and `requestAbort()` from `stopAsync()` is how a key release ends a recording — a
    blind `resetAbort()` swallows the user's stop. Only clear the flag on a bridge this run
    loaded, or on a borrowed one when `WhisperBridge.isDecoding` is false.

71. **Check the abort flag after a decode before persisting its output.** An abort truncates the
    decode wherever it was and whisper still returns the segments already emitted. Persisting them
    — with `rawText` stamped, which marks the card permanently polished — replaces good live text
    with half a sentence. Discard the window instead.

72. **"Decode returned nothing" and "decode did not run" must be distinguishable at the call site.**
    `transcribeTimestamped` collapsed shutdown, not-initialized, lock timeout and genuine silence
    into `[]`, so a lock timeout was logged as "window decoded to silence" and marked handled.
    `transcribeTimestampedChecked` throws for the first three; only real silence is empty.

73. **A card whose re-decode matches its existing text is still converged — stamp it.** `isPolished`
    derives from `rawText != nil`, so skipping the stamp when nothing changed leaves the card
    pending forever and a meeting whose live ASR was already right re-refines on every pass.

74. **`run` must hold its own single-flight guard.** The guard lived in `start()`, but
    `MeetingSession` calls `run` directly (it needs the returned segments), so a manual
    "Re-transcribe" overlapping the end-of-meeting polish put two passes on one meeting, both
    writing the whole array — the slower one's stale snapshot won. Claim `activeMeetingID` before
    the first `await` so the check and the claim are one main-actor turn.

75. **Throttle whole-array persistence, and key the dirty flag on mutations rather than on the
    rewrite counter.** `updateSegments` rewrites every segment, so a per-window write is quadratic
    in meeting length on the main actor. Writing at most every 2s bounds interrupted-run loss to
    that much work. The flag must be set at *every* site that mutates the array, including the ones
    that change no visible text — the `rawText` convergence stamp and the per-card language — or
    those never reach disk and rule 73's fix is undone.

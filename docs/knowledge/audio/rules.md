# Audio — Rules (apply by default)

1. **A container that `afconvert -hf` lists is not necessarily writable.** Ogg is advertised
   with `data_formats: 'opus'` and fails at `ExtAudioFileClose` (`'pck?'`) — or, through
   `AVAudioFile`, leaves a 0-byte file with no error at all. Prove a container by writing a
   file *and reopening it*, never by reading the capability table.

2. **"Core Audio cannot write it" ≠ "the platform cannot write it."** Ogg is unwritable through
   `AVAudioFile` / `afconvert`, but libogg + libopus write it fine from Swift
   (`element-hq/swift-ogg`) — incrementally, crash-safe, at 8.3 MB/hour. Before concluding a
   format is output-only, check whether the limitation is the framework's or the format's.

   *(Supersedes the earlier rule "Opus output goes in CAF; `.opus` is an input-only format",
   which was true of Core Audio only.)*

3. **Don't resample for Opus — but do convert the sample type.** libopus encodes 16 kHz
   natively and `OGGEncoder` outright refuses `pcmRate != opusRate`, so the capture rate goes
   through unchanged. It does take **interleaved Int16**, so `AudioArchiveWriter.write` clamps
   and scales the recorder's Float32 buffers itself (one pass over a reused scratch array —
   an `AVAudioConverter` for that is more machinery than the loop it replaces).

   *(Supersedes the earlier wording "recorder buffers pass through `write(from:)` untouched",
   which described the `AVAudioFile`/Core Audio writer that was never shipped.)*

4. **If you do write Opus into CAF, strip the `free` chunk.** `AVAudioFile` reserves a flat
   ~236 KB packet-table pad that `AudioFileOptimize()` will not reclaim; for a 10 s dictation
   that is 85% of the file. Rewriting the CAF chunk list without `free` is safe and verified.
   Ogg has no equivalent pad — a 10 s `.opus` is 23.7 KB with no post-processing.
   *(Historical: the app writes Ogg, so nothing exercises this. It is the fallback path if the
   swift-ogg dependency ever has to be dropped.)*

5. **Deleting a record means deleting its artefacts.** A CoreData row and its audio file (plus
   `.wax` and `-chat.json` for a meeting) go together. `HistoryManager.deleteTranscription`
   dropping only the row is the bug that orphans `Recordings/` forever.

6. **Any cleanup sweep must run after crash recovery, not before it.** `loadInProgressSessions`
   / `recoverCrashedSessions` finalize records that point at files a sweep would otherwise see
   as orphans.

7. **Age records by `createdAt`, never by file mtime.** A transcode, refine pass or migration
   rewrites the file and would silently reset the retention clock.

8. **Never hardcode 16 000 when reading a stored recording.** An Ogg Opus file reports
   **48 kHz** through `AVAudioFile` whatever it was encoded at, so a hardcoded rate is 3× off
   and fails silently — the seek lands somewhere real, just not where you meant. Derive
   everything from `file.processingFormat.sampleRate`.

9. **`AVAudioFile.read(into:frameCount:)` does not convert.** It fills at the *file's* format
   and ignores the client buffer's rate — measured 146 cycles where 440 were expected. Read at
   `processingFormat`, then convert with an explicit `AVAudioConverter`.

10. **Compare audio durations in seconds, never in frames.** Any check that a transcode
    preserved the recording (`abs(actual - expected) <= tolerance`) must be rate-relative, or
    a correct 16 kHz → Opus conversion looks like a 3× overrun.

11. **Commit the CoreData rename before unlinking the original.** Transcode → verify → save the
    new filename → *then* delete. If the save fails, delete the **new** file and keep the old
    one. Any other order can leave a library row with a dead play button, which is worse than
    the bytes it saved.

12. **A watchdog whose remedy is destructive must wait on observed progress, not on wall clock.**
    `forceIdleFromWatchdog()` calls `stopRecording()`, which bumps the recorder generation and
    invalidates the very start it was supervising — so a 4 s deadline against a CoreAudio call
    with no bounded latency does not *report* a failure, it *causes* one. Publish a progress
    signal from the owner (`AudioRecorder.startupInFlightSince`) and hold off while it says work
    is in flight. Sample that signal **stickily**: the owner clears it in a `defer`, one hop
    before the watchdog is cancelled, and a tick in that window would punish a start that just
    succeeded.

13. **The owner's deadline must fire before the supervisor's ceiling.**
    `AudioRecorder.startupHardDeadline` (20 s) sits below `AppState.startupHardCeiling` (25 s) so
    a wedged start surfaces as a thrown error on the normal catch path — which resets state,
    discards the session file and tears down meeting mode — instead of as a force-idle from
    outside, which does none of that. Two timeouts on one operation is fine; two timeouts with
    no ordering between them is the bug.

14. **Every exit from a start path must reset the recorder.** Attempts 1 and 2 threw
    `engineCleanedUp` leaving `recorderState == .starting`, and nothing else cleared it. Use a
    generation-stamped `defer` (`if case .starting(let g) = recorderState, g == generation`) so
    the reset cannot clobber a start that began after yours. And discard the session audio on
    *every* abort — a cancelled start otherwise leaves an open encoder and a fraction-of-a-second
    `.opus` in `Sessions/` that no record points at.

15. **`try? await Task.sleep` is wrong for any timer that will be cancelled.** `try?` swallows the
    `CancellationError` and runs the body immediately, so a cancelled timeout fires instead of
    disappearing — which is how a 15 s timeout logged itself 4.4 s in. Write
    `do { try await Task.sleep(...) } catch { return }`.

16. **`AVAudioPlayer` cannot seek the app's Ogg Opus format — use `AVAudioEngine` + `scheduleSegment`.**
    Setting `AVAudioPlayer.currentTime = t` on an Ogg Opus file appears to work (read-back returns `t`),
    but the underlying decoder never moves. Any playback path must use `AVAudioFile(forReading:)` for
    random access and `AVAudioPlayerNode.scheduleSegment(file:startingFrame:frameCount:at:)` to start
    from the correct frame. `AVAudioFile` frame seeks on `.opus` are exact and repeatable — this is the
    same access pattern `WaveformGenerator` uses and it is verified correct.
    
    Empirical evidence (meeting file 47E20DE7…, 2786 s, 48 kHz / Ogg Opus):
    - `AVAudioPlayer.currentTime = 600` → read-back 600.0 ✅, but decoder stayed at 0 ❌
    - `AVAudioPlayer.currentTime = duration - 3`, then `play()` → still playing 12 s later, pinned at `duration` ❌
    - `AVAudioEngine` + `scheduleSegment(startingFrame: 600 s)` → offline-render RMS 0.037986, matches
      `AVAudioFile` direct read at 600 s (RMS 0.037991) ✅
    
    `SeekableAudioPlayer` (`Whisperer/Audio/SeekableAudioPlayer.swift`) encapsulates this pattern and
    replaces both `AudioPlayer` (History) and `MeetingAudioPlayer` (Meetings). The regression guard is
    `SeekableAudioPlayerTests.testSeekIntoToneRendersCorrectAudio`.

17. **RMS alone cannot tell a silent room from a dead input — always probe the device.** On
    2026-09-14 a woken-from-sleep `MacBook Pro Microphone` (id=96) reported `alive=true`,
    negotiated 48 kHz mono, and delivered 4096-frame **zero-filled** buffers through four
    independently built `AVAudioEngine`s. Rebuilding cannot fix mute, zero gain or a stale TCC
    grant, and all three produce exactly that signature. Before reacting to silence, read
    `AVCaptureDevice.authorizationStatus(for: .audio)`, `kAudioDevicePropertyMute` and
    `kAudioDevicePropertyVolumeScalar` **on the input scope** (`AudioMuter` only ever reads the
    output scope), plus `DeviceIsAlive` / `Streams`. `InputHealthProbe` does this; its verdict
    must reach the log line and the user-facing message. `reason=silence_1.5s` is not a diagnosis.

18. **The retry budget belongs to the session kind, not to the recorder.** A flat
    `maxRecoveryAttempts = 3` gave a 58-minute meeting the same ~7 seconds of patience as a
    two-second push-to-talk dictation, then surrendered permanently — and the counter only reset
    on a non-silent buffer, so nothing ever tried again. Long-form gets unbounded retries with
    exponential backoff capped at 10 s (`AudioRecorder.RecoveryPolicy.longForm`); dictation keeps
    the short leash because the user is holding a key and can just release and retry.

19. **Process-wide gates must be self-healing, never single-path invariants.**
    `ModelWorkQueue.meetingActive` and `MeetingJobQueue.isSuspended` were each raised and lowered
    by exactly one code path. The capture-failure path skipped the lowering, so one audio fault
    parked every background model job and every meeting summary for the remaining life of the
    process. Every teardown path now ends in `AppState.lowerStrandedRecordingGates(reason:)`,
    which lowers both whenever `activeMeetingSession == nil`. Guarded by
    `StrandedGateWatchdogTests` and `AudioFlowTimeoutTests`.

20. **A guard at the top of a stop path is a state leak waiting to happen.**
    `stopInAppRecording()` opened with `guard case .recording = state else { return }`. After the
    recorder had already collapsed to `.idle`, the user's Stop fell straight through:
    `activeMeetingSession` was never nilled, `awaitTailDelivery()` burned its full 12 s, and
    `isMeetingStopInFlight` stayed `true` — which is itself the guard that makes
    `abandonMeetingMode()` a no-op, so the deadlock was permanent. A stop arriving in an
    unexpected state must still run teardown and only skip the transcriber drain; clear
    `isMeetingStopInFlight` **first**.

21. **A failure surface has to outlive `state == .idle`.** `AppState.errorMessage` reaches only
    the menu bar popover; the silent-meeting toast renders inside `OverlayView`, whose panel hides
    at `.idle`. The Island is the only surface that survives, and
    `IslandCaptureState.failed` / `IslandEvent.captureFailed` existed for months with **nothing in
    the app emitting them**. A state the reducer handles but no producer emits is dead code, not a
    feature — assert the emission path in a test.

22. **Recorded audio is persisted at stop unconditionally — never behind a transcription-state guard.**
    The only code that wrote an archive into `Recordings/` was `saveRecordingFromTranscriber`, reachable
    only past `guard case .stopping = state else { return }`. Any watchdog trip flipped the state to
    `.idle` first, so the guard returned and the user's audio was never written — then the `Sessions/`
    working file was reaped by the 7-day orphan sweep. One user lost a 2-minute recording outright on
    2026-09-16. The archive write is now `archiveRecordingAudio(_:transcription:recordId:)`, called from
    every stop path including `forceIdleFromWatchdog`, before `streamingTranscriber` is nilled. It
    sources from in-memory samples, so it does not depend on the Ogg being closed — keep that
    independence. Durability of the user's audio must never be downstream of a transcription outcome.

23. **A history row must never name a file outside `Recordings/`.** `forceIdleFromWatchdog` wrote
    `audioRecorder?.sessionAudioURL?.lastPathComponent` — a `Sessions/` name — into `audioFileURL`,
    which every consumer resolves against `Recordings/`. The row looked healthy (duration intact, play
    button live) and failed only on click. `HistoryManager.finalizeSession` now refuses a filename with
    no matching file under `Recordings/` and logs an error rather than storing it; a row with `nil`
    audio is honest and recoverable, a row pointing at nothing is corruption. Deliberately *not* an
    `assertionFailure` — trapping a Debug build there would destroy the very recording the check
    protects.

24. **A late result repairs its row; it does not vanish.** When the completion path finds the state no
    longer `.stopping`, it no longer returns silently. `forceIdledSession` carries the force-idled row's
    id, archived filename and duration, and `repairForceIdledSession` updates that row through the
    idempotent `HistoryManager.finalizeSession` — archiving the audio if the watchdog could not. It
    deliberately does *not* re-run insertion or paste: the user has moved on, this is history repair.

25. **A resolver that hands out a URL it never checked is a dead control in the UI.**
    `TranscriptionRecord.audioURL` / `TranscriptionEntity.audioURL` now `fileExists` before returning,
    so a row whose file is gone returns `nil` and `audioIsMissing` becomes true. That one choke point
    gates both the player and Re-transcribe, and `TranscriptionDetailView` renders an explanation in
    place of the player instead of offering controls that fail with `2003334207`.

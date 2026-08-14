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

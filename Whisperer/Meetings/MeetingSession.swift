//
//  MeetingSession.swift
//  Whisperer
//
//  Live recording session state — bridging AppState → MeetingManager.
//

import Foundation
import SwiftUI
import Combine

/// Which surface owns the live UI for a recording, decided by where it was started from.
///
/// Both surfaces render the same `MeetingSession`, so this only says which one to *raise* —
/// the user can hand over either way at any time (the workspace header's float button, the
/// live window's "Open in Workspace"). Raising the wrong one is not cosmetic: the floating
/// window sits over whatever the user is meeting in, and the workspace is 1100pt of review
/// affordances that cover the call.
enum MeetingLiveSurface {
    /// Floating rail. A detected call: the workspace is not open and must not be raised over it.
    case floatingWindow
    /// The workspace itself. The user pressed Start in Meeting Studio and is already looking at
    /// the transcript there — nothing extra is put on screen.
    case workspace
}

@MainActor
class MeetingSession: ObservableObject {
    @Published var meetingID: UUID?
    @Published var segments: [MeetingSegment] = []
    var chunkGeneration: Int = 0
    @Published var notes: [MeetingNote] = []
    @Published var isRecording: Bool = false
    @Published var elapsedSeconds: Double = 0
    @Published var livePreviewText: String = ""

    // Accumulated text for the current in-progress segment (dark committed text).
    // Grows as chunks land; flushed to a MeetingSegment on the rules below.
    @Published var currentSegmentText: String = ""
    @Published var currentSegmentStartTimestamp: Double = 0

    /// Speaker the diarizer currently attributes speech to. Stays 0 on backends without
    /// diarization, which is exactly today's single-speaker behaviour.
    @Published var currentSpeakerIndex: Int = 0
    @Published var currentSpeakerName: String = "Speaker 1"

    /// Who the diarizer believes is talking *right now*, from its tentative (not yet
    /// finalized) timeline. Drives the live bubble label only — `currentSpeakerIndex`
    /// moves later, when text is actually attributed, which is what closes a paragraph.
    @Published var liveSpeakerIndex: Int = 0
    @Published var liveSpeakerName: String = "Speaker 1"

    /// True once the diarizer has reported any speaker at all — lets the UI show
    /// "Detecting…" instead of asserting "Speaker 1" before it knows.
    @Published var hasSpeakerSignal: Bool = false

    /// Custom names typed during the recording, keyed by speaker index, so segments
    /// flushed *after* a rename pick the new name up too.
    private var speakerNames: [Int: String] = [:]

    /// Hard cap on how much audio one transcript card may cover.
    private let maxSegmentDuration: Double = 30.0

    /// Audio-time gap between two chunks that counts as the speaker pausing. Below this,
    /// chunks are treated as one continuous paragraph.
    private let silenceSplitGap: Double = 1.2

    /// Floors below which a paragraph is not worth its own card. A gap or idle break that
    /// would produce one is declined and the text merges into the next card instead — per
    /// Rule 19 an open card is neither invisible nor at risk, and the 30s cap is the backstop.
    private let minSegmentDuration: Double = 5.0
    private let minSegmentWords: Int = 12

    // Silence-based flush: fires 2.5s after the last chunk if no further speech arrives.
    private var silenceFlushTask: Task<Void, Never>?

    /// Tail of the chain of CoreData appends. Every commit awaits its predecessor, so cards
    /// reach `segmentsJSON` in transcript order and the post-stop pass has one handle to wait
    /// on. Two bare `Task`s fired from consecutive flushes had no order between them.
    private var pendingPersistence: Task<Void, Never>?

    /// Audio-time end of the most recently appended chunk. All segment boundaries are
    /// placed on this clock so they line up with the recorded audio during playback.
    private var lastChunkEndTimestamp: Double = 0

    // Elapsed timer
    private var timerTask: Task<Void, Never>?
    private var recordingStartDate: Date?

    /// True from the first line of `startRecording` until it has either bailed out or
    /// set `isRecording`. `isRecording` alone cannot guard the entry: it is only set
    /// after `prepareMeetingBackend()` and `beginSession()`, and the former polls for
    /// up to 90s while Nemotron loads. Every tap on Start during that window used to
    /// pass the guard and create its own CoreData row — the extra rows were then left
    /// with `isInProgress = true` and showed up as "crash recovery: finalizing N
    /// interrupted session(s)" on the next launch.
    private var isStarting = false

    // MARK: - Start

    func startRecording(title: String, surface: MeetingLiveSurface) async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        #if canImport(FluidAudio)
        // Force Nemotron before anything is created — a failure here must leave no
        // half-started meeting behind. AppState surfaces the reason via errorMessage.
        guard await AppState.shared.prepareMeetingBackend() else { return }
        guard !isRecording else { return }   // re-check: the await above yielded
        #endif

        // Increment before any await — invalidates stale onChunkCompleted closures
        // that captured the previous generation and may still be in-flight.
        chunkGeneration += 1

        // Clear ALL stale state immediately — before any await so no old data
        // leaks into the view during the async CoreData round-trip.
        silenceFlushTask?.cancel()
        silenceFlushTask = nil
        meetingID = nil
        segments = []
        notes = []
        livePreviewText = ""
        currentSegmentText = ""
        currentSegmentStartTimestamp = 0
        lastChunkEndTimestamp = 0
        elapsedSeconds = 0
        currentSpeakerIndex = 0
        currentSpeakerName = "Speaker 1"
        liveSpeakerIndex = 0
        liveSpeakerName = "Speaker 1"
        hasSpeakerSignal = false
        speakerNames = [:]

        let language = await AppState.shared.selectedLanguage.rawValue
        let model = await AppState.shared.selectedModel.rawValue

        let id = await MeetingManager.shared.beginSession(
            title: title,
            language: language,
            modelUsed: model
        )

        // Set live state last — meetingID triggers onChange in MeetingStudioView.
        // segments is already [] so no flash of old data when view switches.
        meetingID = id
        isRecording = true
        recordingStartDate = Date()

        startElapsedTimer()
        AppState.shared.startMeetingRecording(session: self, surface: surface)
    }

    func stopRecording() async {
        guard isRecording, let id = meetingID else { return }
        isRecording = false
        silenceFlushTask?.cancel()
        silenceFlushTask = nil
        stopElapsedTimer()

        AppState.shared.stopMeetingRecording()

        // Show the processing indicator from the instant the LIVE badge goes away, so the
        // transition never reads as "the app stopped doing anything".
        MeetingManager.shared.setProcessing(.finalizing, for: id)

        // Flush any remaining accumulated + live text as the final segment.
        let tail = [currentSegmentText, livePreviewText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !tail.isEmpty {
            currentSegmentText = tail
            // elapsedSeconds is the wall-clock display counter; lastChunkEndTimestamp is the
            // audio clock. Take the later so the final card reaches the end of the recording
            // whichever one is ahead.
            closeSegment(endTimestamp: max(lastChunkEndTimestamp, elapsedSeconds), policy: .commitAll)
        }
        currentSegmentText = ""
        livePreviewText = ""

        // Pending sidecar fully handled by the final flush above — clear for safety.
        MeetingPendingStore.clear(meetingID: id)

        // Move the session audio file from Sessions/ into Meetings/ so MeetingRecord.resolvedAudioURL finds it.
        let audioFileName = AppState.shared.meetingAudioFileURL
        var audioURL: URL?
        if let filename = audioFileName {
            audioURL = moveAudioToMeetingsDirectory(filename: filename)
        }

        let capturedAudioURL = audioURL

        await MeetingManager.shared.finalizeSession(
            meetingID: id,
            duration: elapsedSeconds,
            audioFileURL: audioFileName
        )

        // Trigger AI cleanup + naming + overview in background.
        // Order: cleanup first so title and summary are generated from corrected text.
        let currentTitle = MeetingManager.shared.meetings.first(where: { $0.id == id })?.title ?? ""

        // Inherits @MainActor, so the phase updates land on the main actor between awaits.
        Task { [weak self] in
            // Everything below is built from the transcript, so it has to wait for the last
            // of it. The backend's tail chunk is delivered *after* stopRecording() returns
            // (see awaitTailDelivery) — snapshotting `segments` here would summarize, name
            // and re-transcribe a meeting missing its final card. The refiner defends itself
            // by re-reading CoreData, but the two skip paths below never reach it.
            await self?.awaitTailDelivery()
            guard let self else { return }

            let finalSegments = self.segments
            let transcript = finalSegments.map { $0.text }.joined(separator: " ")
            let willPolish = MeetingTranscriptRefiner.shared.shouldRun(for: finalSegments, audioURL: capturedAudioURL)
            Logger.info("Meeting session stop: segments=\(finalSegments.count), transcript=\(transcript.count) chars, polish=\(willPolish)", subsystem: .transcription)

            guard !transcript.isEmpty else {
                // A recording stopped within a couple of seconds legitimately has nothing to
                // summarize. Only a longer one that produced no text points at a real bug.
                if finalSegments.isEmpty && self.elapsedSeconds < 2 {
                    Logger.debug("Meeting session stop: nothing recorded — overview skipped", subsystem: .transcription)
                } else {
                    Logger.warning("Meeting session stop: transcript empty — overview skipped (did chunks arrive?)", subsystem: .transcription)
                }
                MeetingManager.shared.setProcessing(nil, for: id)
                return
            }

            // Scope for the LLM borrow's `defer` — it must release before the Task ends,
            // and after the last generation, not at some later suspension point.
            do {
                // 1. Cleanup (re-transcription)
                MeetingManager.shared.setProcessing(.polishing, for: id)
                var segmentsForSummary = finalSegments
                if willPolish {
                    if let reason = MeetingTranscriptRefiner.shared.blockingReason(for: id, audioURL: capturedAudioURL) {
                        Logger.warning("Meeting session stop: cleanup skipped — \(reason)", subsystem: .transcription)
                        MeetingManager.shared.setProcessing(.polishing, notice: "Cleanup skipped — model not downloaded", for: id)
                    } else {
                        segmentsForSummary = await MeetingTranscriptRefiner.shared.run(
                            meetingID: id, segments: finalSegments
                        )
                        self.applyRefined(segmentsForSummary, meetingID: id)
                    }
                }

                // Title and overview run under ONE outer LLM borrow.
                //
                // Each MeetingAIService call borrows and releases on its own, and a release
                // that drops the refcount to zero arms a 60s idle unload. Holding an outer
                // borrow across both keeps the count ≥ 1 for the whole sequence, so the 3.2 GB
                // model cannot unload between them and be paid for twice. Taken *after* the
                // cleanup pass, not before: the refiner loads its own multi-GB Whisper model
                // and gates on free memory, so keeping the LLM resident across it would work
                // against that check.
                #if canImport(FluidAudio)
                let llmHeld = await MeetingEngines.shared.borrowLLM() != nil
                defer { if llmHeld { MeetingEngines.shared.releaseLLM() } }
                #endif

                // 2. Title: a short generation — the library row picks up a real name in a
                // couple of seconds instead of waiting out the full summary pass.
                MeetingManager.shared.setProcessing(.naming, for: id)
                await MeetingAIService.shared.generateTitle(
                    segments: segmentsForSummary, meetingID: id, currentTitle: currentTitle
                )

                // 3. Overview — check intelligence engine readiness to surface a notice when
                // the model is not available, so the user knows why no summary appears.
                let intelligenceNotice: String?
                #if canImport(FluidAudio)
                switch MeetingEngines.shared.readiness[.intelligence] {
                case .needsDownload:
                    intelligenceNotice = "Summary skipped — meeting intelligence not downloaded"
                case .unavailable(let msg):
                    intelligenceNotice = "Summary skipped — \(msg)"
                default:
                    intelligenceNotice = nil
                }
                #else
                intelligenceNotice = nil
                #endif

                MeetingManager.shared.setProcessing(.summarizing, notice: intelligenceNotice, for: id)
                await MeetingAIService.shared.generateOverview(segments: segmentsForSummary, meetingID: id)
                MeetingManager.shared.setProcessing(nil, for: id)
            }
        }

        // Clear transient live state — segments kept for post-recording display via CoreData.
        // meetingID is intentionally NOT cleared here. The tail transcription from
        // StreamingTranscriber arrives asynchronously after finalizeSession completes, and
        // onNewChunk guards on `meetingID != nil`. Clearing it here would drop the tail chunk.
        // The next startRecording() call resets meetingID before the CoreData round-trip.
        currentSegmentText = ""
        livePreviewText = ""
    }

    /// Waits until the backend's final chunk has landed **and** reached CoreData.
    ///
    /// `stopRecording()` returns while `AppState.stopInAppRecording()`'s Task is still draining:
    /// the tail arrives afterwards through `onNewChunk` / `onAttributedText` and appends one
    /// more card. `AppState` nils `activeMeetingSession` immediately after `stopAsync()` and the
    /// diarizer's `finish()` have returned, precisely so that assignment can be read as "the
    /// tail has been delivered". Then drain `pendingPersistence` — `MeetingTranscriptRefiner`
    /// re-reads the record from CoreData, and would otherwise rewrite the whole `segmentsJSON`
    /// blob from a copy that predates the tail row.
    ///
    /// Bounded because `stopInAppRecording` already caps `stopAsync()` at 10s. The ceiling only
    /// expires when its `guard case .recording` bailed out and the nil-assignment never ran, so
    /// reaching it is worth a warning rather than a silent extra wait.
    private func awaitTailDelivery() async {
        let deadline = Date().addingTimeInterval(12)
        while AppState.shared.activeMeetingSession === self {
            guard Date() < deadline else {
                Logger.warning("Meeting session stop: tail delivery timed out — proceeding without it", subsystem: .transcription)
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await pendingPersistence?.value
    }

    /// Swap in the polished transcript.
    ///
    /// `MeetingDetailView` renders `session.segments` until the persisted copy has caught up
    /// with it, so without this the live→persisted handoff would keep showing the raw text
    /// until the next detail refresh. Guarded on the meeting ID: a run that finishes after the
    /// user started recording something else must not overwrite the new session's segments.
    func applyRefined(_ refined: [MeetingSegment], meetingID id: UUID) {
        guard meetingID == id, !isRecording, !refined.isEmpty else { return }
        segments = refined
    }

    func cancelRecording() async {
        guard isRecording, let id = meetingID else { return }
        isRecording = false
        silenceFlushTask?.cancel()
        silenceFlushTask = nil
        stopElapsedTimer()
        livePreviewText = ""
        currentSegmentText = ""
        currentSegmentStartTimestamp = 0
        lastChunkEndTimestamp = 0
        currentSpeakerIndex = 0
        currentSpeakerName = "Speaker 1"
        liveSpeakerIndex = 0
        liveSpeakerName = "Speaker 1"
        hasSpeakerSignal = false
        speakerNames = [:]
        MeetingPendingStore.clear(meetingID: id)
        meetingID = nil
        segments = []
        AppState.shared.stopMeetingRecording()
        await MeetingManager.shared.discardSession(meetingID: id)
    }

    /// Tear down a meeting whose recording never actually ran — a failed audio start, or a
    /// watchdog force-idle.
    ///
    /// Deliberately not `cancelRecording()`, which is the user's explicit discard and routes
    /// through `AppState.stopMeetingRecording()`. There is no stop to perform here, and that
    /// path latches `isMeetingStopInFlight = true` with no `stopInAppRecording()` behind it to
    /// clear it — the next dictation would then route its chunks as a meeting tail.
    ///
    /// The CoreData row `beginSession` created moments ago is still `isInProgress`. Left as it
    /// is, it returns on the next launch as "crash recovery: finalizing 1 interrupted session".
    /// So it is discarded when it holds nothing at all — the failed-start case, where no audio
    /// was ever captured — and otherwise finalized. Never deleted with content in it.
    func abandonRecording() async {
        guard isRecording || meetingID != nil else { return }

        let id = meetingID
        let hadContent = !segments.isEmpty
            || !currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        isRecording = false
        silenceFlushTask?.cancel()
        silenceFlushTask = nil
        stopElapsedTimer()
        livePreviewText = ""
        currentSegmentText = ""
        currentSegmentStartTimestamp = 0
        lastChunkEndTimestamp = 0
        currentSpeakerIndex = 0
        currentSpeakerName = "Speaker 1"
        liveSpeakerIndex = 0
        liveSpeakerName = "Speaker 1"
        hasSpeakerSignal = false
        speakerNames = [:]

        guard let id else { return }
        MeetingPendingStore.clear(meetingID: id)
        MeetingManager.shared.setProcessing(nil, for: id)

        if hadContent {
            await MeetingManager.shared.finalizeSession(
                meetingID: id,
                duration: elapsedSeconds,
                audioFileURL: nil
            )
        } else {
            meetingID = nil
            segments = []
            await MeetingManager.shared.discardSession(meetingID: id)
        }
    }

    // MARK: - Chunk callback (called from AppState)

    /// `start`/`end` are seconds on the **audio clock** (samples received / sample rate),
    /// so they line up with the recorded `.m4a` used for playback and are unaffected by
    /// inference latency.
    func onNewChunk(text: String, start: Double, end: Double) {
        // whisper.cpp emits one chunk per voiced VAD segment, so chunk *arrival* really does
        // track speech — the idle timer is a valid pause signal on this path.
        accumulate(text: text, start: start, end: end, idleFlushTracksSpeech: true)
    }

    /// Nemotron + Sortformer path: `text` is already attributed to a speaker.
    ///
    /// A speaker change closes the current paragraph at the boundary — that is what turns
    /// the transcript into per-turn cards instead of one wall of text.
    func onAttributedText(text: String, speakerIndex: Int, startTimestamp: Double, endTimestamp: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, meetingID != nil else { return }

        if speakerIndex != currentSpeakerIndex {
            // Close at the last voiced sample of the previous turn, not at this turn's start —
            // a pause between speakers belongs to neither card.
            let boundary = max(lastChunkEndTimestamp, currentSegmentStartTimestamp)
            if isSubstantial(currentSegmentText, from: currentSegmentStartTimestamp, to: boundary) {
                silenceFlushTask?.cancel()
                silenceFlushTask = nil
                // `.commitAll`: a different person is talking now, so no remainder may carry.
                closeSegment(endTimestamp: boundary, policy: .commitAll)
            }
            // Otherwise the open card is too small to defend its own label, so a change here is
            // likelier a diarizer wobble than a turn — and committing would leave a two-word
            // orphan mid-sentence, the exact outcome the gap rule already declines to cause.
            // Falling through re-labels the open card instead: the newest attribution is at
            // least as good as whatever produced a sub-floor card, and a genuine one-word
            // interjection gets absorbed rather than mislabelling everything said after it.
            // This was the last unguarded break in the file — see `SegmentBreakPolicy`.
            currentSpeakerIndex = speakerIndex
            currentSpeakerName = speakerName(for: speakerIndex)
        }
        // Attributed text is stronger evidence than a tentative segment — realign the
        // live label so the bubble can't sit on a speaker the transcript disagrees with.
        liveSpeakerIndex = speakerIndex
        liveSpeakerName = currentSpeakerName
        hasSpeakerSignal = true

        // No idle flush here: on this path text arrival is gated by the diarizer, not by
        // speech. See `accumulate(idleFlushTracksSpeech:)`.
        accumulate(text: trimmed, start: startTimestamp, end: endTimestamp, idleFlushTracksSpeech: false)
    }

    /// Shared accumulation used by both the whisper VAD-chunk path and the attributed
    /// Nemotron path. Kept in one place so the two can't drift on flush rules.
    ///
    /// - Parameter idleFlushTracksSpeech: whether a gap in *arrival* is evidence that the
    ///   speaker stopped. True for whisper VAD chunks. **False for the attributed path**:
    ///   `MeetingSpeakerCoordinator` withholds text until Sortformer's finalized timeline
    ///   covers it, and Sortformer only finalizes a turn when it *closes* — so during an
    ///   unbroken monologue text arrives in bursts at every micro-breath. Treating those
    ///   arrival gaps as pauses chopped a 48s continuous recording into seven cards.
    private func accumulate(text: String, start: Double, end: Double, idleFlushTracksSpeech: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard on meetingID rather than isRecording so the tail chunk delivered
        // after isRecording=false (during stop drain) still accumulates.
        guard !trimmed.isEmpty, meetingID != nil else { return }

        livePreviewText = ""  // chunk committed — clear the live tail

        // Clamp: an out-of-order or overlapping span would otherwise produce a segment
        // that runs backwards on the timeline.
        let chunkStart = max(0, start)
        let chunkEnd = max(chunkStart, end)

        if currentSegmentText.isEmpty {
            currentSegmentStartTimestamp = chunkStart
        } else if chunkStart - lastChunkEndTimestamp >= silenceSplitGap {
            // The speaker paused — or the diarizer's finalized timeline has a hole, which is
            // the same thing on the audio clock. `.softBreak` makes the text arbitrate.
            closeSegment(endTimestamp: lastChunkEndTimestamp, policy: .softBreak)
            // A declined break, or one that carried a remainder forward, leaves the paragraph
            // open — only restart the clock when the card actually closed empty.
            if currentSegmentText.isEmpty { currentSegmentStartTimestamp = chunkStart }
        }

        currentSegmentText += currentSegmentText.isEmpty ? trimmed : " " + trimmed
        lastChunkEndTimestamp = chunkEnd

        // Persist accumulated text so it survives a crash before the next flush.
        if let id = meetingID {
            MeetingPendingStore.save(meetingID: id, text: currentSegmentText, startTimestamp: currentSegmentStartTimestamp)
        }

        // Late tail arriving during the stop drain — nothing will flush it later.
        // stopRecording() already committed livePreviewText, which usually holds these
        // same words, so drop whatever overlaps before adding a card.
        guard isRecording else {
            drainTailChunk(endTimestamp: chunkEnd)
            return
        }

        if chunkEnd - currentSegmentStartTimestamp >= maxSegmentDuration {
            silenceFlushTask?.cancel()
            silenceFlushTask = nil
            closeSegment(endTimestamp: chunkEnd, policy: .capBreak)
        } else if idleFlushTracksSpeech {
            // Reset silence timer: if no new chunk arrives within 2.5s, flush the
            // current paragraph. The gap check above only fires once the *next* chunk
            // lands, so this is what closes the card during a long pause.
            scheduleSilenceFlush()
        } else {
            // Attributed path: the card stays open until a real audio-clock gap arrives with
            // the next item, the 30s cap trips, or the speaker changes. Nothing is lost while
            // it is open — the live bubble renders `currentSegmentText`, and every accumulate
            // writes it to MeetingPendingStore for crash recovery.
            silenceFlushTask?.cancel()
            silenceFlushTask = nil
        }
    }

    private func scheduleSilenceFlush() {
        silenceFlushTask?.cancel()
        guard isRecording else { return }
        silenceFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.isRecording, !self.currentSegmentText.isEmpty else { return }
            self.closeSegment(endTimestamp: self.lastChunkEndTimestamp, policy: .softBreak)
        }
    }

    private func drainTailChunk(endTimestamp: Double) {
        guard let id = meetingID else { return }
        let previous = segments.last?.text ?? ""
        let unique = previous.isEmpty
            ? currentSegmentText
            : VADSegmenter.deduplicateOverlap(previousText: previous, newText: currentSegmentText)
        currentSegmentText = unique.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentSegmentText.isEmpty else {
            MeetingPendingStore.clear(meetingID: id)
            return
        }
        // Nothing follows the tail, so there is nowhere for a remainder to be carried to.
        closeSegment(endTimestamp: endTimestamp, policy: .commitAll)
    }

    // MARK: - Segment flushing

    /// How much a proposed paragraph boundary may be trusted, and therefore how hard the
    /// close tries to land it on a sentence end.
    ///
    /// A break derived from *arrival* timing is a hypothesis, not a fact: the gap rule cannot
    /// tell real silence from a hole in Sortformer's finalized timeline, which
    /// `MeetingSpeakerCoordinator.voicedRuns` reports verbatim and `emit()` then apportions
    /// words across. That is how a single sentence got cut into a 7-word orphan card and a
    /// continuation. The text is the only signal that survives both backends, so a soft break
    /// has to prove itself against it.
    private enum SegmentBreakPolicy {
        /// Gap rule and idle timer. Breaks only at a sentence end that clears both size
        /// floors; otherwise leaves the card open.
        case softBreak
        /// The 30s cap. Must produce a card, but carries a trailing incomplete sentence
        /// forward when the complete part stands on its own.
        case capBreak
        /// Speaker change, stop, tail drain. Commits everything as-is — no carry, no floors.
        case commitAll
    }

    private func closeSegment(endTimestamp: Double, policy: SegmentBreakPolicy) {
        let text = currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let start = currentSegmentStartTimestamp
        let end = max(endTimestamp, start)

        if policy != .commitAll, let split = Self.splitAtLastSentenceEnd(text) {
            // Same character-share arithmetic `splitByDuration` uses: with no word-level
            // timings, a prefix holding 60% of the characters gets 60% of the span.
            let cut = split.remainder.isEmpty
                ? end
                : start + (end - start) * Double(split.complete.count) / Double(text.count)
            if isSubstantial(split.complete, from: start, to: cut) {
                commitSegment(text: split.complete, start: start, end: cut,
                              carrying: split.remainder, from: cut)
                return
            }
        }

        // No honest cut available. A soft break declines rather than forcing one; the cap
        // and the hard breaks have to commit regardless.
        guard policy != .softBreak else { return }
        commitSegment(text: text, start: start, end: end, carrying: nil, from: end)
    }

    /// Whether a span earns its own card. A two-second, seven-word fragment is noise — it
    /// belongs to the paragraph around it, not beside it.
    private func isSubstantial(_ text: String, from start: Double, to end: Double) -> Bool {
        guard end - start >= minSegmentDuration else { return false }
        return text.split(separator: " ", omittingEmptySubsequences: true).count >= minSegmentWords
    }

    /// Commits `text` as one or more cards and rolls the open paragraph forward.
    ///
    /// `remainder` is the trailing incomplete sentence a break chose not to cut through. It
    /// becomes the new open card starting at `remainderStart`, and is **re-saved** to
    /// `MeetingPendingStore` rather than cleared — an uncommitted remainder is exactly the
    /// text a crash would otherwise lose.
    private func commitSegment(text: String, start: Double, end: Double,
                               carrying remainder: String?, from remainderStart: Double) {
        guard let id = meetingID else { return }

        let pieces = Self.splitByDuration(text: text, start: start, end: end, cap: maxSegmentDuration)
        let newSegments = pieces.map {
            MeetingSegment(
                timestamp: $0.start,
                endTimestamp: $0.end,
                text: $0.text,
                speakerName: speakerName(for: currentSpeakerIndex),
                speakerIndex: currentSpeakerIndex
            )
        }
        segments.append(contentsOf: newSegments)

        let carried = (remainder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        currentSegmentText = carried
        currentSegmentStartTimestamp = carried.isEmpty ? end : remainderStart
        lastChunkEndTimestamp = max(lastChunkEndTimestamp, end)
        // Committed text is in CoreData; the sidecar now holds only what is still open
        // (empty text clears the file). This runs before the Task so no new chunk's save
        // can race with a stale write.
        MeetingPendingStore.save(meetingID: id, text: carried, startTimestamp: currentSegmentStartTimestamp)
        let duration = max(end, elapsedSeconds)
        let previous = pendingPersistence
        pendingPersistence = Task {
            await previous?.value
            for segment in newSegments {
                await MeetingManager.shared.appendSegment(
                    meetingID: id,
                    segment: segment,
                    duration: duration
                )
            }
        }
    }

    // MARK: - Duration-bounded splitting

    /// Splits an over-long span into pieces of at most `cap` seconds.
    ///
    /// Chunk cadence is a property of the backend, not of the speech: the whisper.cpp VAD
    /// path emits a chunk per voiced segment, WhisperKit commits roughly every six seconds,
    /// and Nemotron hands back the entire meeting in one blob at stop. Enforcing the cap only
    /// at chunk arrival would leave that last case as one unreadable card.
    ///
    /// Without word-level timings the only honest mapping is proportional — speech rate is
    /// near-constant, so a piece holding 40% of the characters gets 40% of the span. Cuts
    /// prefer sentence boundaries and fall back to words when the text is unpunctuated.
    static func splitByDuration(text: String, start: Double, end: Double, cap: Double)
        -> [(text: String, start: Double, end: Double)] {

        let whole = [(text: text, start: start, end: end)]
        let span = end - start
        guard cap > 0, span > cap else { return whole }

        let pieceCount = max(2, Int(ceil(span / cap)))
        var units = sentenceUnits(text)
        if units.count < pieceCount { units = wordUnits(text) }
        guard units.count >= 2 else { return whole }

        let totalChars = units.reduce(0) { $0 + $1.count }
        guard totalChars > 0 else { return whole }
        let target = Double(totalChars) / Double(pieceCount)

        var groups: [String] = []
        var buffer = ""
        for unit in units {
            buffer += unit
            if groups.count < pieceCount - 1, Double(buffer.count) >= target {
                groups.append(buffer)
                buffer = ""
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { groups.append(buffer) }
        guard groups.count > 1 else { return whole }

        var result: [(text: String, start: Double, end: Double)] = []
        var consumed = 0
        for (index, group) in groups.enumerated() {
            let pieceStart = start + span * Double(consumed) / Double(totalChars)
            consumed += group.count
            // Pin the last piece to `end` so rounding never leaves a gap at the tail.
            let pieceEnd = index == groups.count - 1
                ? end
                : start + span * Double(consumed) / Double(totalChars)
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append((trimmed, pieceStart, pieceEnd))
            }
        }
        return result.isEmpty ? whole : result
    }

    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", "\n", "。", "！", "？", "؟"
    ]

    /// Text broken after each sentence terminator; the terminator stays with its sentence.
    private static func sentenceUnits(_ text: String) -> [String] {
        var units: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if sentenceTerminators.contains(character) {
                units.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { units.append(current) }
        return units
    }

    /// Closing marks that belong to the sentence they follow, not to the next one.
    private static let sentenceClosers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»", "」"]

    /// Splits `text` after its last sentence end.
    ///
    /// Returns `nil` when there is no usable terminator — one unbroken run with no honest
    /// place to cut. A fully-terminated text returns an empty `remainder`.
    ///
    /// A terminator only counts when whitespace or the end of the string follows it, so the
    /// `.` in "3.5 million" or "e.g." is not mistaken for a sentence end and the number is
    /// not cut in half.
    static func splitAtLastSentenceEnd(_ text: String) -> (complete: String, remainder: String)? {
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            guard sentenceTerminators.contains(text[index]) else { continue }

            var cut = text.index(after: index)
            while cut < text.endIndex, sentenceClosers.contains(text[cut]) { cut = text.index(after: cut) }
            guard cut == text.endIndex || text[cut].isWhitespace else { continue }

            let complete = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !complete.isEmpty else { return nil }
            return (complete, String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Fallback for speech with no punctuation — common in raw whisper output.
    private static func wordUnits(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map { String($0) + " " }
    }

    // MARK: - Speaker management

    private func speakerName(for index: Int) -> String {
        speakerNames[index] ?? "Speaker \(index + 1)"
    }

    /// Tentative speaker report from the diarizer. Deliberately does **not** touch
    /// `currentSpeakerIndex`: tentative segments flip around, and a flush triggered by one
    /// would fragment the transcript into cards that later turn out to be the same speaker.
    func noteLiveSpeaker(_ index: Int) {
        hasSpeakerSignal = true
        guard index != liveSpeakerIndex else { return }
        liveSpeakerIndex = index
        liveSpeakerName = speakerName(for: index)
    }

    /// Applies a rename to the **live** session copy: every segment that speaker owns, plus
    /// the label future flushes will use. A per-card rename would leave the same person
    /// under two names in one transcript.
    ///
    /// In-memory only — persistence is the caller's job (`MeetingManager.renameSpeaker`),
    /// so the CoreData write isn't issued twice.
    func updateSpeaker(segmentID: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The renamed card may already have handed over to CoreData, in which case the
        // session no longer holds it — fall back to the speaker currently being recorded.
        let speakerIndex = segments.first(where: { $0.id == segmentID })?.speakerIndex
            ?? currentSpeakerIndex

        // Recorded so segments flushed later in this same recording inherit the new name.
        speakerNames[speakerIndex] = trimmed
        for i in segments.indices where segments[i].speakerIndex == speakerIndex {
            segments[i].speakerName = trimmed
        }
        if speakerIndex == currentSpeakerIndex { currentSpeakerName = trimmed }
        if speakerIndex == liveSpeakerIndex { liveSpeakerName = trimmed }
    }

    // MARK: - Notes

    func addNote(kind: NoteKind) {
        let note = MeetingNote(kind: kind, timestamp: elapsedSeconds)
        notes.append(note)
        persistNotes()
    }

    func updateNote(_ note: MeetingNote) {
        if let idx = notes.firstIndex(where: { $0.id == note.id }) {
            notes[idx] = note
        }
        persistNotes()
    }

    func deleteNote(id: UUID) {
        notes.removeAll { $0.id == id }
        persistNotes()
    }

    private func persistNotes() {
        guard let id = meetingID else { return }
        let snap = notes
        Task {
            await MeetingManager.shared.updateNotes(meetingID: id, notes: snap)
        }
    }

    // MARK: - Audio

    /// Returns the final location, which the re-transcription pass decodes from. Nil when there
    /// is no recording on disk — the move is best-effort and a missing file is not fatal here.
    @discardableResult
    private func moveAudioToMeetingsDirectory(filename: String) -> URL? {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let source = appSupport.appendingPathComponent("Whisperer/Sessions/\(filename)")
        let meetingsDir = appSupport.appendingPathComponent("Whisperer/Meetings")
        let dest = meetingsDir.appendingPathComponent(filename)

        if fm.fileExists(atPath: source.path) {
            try? fm.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
            try? fm.moveItem(at: source, to: dest)
        }
        return fm.fileExists(atPath: dest.path) ? dest : nil
    }

    // MARK: - Timer

    private func startElapsedTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    // Display counter only. Segment boundaries are placed on the audio
                    // clock in onNewChunk / flushCurrentSegment, never on this one.
                    self.elapsedSeconds += 1
                }
            }
        }
    }

    private func stopElapsedTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Elapsed display

    var elapsedDisplay: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

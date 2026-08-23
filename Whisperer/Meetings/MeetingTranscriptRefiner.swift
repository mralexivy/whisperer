//
//  MeetingTranscriptRefiner.swift
//  Whisperer
//
//  Post-recording cleanup of a meeting transcript by re-transcribing the recorded
//  audio with a more accurate Whisper model. Raw live-ASR text is preserved in
//  MeetingSegment.rawText so the user can switch back.
//
//  Runs between the naming and summarizing phases so the overview and the Ask-AI
//  answers are built from the corrected text.
//
//  ### Why a second decode and not an LLM
//  This pass used to hand the finished transcript to the on-device LLM and ask it to fix
//  spelling, punctuation and "obvious mishearings". That is asking a language model to guess
//  what the audio said — it can pattern-match a plausible correction, it cannot hear. It also
//  needed a byte-identical system prompt (one warm KV slot), a 256-token cap, batch sizes
//  derived from that cap, a numbered `N| text` protocol with a two-strike fallback, a custom
//  script table for the token estimator and per-line strict validation to catch the model
//  rewriting lines it was told to leave alone.
//
//  The audio is still on disk. Re-running it through Whisperer V3 (WhisperModel.largeTurboQ5,
//  547 MB) replaces every guess with a real decode, and whisper's own punctuation and
//  capitalization come for free.
//

import Foundation
import Combine

@MainActor
final class MeetingTranscriptRefiner: ObservableObject {
    static let shared = MeetingTranscriptRefiner()

    // MARK: - Published progress
    //
    // Written at WINDOW granularity only. Every publish re-evaluates MeetingTranscriptView's
    // body, which reaches SelectableTranscriptView.updateNSView → recomputeMetrics() — a full
    // text layout enumeration. Once per window (~1-3s) is free; per segment would not be.

    /// 0…1 while a run is active, nil otherwise.
    @Published private(set) var progress: Double?
    /// Segments currently being re-transcribed — drives the shimmer sweep in the transcript.
    @Published private(set) var activeSegmentIDs: Set<UUID> = []
    /// Segments already handled in this run — drives the settled accent pulse.
    @Published private(set) var doneSegmentIDs: Set<UUID> = []
    /// Meeting the current run belongs to; nil when idle.
    @Published private(set) var activeMeetingID: UUID?
    /// Cards the last completed run decoded but could not accept, and the meeting they belong to,
    /// so the UI can say so instead of leaving the user to spot the untouched text themselves.
    /// Cleared when a run starts.
    @Published private(set) var uncorrected: (meetingID: UUID, count: Int)?

    private var runTask: Task<Void, Never>?
    private var cancelledMeetingID: UUID?

    private init() {}

    // MARK: - Tuning

    private static let sampleRate = 16000.0
    /// Whisper's training window. See `MeetingRefineWindow.plan`.
    private static let windowDuration = 30.0
    /// Audio prepended before each window so the first word is not clipped mid-utterance.
    private static let leadInSeconds = 0.5
    /// Context carried into the next window's `initial_prompt`, matching FileTranscriptionManager.
    private static let contextMaxLength = 100
    /// Below this, loading a second multi-GB model on top of the meeting backend risks a swap
    /// storm. Same threshold `AppState.prepareMeetingBackend()` uses.
    private static let minAvailableGB = 2.0
    /// A decode shorter than this is silence or a read error, not speech.
    private static let minWindowSamples = Int(0.2 * 16000.0)

    /// Model used for the pass. Deliberately independent of the dictation model: this runs
    /// after the meeting, off the latency path, so accuracy is the only thing that matters.
    /// Fixed at compile time — no per-user picker.
    static let cleanupModel: WhisperModel = .largeTurboQ5

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "meetingPolishEnabled") == nil
            || UserDefaults.standard.bool(forKey: "meetingPolishEnabled")
    }

    // MARK: - Preconditions

    /// True when a re-transcription pass is worth starting for these segments.
    ///
    /// Only answers "is there work to do?" — does NOT check whether the engine (model) is
    /// present. Use `blockingReason(for:audioURL:)` for the latter. `audioURL` is required:
    /// without the recording there is nothing to decode. Meetings recorded before audio
    /// retention, or whose file the user deleted, skip the pass entirely.
    func shouldRun(for segments: [MeetingSegment], audioURL: URL?) -> Bool {
        guard Self.isEnabled else { return false }
        guard let audioURL, FileManager.default.fileExists(atPath: audioURL.path) else { return false }
        return segments.contains { !$0.isPolished && $0.text.contains(where: { $0.isLetter }) }
    }

    /// Returns a human-readable reason string if the cleanup engine is not ready to run,
    /// or nil if the run should proceed. Returns nil for "nothing to clean up" — that is a
    /// silent correct exit, not a blocking condition.
    func blockingReason(for meetingID: UUID, audioURL: URL?) -> String? {
        // When a resident WhisperBridge matching the cleanup model is already loaded, the run()
        // path will borrow it — no download or warm pass required.
        if AppState.shared.whisperBridge is WhisperBridge,
           AppState.shared.loadedModelForDebug == Self.cleanupModel {
            return nil
        }
        #if canImport(FluidAudio)
        switch MeetingEngines.shared.readiness[.cleanup] {
        case .needsDownload(let msg):
            let detail = msg.isEmpty ? "Download Whisperer V3 (547 MB) from the Models tab." : msg
            return "Cleanup engine not ready — \(detail)"
        case .unavailable(let msg):
            return "Cleanup engine unavailable — \(msg)"
        default:
            return nil
        }
        #else
        if !ModelDownloader.shared.isModelDownloaded(Self.cleanupModel) {
            return "\(Self.cleanupModel.displayName) is not downloaded — get it in the Models tab."
        }
        return nil
        #endif
    }

    // MARK: - Run

    /// Re-transcribe `segments` from the meeting audio and return the new array. Persists each
    /// window as it completes, so a quit mid-run loses at most one window. Returns the best
    /// array it has on cancellation or failure — never nil, never a partial mix.
    ///
    /// - Parameter forcedLanguage: set by the user correcting the language chip. Skips detection
    ///   entirely and resets every card back to its raw ASR text first, so the re-decode starts
    ///   from what was heard rather than from a previous pass's translation of it.
    /// - Parameter redoAll: reset and re-decode every card while still detecting the language.
    ///   What "Re-transcribe" has always claimed to do — without it the pending filter skips every
    ///   already-polished card, so the button could only ever fill gaps a previous pass missed.
    @discardableResult
    func run(meetingID: UUID, segments: [MeetingSegment],
             forcedLanguage: TranscriptionLanguage? = nil, redoAll: Bool = false) async -> [MeetingSegment] {
        // Re-read from CoreData rather than trusting the caller's snapshot. The tail chunk
        // from StreamingTranscriber lands *after* stopRecording() returns and appends one more
        // segment; refining a stale array and then writing it back with updateSegments would
        // erase that card. The record also carries the audio path.
        let record = await MeetingManager.shared.meeting(id: meetingID)
        let persisted = record?.segments ?? []
        let source = persisted.count >= segments.count ? persisted : segments

        cancelledMeetingID = nil
        activeMeetingID = meetingID
        uncorrected = nil
        progress = 0
        activeSegmentIDs = []
        doneSegmentIDs = []
        defer {
            progress = nil
            activeSegmentIDs = []
            doneSegmentIDs = []
            activeMeetingID = nil
        }

        guard let audioURL = record?.resolvedAudioURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            Logger.warning("Transcript refine: no audio on disk for \(meetingID) — skipped", subsystem: .transcription)
            return finish(source, meetingID: meetingID)
        }

        let available = SystemMemory.availableGB()
        guard available >= Self.minAvailableGB else {
            Logger.warning("Transcript refine: only \(String(format: "%.1f", available))GB free — skipped", subsystem: .transcription)
            return finish(source, meetingID: meetingID)
        }

        let model = Self.cleanupModel
        if let reason = blockingReason(for: meetingID, audioURL: record?.resolvedAudioURL) {
            Logger.warning("Transcript refine: \(reason) — skipped", subsystem: .transcription)
            return finish(source, meetingID: meetingID)
        }

        var working = source
        if forcedLanguage != nil || redoAll {
            // Undo the previous pass so `isPolished` goes false and every window decodes again.
            // Without this the pending filter below would skip the whole meeting, and the cards
            // that *were* re-decoded would be corrections of a translation rather than of speech.
            for index in working.indices {
                // `language` is cleared on *every* card, not only the rewritten ones: a card can
                // carry a stamp from a pass that rejected its decode, and leaving that behind
                // means the run it is about to start starts from a claim that was never true.
                working[index].language = nil
                guard working[index].rawText != nil else { continue }
                working[index].text = working[index].rawText ?? working[index].text
                working[index].rawText = nil
            }
        }
        let windows = MeetingRefineWindow.plan(working, maxDuration: Self.windowDuration)
        guard !windows.isEmpty else {
            Logger.info("Transcript refine: nothing to do for \(meetingID)", subsystem: .transcription)
            return finish(working, meetingID: meetingID)
        }

        // Loading is its own queue job so it cannot overlap the meeting backend's own teardown.
        let modelPath = ModelDownloader.shared.modelPath(for: model)
        // Borrow the resident bridge when it matches the cleanup model — avoids a ~2s reload
        // and keeps the user's bridge warm for their next dictation recording. Per-window
        // ModelWorkQueue("meeting-refine") already serialises decodes against dictation, so a
        // borrowed bridge cannot be re-entered mid-decode.
        let residentBridge = AppState.shared.whisperBridge as? WhisperBridge
        let canBorrow = residentBridge != nil && AppState.shared.loadedModelForDebug == model
        let bridge: WhisperBridge
        let ownsBridge: Bool
        if let borrowed = residentBridge, canBorrow {
            bridge = borrowed
            ownsBridge = false
            Logger.info("Transcript refine: borrowing resident \(model.displayName) bridge for \(meetingID)", subsystem: .transcription)
        } else {
            do {
                // `runBlocking`, not `run`: this is blocking C, and on the first launch after a
                // model is installed it is a ~40s synchronous-XPC CoreML/ANE encoder compile.
                bridge = try await ModelWorkQueue.shared.runBlocking("meeting-refine-load") {
                    try WhisperBridge(modelPath: modelPath, useGPU: true)
                }
            } catch {
                Logger.error("Transcript refine: failed to load \(model.displayName): \(error.localizedDescription)", subsystem: .transcription)
                return finish(working, meetingID: meetingID)
            }
            ownsBridge = true
        }
        defer { if ownsBridge { bridge.prepareForShutdown() } }

        // A borrowed bridge arrives with whatever abort state the last owner left on it, and a
        // set flag is silent: `encoder_begin_callback` skips the encode, `whisper_full` returns 0
        // with no segments, and the pass "succeeds" having decoded nothing. We are the start of a
        // new operation, so the flag is ours to clear regardless of who set it.
        bridge.resetAbort()

        Logger.info("Transcript refine: \(windows.count) window(s) over \(working.count) segment(s) with \(model.displayName) for \(meetingID)", subsystem: .transcription)

        // Which language each window is decoded in.
        //
        // This used to be "auto-detect on window #1, then pin the rest of the meeting to it".
        // That gave the pass exactly one chance to be right, and being wrong is not a degraded
        // transcript but a translated one — Whisper handed a wrong forced code emits fluent text
        // in that language instead of failing, and `isPlausible` below only compares lengths.
        //
        // The timeline replaces that with evidence from probes spread over the whole recording,
        // smoothed so a single mis-detected window cannot move it, and expressed per span so a
        // genuinely code-switched stretch decodes in its own language. It abstains to `.auto`
        // where the evidence is weak, which is exactly the old per-window behaviour and is safe.
        let timeline: MeetingLanguageTimeline
        if let forcedLanguage, forcedLanguage != .auto {
            timeline = .empty
            Logger.info("Transcript refine: language forced to \(forcedLanguage.displayName) by the user", subsystem: .transcription)
        } else if AppState.shared.selectedLanguage == .auto {
            let liveTally = AppState.shared.lastMeetingNemotronTally
            timeline = await Self.buildTimeline(
                audioURL: audioURL,
                duration: record?.duration ?? (working.last?.endTimestamp ?? 0),
                segments: working,
                confirmBridge: bridge,
                nemotronTally: liveTally?.meetingID == meetingID ? liveTally?.tally ?? [:] : [:]
            )
            if timeline.dominant != .auto {
                await MeetingManager.shared.updateLanguage(meetingID: meetingID, language: timeline.dominant.rawValue)
            }
        } else {
            timeline = .empty
        }
        /// Language forced when the timeline has nothing to say for a window: the user's explicit
        /// selection, or `.auto` to let whisper detect per window as before.
        let baseLanguage = forcedLanguage ?? AppState.shared.selectedLanguage
        var context = ""
        var rewritten = 0
        var rejected = 0
        // A window that decodes to nothing is not an outcome the accept/reject counters can
        // express — it increments neither, so a whole pass of them reads as "0 rewritten, 0 kept"
        // and looks like there was simply nothing to do. Counted separately so it cannot hide.
        var silent = 0
        let t0 = Date()

        for (windowIndex, window) in windows.enumerated() {
            if Task.isCancelled || cancelledMeetingID == meetingID { break }

            // A window whose cards were all handled by an earlier run costs a full decode for
            // nothing. Its text still feeds the next window's prompt.
            let pending = window.segmentIndices.filter { !working[$0].isPolished }
            guard !pending.isEmpty else {
                context = Self.carry(context, appending: window.segmentIndices.map { working[$0].text })
                markDone(window, in: working)
                progress = Double(windowIndex + 1) / Double(windows.count)
                continue
            }

            activeSegmentIDs = Set(window.segmentIndices.map { working[$0].id })

            // Sample indices are on whisper's 16 kHz clock. The meeting file is Ogg Opus, which
            // always reports 48 kHz through `AVAudioFile` regardless of the rate it was encoded
            // at, so `readFloat32Window` does the seek and the resample rate-relative.
            let bufferStart = max(0, window.start - Self.leadInSeconds)
            let samples = SessionStorage.readFloat32Window(
                from: audioURL,
                startSample: Int(bufferStart * Self.sampleRate),
                endSample: Int((window.end * Self.sampleRate).rounded(.up))
            )
            guard samples.count >= Self.minWindowSamples else {
                Logger.debug("Transcript refine: window \(windowIndex + 1) has no readable audio", subsystem: .transcription)
                markDone(window, in: working)
                activeSegmentIDs = []
                progress = Double(windowIndex + 1) / Double(windows.count)
                continue
            }

            let prompt = context.isEmpty ? nil : String(context.suffix(Self.contextMaxLength))
            // Windows come from `MeetingRefineWindow.plan`, so spans align to them for free.
            // The midpoint, not the start, so a window straddling a span boundary follows
            // whichever language owns most of it.
            let spanLanguage = timeline.language(at: (window.start + window.end) / 2)
            let fixedLanguage = spanLanguage == .auto ? baseLanguage : spanLanguage
            let timed: [WhisperTimedSegment]
            do {
                // One queue job per window, not per run: a whole pass would far exceed the
                // queue's 120s stall ceiling and have its slot reclaimed mid-flight, whereas a
                // ≤30s window is a 1-3s job. Re-submitting per window also re-checks the
                // meeting gate, so starting a new recording suspends the run at a boundary.
                timed = try await ModelWorkQueue.shared.runBlocking("meeting-refine") {
                    bridge.transcribeTimestamped(samples: samples, initialPrompt: prompt, language: fixedLanguage)
                }
            } catch {
                Logger.warning("Transcript refine: window \(windowIndex + 1) cancelled", subsystem: .transcription)
                break
            }

            // Shift to absolute meeting time and drop anything that lives entirely in the lead-in.
            let shifted = timed
                .map { WhisperTimedSegment(text: $0.text, start: bufferStart + $0.start, end: bufferStart + $0.end) }
                .filter { $0.end > window.start }

            if timed.isEmpty { silent += 1 }

            let languageSource = spanLanguage != .auto ? "timeline"
                : (forcedLanguage != nil ? "forced" : "base")
            Logger.debug("Transcript refine: window \(windowIndex + 1)/\(windows.count) decoded as \(fixedLanguage.displayName) (\(languageSource))", subsystem: .transcription)

            for (index, decoded) in MeetingRefineWindow.assign(shifted, to: window, in: working) {
                let corrected = DictionaryManager.shared.correctText(decoded)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let original = working[index].text
                if let reason = Self.rejectionReason(for: corrected, replacing: original, language: fixedLanguage) {
                    // Named, because "rejected replacement (15 → 328 chars)" read like a success
                    // while the pass was discarding the only correct text it had.
                    Logger.info("Transcript refine: kept existing text for card \(index) — \(reason.rawValue) (\(original.count) → \(corrected.count) chars)", subsystem: .transcription)
                    rejected += 1
                    continue
                }
                // Record what the card was decoded in only once the decode is actually kept.
                // Stamping every pending card up front labelled rejected cards with a language
                // their text was never in, which then made the detail view's chip lie and blocked
                // re-picking that language as a no-op.
                if fixedLanguage != .auto { working[index].language = fixedLanguage.rawValue }
                guard corrected != original else { continue }
                if working[index].rawText == nil { working[index].rawText = original }
                working[index].text = corrected
                rewritten += 1
            }

            context = Self.carry(context, appending: window.segmentIndices.map { working[$0].text })
            markDone(window, in: working)
            activeSegmentIDs = []
            progress = Double(windowIndex + 1) / Double(windows.count)

            await MeetingManager.shared.updateSegments(meetingID: meetingID, segments: working)

            // Give Core Animation a scheduler tick to drain its pending GPU work between
            // decodes so the processing banner keeps animating.
            await Task.yield()
        }

        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
        Logger.info("Transcript refine: \(rewritten) segment(s) rewritten, \(rejected) kept, across \(windows.count) window(s) in \(elapsed)ms for \(meetingID)", subsystem: .transcription)
        // Every window returning nothing means the decoder never ran — a stuck abort flag, a
        // truncated audio file, a context that failed to load. None of those are "the transcript
        // was already correct", which is what the line above says on its own.
        if silent == windows.count {
            Logger.error("Transcript refine: every window decoded to silence — the decoder produced nothing for \(meetingID)", subsystem: .transcription)
        } else if silent > 0 {
            Logger.warning("Transcript refine: \(silent)/\(windows.count) window(s) decoded to silence for \(meetingID)", subsystem: .transcription)
        }
        uncorrected = rejected > 0 ? (meetingID: meetingID, count: rejected) : nil

        return finish(working, meetingID: meetingID)
    }

    /// Start a run detached from the caller — used by the manual "Re-transcribe" action and by
    /// the language chip. A forced run bypasses `shouldRun`'s "is there unpolished work" filter:
    /// the point of correcting the language is to redo cards that *are* already polished, wrongly.
    func start(meetingID: UUID, segments: [MeetingSegment], audioURL: URL?,
               forcedLanguage: TranscriptionLanguage? = nil, redoAll: Bool = false) {
        guard runTask == nil else { return }
        guard forcedLanguage != nil || redoAll
                ? canForceRun(audioURL: audioURL)
                : shouldRun(for: segments, audioURL: audioURL) else { return }
        MeetingManager.shared.setProcessing(.polishing, for: meetingID)
        runTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.run(meetingID: meetingID, segments: segments,
                               forcedLanguage: forcedLanguage, redoAll: redoAll)
            MeetingManager.shared.setProcessing(nil, for: meetingID)
            self.runTask = nil
        }
    }

    /// A forced re-run needs only the two things `run` cannot work without: the feature on and
    /// the audio still on disk.
    func canForceRun(audioURL: URL?) -> Bool {
        guard Self.isEnabled, let audioURL else { return false }
        return FileManager.default.fileExists(atPath: audioURL.path)
    }

    func cancel(meetingID: UUID) {
        guard activeMeetingID == meetingID else { return }
        cancelledMeetingID = meetingID
        runTask?.cancel()
    }

    // MARK: - Language timeline

    /// Scan the recording for its language timeline.
    ///
    /// Two detectors, deliberately: the shared tiny CPU-only bridge does the wide sweep because
    /// an encoder-only detection on it is a small fraction of one large-model window decode, and
    /// the large bridge — already loaded, already warm — re-checks only the handful of probes the
    /// tiny model was unsure about. Tiny picks *where* to look, large decides *what*.
    ///
    /// Falls back to the large bridge for everything if no tiny bridge is resident (it is loaded
    /// for live preview, which a meeting imported from a file never went through).
    private static func buildTimeline(
        audioURL: URL,
        duration: Double,
        segments: [MeetingSegment],
        confirmBridge: WhisperBridge,
        nemotronTally: [String: Int]
    ) async -> MeetingLanguageTimeline {
        let transcript = segments.map(\.text).joined(separator: " ")
        let routing = LanguageRoutingConfig.load()

        // The tiny bridge has its own ctxLock and never touches the GPU, so it needs no queue slot.
        let previewBridge = AppState.shared.modelPoolForDebug?.previewBridge
        let accurate: MeetingLanguageScanner.Detector = { samples in
            // Same queue and job name family as the window decodes, so a detection can never
            // re-enter the borrowed bridge mid-decode.
            try? await ModelWorkQueue.shared.runBlocking("meeting-refine-detect") {
                confirmBridge.detectLanguage(samples: samples)
            }
        }
        let coarse: MeetingLanguageScanner.Detector = previewBridge.map { tiny in
            { samples in tiny.detectLanguage(samples: samples) }
        } ?? accurate

        return await MeetingLanguageScanner.scan(
            audioURL: audioURL,
            duration: duration,
            coarse: coarse,
            confirm: previewBridge == nil ? nil : accurate,
            transcript: transcript,
            nemotronTally: nemotronTally,
            allowedLanguages: routing.isRoutingEnabled ? routing.allowedLanguages : []
        )
    }

    // MARK: - Helpers

    /// Every exit path goes through here. Posts `.meetingSegmentsDidRefine` so observers
    /// (MeetingDetailView) can apply the refined text in one atomic update.
    private func finish(_ segments: [MeetingSegment], meetingID: UUID) -> [MeetingSegment] {
        NotificationCenter.default.post(
            name: .meetingSegmentsDidRefine, object: meetingID, userInfo: ["segments": segments]
        )
        return segments
    }

    private func markDone(_ window: MeetingRefineWindow, in segments: [MeetingSegment]) {
        for index in window.segmentIndices { doneSegmentIDs.insert(segments[index].id) }
    }

    private static func carry(_ context: String, appending texts: [String]) -> String {
        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return context }
        return String((context + " " + joined).suffix(contextMaxLength * 2))
    }

    /// Why a re-decode was not written to its card, or nil to accept it.
    enum RefineRejection: String {
        case empty
        case repetitionLoop = "repetition-loop"
        case scriptMismatch = "script-mismatch"
        case collapsed
    }

    /// Judges the new decode on its own merits.
    ///
    /// This deliberately does **not** compare lengths against the existing text, which is what the
    /// previous `isPlausible` did. The text being replaced is usually the garbage the pass exists
    /// to remove — in the Hebrew meeting that motivated this, live output had dropped most of the
    /// speech, so the correct Hebrew came back 3–20× longer and was rejected *for being right*: 11
    /// of 23 windows thrown away, leaving the visible Hebrew/Italian mix. Text that is probably
    /// wrong gets no vote on text that is probably right.
    ///
    /// What is left are the failure modes a decode genuinely has, each detectable without a
    /// reference: nothing came back, the decoder span a loop, or it ignored the language it was
    /// given and emitted the wrong script.
    static func rejectionReason(
        for candidate: String,
        replacing original: String,
        language: TranscriptionLanguage
    ) -> RefineRejection? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let words = trimmed.split(separator: " ")
        if TranscriptRepetition.containsLoop(words: words) { return .repetitionLoop }
        // `containsLoop`'s `minimumPhraseLength = 3` misses the two-word spirals whisper actually
        // produces ("I'm okay. I'm okay. I'm okay."), so back it with a vocabulary floor.
        if words.count >= 12 {
            let distinct = Set(words.map { $0.lowercased() }).count
            if Double(distinct) / Double(words.count) < 0.35 { return .repetitionLoop }
        }

        if !writtenInExpectedScript(trimmed, language: language) { return .scriptMismatch }

        // The one length check worth keeping: a decode that lost nearly all of the speech. Only
        // meaningful when the original is itself credible text in the right script — otherwise
        // "shorter than the garbage" says nothing.
        if original.count >= 8,
           writtenInExpectedScript(original, language: language),
           Double(trimmed.count) / Double(original.count) < 0.4 {
            return .collapsed
        }
        return nil
    }

    /// True when `text` is written in a script the language actually uses, or when no such check
    /// applies — an unknown language, or a Latin-script one, where the test would fire on ordinary
    /// borrowed words and punctuation-heavy lines.
    private static func writtenInExpectedScript(_ text: String, language: TranscriptionLanguage) -> Bool {
        guard language != .auto else { return true }
        let expected = ScriptAnalyzer.scriptFamilies(for: language)
        guard !expected.isEmpty, !expected.contains(.latin) else { return true }
        let shares = ScriptAnalyzer.scriptShares(in: text)
        guard !shares.isEmpty else { return true }
        return expected.reduce(Float(0)) { $0 + (shares[$1] ?? 0) } >= 0.5
    }
}

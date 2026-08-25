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

    /// Baseline model for language scanning and for languages with no specialist.
    /// Per-language specialist selection happens via `RefineModelTable.model(for:)` at run time,
    /// after the language timeline is built — never at compile time.
    static var baselineModel: WhisperModel { RefineModelTable.baseline }

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

    /// Returns a human-readable reason string if no model at all can be obtained, or nil if the
    /// run should proceed. A missing specialist model is not a blocker — it downloads during the
    /// run. Only block when the baseline is also absent and the device appears to be offline.
    func blockingReason(for meetingID: UUID, audioURL: URL?) -> String? {
        // Resident baseline bridge → ready immediately.
        if AppState.shared.whisperBridge is WhisperBridge,
           AppState.shared.loadedModelForDebug == Self.baselineModel {
            return nil
        }
        // Baseline on disk → run can load it.
        if ModelDownloader.shared.isModelDownloaded(Self.baselineModel) { return nil }
        #if canImport(FluidAudio)
        // Let MeetingEngines drive the "not ready" reason for the prep flow.
        switch MeetingEngines.shared.readiness[.cleanup] {
        case .unavailable(let msg):
            return "Cleanup engine unavailable — \(msg)"
        default:
            break
        }
        #endif
        // Baseline missing and no warm resident — nothing we can do.
        return "\(Self.baselineModel.displayName) is not downloaded — get it in the Models tab."
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

        // ─── Phase 0: Language scan using the baseline bridge ────────────────────
        //
        // Load (or borrow) the baseline bridge first — it is the language detector and also
        // the fallback decode model. If Phase 1 picks the baseline anyway (no specialist), this
        // same bridge is reused in Phase 2 without a reload.
        let baselineModel = Self.baselineModel
        let baselineModelPath = ModelDownloader.shared.modelPath(for: baselineModel)
        let residentBridge = AppState.shared.whisperBridge as? WhisperBridge
        let canBorrow = residentBridge != nil && AppState.shared.loadedModelForDebug == baselineModel
        let detectBridge: WhisperBridge
        let ownsDetectBridge: Bool
        if let borrowed = residentBridge, canBorrow {
            detectBridge = borrowed
            ownsDetectBridge = false
            Logger.info("Transcript refine: borrowing resident \(baselineModel.displayName) bridge for \(meetingID)", subsystem: .transcription)
        } else {
            do {
                detectBridge = try await ModelWorkQueue.shared.runBlocking("meeting-refine-load") {
                    try WhisperBridge(modelPath: baselineModelPath, useGPU: true)
                }
            } catch {
                Logger.error("Transcript refine: failed to load \(baselineModel.displayName): \(error.localizedDescription)", subsystem: .transcription)
                return finish(working, meetingID: meetingID)
            }
            ownsDetectBridge = true
        }
        // Abort flag may be stale from a previous owner.
        detectBridge.resetAbort()

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
                confirmBridge: detectBridge,
                nemotronTally: liveTally?.meetingID == meetingID ? liveTally?.tally ?? [:] : [:]
            )
            if timeline.dominant != .auto {
                await MeetingManager.shared.updateLanguage(meetingID: meetingID, language: timeline.dominant.rawValue)
            }
        } else {
            timeline = .empty
        }

        // ─── Phase 1: Plan and fetch specialist models ───────────────────────────
        //
        // MeetingRefinePlan.build() applies dominance rules: if Hebrew is ≥85% of the timeline,
        // it collapses to one group on .ivritLargeTurbo, and the tail "Bye. Bye." stays Hebrew.
        let downloaded = Set(WhisperModel.allCases.filter { ModelDownloader.shared.isModelDownloaded($0) })
        var plan = MeetingRefinePlan.build(
            windows: windows,
            timeline: timeline,
            baseLanguage: forcedLanguage ?? AppState.shared.selectedLanguage,
            downloaded: downloaded,
            availableGB: available
        )

        // Download any missing specialist models before decode begins.
        // Downloads run plain (not inside ModelWorkQueue) — URLSession contends with nothing.
        // Any failure folds that group's windows into the baseline group.
        var downloadFailed: Set<WhisperModel> = []
        for model in plan.modelsToFetch {
            if Task.isCancelled || cancelledMeetingID == meetingID { break }
            Logger.info("Transcript refine: downloading \(model.displayName) for \(meetingID)", subsystem: .transcription)
            do {
                try await ModelDownloader.shared.downloadModel(model, progressCallback: { [weak self] prog in
                    guard let self else { return }
                    Task { @MainActor in
                        MeetingManager.shared.setProcessing(
                            .polishing,
                            notice: "Downloading \(model.displayName) — \(Int(prog * 100))%",
                            for: meetingID
                        )
                    }
                })
                MeetingManager.shared.setProcessing(.polishing, notice: nil, for: meetingID)
                Logger.info("Transcript refine: \(model.displayName) download complete", subsystem: .transcription)
            } catch {
                Logger.warning("Transcript refine: \(model.displayName) download failed (\(error.localizedDescription)) — folding into baseline", subsystem: .transcription)
                downloadFailed.insert(model)
            }
        }
        // Fold failed downloads back to baseline.
        if !downloadFailed.isEmpty {
            plan = MeetingRefinePlan.build(
                windows: windows,
                timeline: timeline,
                baseLanguage: forcedLanguage ?? AppState.shared.selectedLanguage,
                downloaded: downloaded.union(Set(plan.modelsToFetch).subtracting(downloadFailed)),
                availableGB: available
            )
        }

        // ─── Phase 2: Decode per group ───────────────────────────────────────────
        //
        // Baseline group reuses detectBridge; specialist groups load their own bridge,
        // decode all their windows, then shut down before the next bridge loads —
        // peak memory is one specialist at a time, not N.
        let totalWindows = windows.count
        var completedWindows = 0
        var totalRewritten = 0
        var totalSilent = 0
        let t0 = Date()

        Logger.info("Transcript refine: \(plan.groups.count) group(s), \(totalWindows) window(s), \(working.count) segment(s) for \(meetingID)", subsystem: .transcription)

        for group in plan.groups {
            if Task.isCancelled || cancelledMeetingID == meetingID { break }

            let isBaseline = group.model == baselineModel
            let groupBridge: WhisperBridge
            let ownsGroupBridge: Bool

            if isBaseline {
                groupBridge = detectBridge
                ownsGroupBridge = false
            } else {
                let specialistPath = ModelDownloader.shared.modelPath(for: group.model)
                do {
                    groupBridge = try await ModelWorkQueue.shared.runBlocking("meeting-refine-load-\(group.model.rawValue)") {
                        try WhisperBridge(modelPath: specialistPath, useGPU: true)
                    }
                } catch {
                    Logger.error("Transcript refine: failed to load \(group.model.displayName): \(error.localizedDescription) — skipping group", subsystem: .transcription)
                    completedWindows += group.windows.count
                    continue
                }
                ownsGroupBridge = true
            }
            groupBridge.resetAbort()

            Logger.info("Transcript refine: \(group.windows.count) window(s) with \(group.model.displayName) (\(group.language.displayName)) for \(meetingID)", subsystem: .transcription)

            var groupContext = ""
            var groupRewritten = 0
            var groupSilent = 0

            for window in group.windows {
                if Task.isCancelled || cancelledMeetingID == meetingID { break }

                // Per-group pending filter: cards in this group that still need polishing.
                // A `redoAll` run has already cleared `isPolished` above, so this only skips
                // windows where every card was already handled by a previous pass (e.g. a resume).
                let pending = window.segmentIndices.filter { !working[$0].isPolished }
                guard !pending.isEmpty else {
                    groupContext = Self.carry(groupContext, appending: window.segmentIndices.map { working[$0].text })
                    markDone(window, in: working)
                    completedWindows += 1
                    progress = Double(completedWindows) / Double(totalWindows)
                    continue
                }

                activeSegmentIDs = Set(window.segmentIndices.map { working[$0].id })

                let bufferStart = max(0, window.start - Self.leadInSeconds)
                let samples = SessionStorage.readFloat32Window(
                    from: audioURL,
                    startSample: Int(bufferStart * Self.sampleRate),
                    endSample: Int((window.end * Self.sampleRate).rounded(.up))
                )
                guard samples.count >= Self.minWindowSamples else {
                    Logger.debug("Transcript refine: window has no readable audio at \(window.start)s", subsystem: .transcription)
                    markDone(window, in: working)
                    activeSegmentIDs = []
                    completedWindows += 1
                    progress = Double(completedWindows) / Double(totalWindows)
                    continue
                }

                let prompt = groupContext.isEmpty ? nil : String(groupContext.suffix(Self.contextMaxLength))
                // Use the group's forced language; fall back to the timeline span; fall back to
                // the user's configured language. Per-group context keeps this in the right script.
                let spanLanguage = timeline.language(at: (window.start + window.end) / 2)
                let fixedLanguage: TranscriptionLanguage
                if group.language != .auto {
                    fixedLanguage = group.language
                } else if spanLanguage != .auto {
                    fixedLanguage = spanLanguage
                } else {
                    fixedLanguage = forcedLanguage ?? AppState.shared.selectedLanguage
                }

                let timed: [WhisperTimedSegment]
                do {
                    timed = try await ModelWorkQueue.shared.runBlocking("meeting-refine") {
                        groupBridge.transcribeTimestamped(samples: samples, initialPrompt: prompt, language: fixedLanguage)
                    }
                } catch {
                    Logger.warning("Transcript refine: window at \(window.start)s cancelled", subsystem: .transcription)
                    break
                }

                let shifted = timed
                    .map { WhisperTimedSegment(text: $0.text, start: bufferStart + $0.start, end: bufferStart + $0.end) }
                    .filter { $0.end > window.start }

                if timed.isEmpty {
                    groupSilent += 1
                } else {
                    // Check for a repetition spiral. A spiral means the decoder lost coherence,
                    // usually from poisoned context. Retry once with no prompt to break the loop.
                    var accepted = shifted
                    let allText = shifted.map(\.text).joined(separator: " ")
                    let words = allText.split(separator: " ")
                    let isSpiral = TranscriptRepetition.containsLoop(words: words)
                        || (words.count >= 12 && Double(Set(words.map { $0.lowercased() }).count) / Double(words.count) < 0.35)
                    if isSpiral {
                        Logger.info("Transcript refine: repetition spiral detected at \(window.start)s — retrying without prompt", subsystem: .transcription)
                        let retried: [WhisperTimedSegment]? = try? await ModelWorkQueue.shared.runBlocking("meeting-refine") {
                            groupBridge.transcribeTimestamped(samples: samples, initialPrompt: nil, language: fixedLanguage)
                        }
                        if let retried {
                            accepted = retried
                                .map { WhisperTimedSegment(text: $0.text, start: bufferStart + $0.start, end: bufferStart + $0.end) }
                                .filter { $0.end > window.start }
                        }
                    }

                    Logger.debug("Transcript refine: window \(completedWindows + 1)/\(totalWindows) decoded as \(fixedLanguage.displayName) (\(group.model.displayName))", subsystem: .transcription)

                    // The refine output always wins. With the correct per-language model there is
                    // no longer a reason to distrust the output's script or length.
                    for (index, decoded) in MeetingRefineWindow.assign(accepted, to: window, in: working) {
                        var corrected = DictionaryManager.shared.correctText(decoded)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        // Strip leading punctuation artifacts: model sometimes starts a window with
                        // ", " or ". " when the audio boundary falls mid-utterance after a pause.
                        while let first = corrected.unicodeScalars.first,
                              CharacterSet(charactersIn: ",. ").contains(first) {
                            corrected = String(corrected.unicodeScalars.dropFirst())
                                .trimmingCharacters(in: .init(charactersIn: " "))
                        }
                        // Strip Arabic script from Hebrew-forced decodes. The ivrit model occasionally
                        // outputs Arabic Unicode for Arabic loanwords the speaker used; since the
                        // whole group is forced to Hebrew, this is always an artifact.
                        if fixedLanguage == .hebrew {
                            corrected = String(corrected.unicodeScalars.filter {
                                !($0.value >= 0x0600 && $0.value <= 0x06FF)
                            }).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        guard !corrected.isEmpty else { continue }
                        if fixedLanguage != .auto { working[index].language = fixedLanguage.rawValue }
                        let original = working[index].text
                        guard corrected != original else { continue }
                        if working[index].rawText == nil { working[index].rawText = original }
                        working[index].text = corrected
                        groupRewritten += 1
                    }
                }

                groupContext = Self.carry(groupContext, appending: window.segmentIndices.map { working[$0].text })
                markDone(window, in: working)
                activeSegmentIDs = []
                completedWindows += 1
                progress = Double(completedWindows) / Double(totalWindows)

                await MeetingManager.shared.updateSegments(meetingID: meetingID, segments: working)
                await Task.yield()
            }

            totalRewritten += groupRewritten
            totalSilent += groupSilent

            if groupSilent == group.windows.count, !group.windows.isEmpty {
                Logger.error("Transcript refine: every window in \(group.model.displayName) group decoded to silence for \(meetingID)", subsystem: .transcription)
            } else if groupSilent > 0 {
                Logger.warning("Transcript refine: \(groupSilent)/\(group.windows.count) window(s) silent in \(group.model.displayName) group", subsystem: .transcription)
            }

            if ownsGroupBridge { groupBridge.prepareForShutdown() }
        }

        if ownsDetectBridge { detectBridge.prepareForShutdown() }

        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
        Logger.info("Transcript refine: \(totalRewritten) segment(s) rewritten across \(totalWindows) window(s) in \(elapsed)ms for \(meetingID)", subsystem: .transcription)

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
    /// Scan the recording with Whisperer V3 alone. V3 is the resident bridge during the refine
    /// pass; one encoder pass costs ~721 ms but is 0.98–0.99 confident from 30 s windows. Using
    /// `Plan.accurate` keeps probes to 20 and skips the two-tier coarse/confirm approach.
    private static func buildTimeline(
        audioURL: URL,
        duration: Double,
        segments: [MeetingSegment],
        confirmBridge: WhisperBridge,
        nemotronTally: [String: Int]
    ) async -> MeetingLanguageTimeline {
        let transcript = segments.map(\.text).joined(separator: " ")
        let routing = LanguageRoutingConfig.load()

        let detector: MeetingLanguageScanner.Detector = { samples in
            // Same queue and job name family as the window decodes, so a detection can never
            // re-enter the borrowed bridge mid-decode.
            try? await ModelWorkQueue.shared.runBlocking("meeting-refine-detect") {
                confirmBridge.detectLanguage(samples: samples)
            }
        }

        return await MeetingLanguageScanner.scan(
            audioURL: audioURL,
            duration: duration,
            coarse: detector,
            confirm: nil,
            transcript: transcript,
            nemotronTally: nemotronTally,
            allowedLanguages: routing.isRoutingEnabled ? routing.allowedLanguages : [],
            plan: .accurate
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

    // RefineRejection and rejectionReason were removed. The refine output always wins:
    // with the correct per-language model selected by MeetingRefinePlan, the re-decode is
    // by construction more accurate than the live single-pass text it replaces. The only
    // surviving failure check is a repetition spiral (in the window loop above), which
    // triggers a no-prompt retry rather than keeping the garbage live text.
}

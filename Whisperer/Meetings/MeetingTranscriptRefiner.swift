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
    @discardableResult
    func run(meetingID: UUID, segments: [MeetingSegment]) async -> [MeetingSegment] {
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

        let model = Self.cleanupModel
        if let reason = blockingReason(for: meetingID, audioURL: record?.resolvedAudioURL) {
            Logger.warning("Transcript refine: \(reason) — skipped", subsystem: .transcription)
            return finish(source, meetingID: meetingID)
        }

        var working = source
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

        Logger.info("Transcript refine: \(windows.count) window(s) over \(working.count) segment(s) with \(model.displayName) for \(meetingID)", subsystem: .transcription)

        // A meeting cannot change language halfway through, but per-window auto-detect can.
        // Detect once on the first decoded window, then pin.
        var language = AppState.shared.selectedLanguage
        var context = ""
        var rewritten = 0
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
            let fixedLanguage = language
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

            if language == .auto, let detected = bridge.lastDetectedLanguage,
               let resolved = TranscriptionLanguage(rawValue: detected) {
                language = resolved
                Logger.debug("Transcript refine: language pinned to \(resolved.displayName)", subsystem: .transcription)
            }

            // Shift to absolute meeting time and drop anything that lives entirely in the lead-in.
            let shifted = timed
                .map { WhisperTimedSegment(text: $0.text, start: bufferStart + $0.start, end: bufferStart + $0.end) }
                .filter { $0.end > window.start }

            for (index, decoded) in MeetingRefineWindow.assign(shifted, to: window, in: working) {
                let corrected = DictionaryManager.shared.correctText(decoded)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let original = working[index].text
                guard Self.isPlausible(corrected, replacing: original) else {
                    Logger.debug("Transcript refine: rejected replacement (\(original.count) → \(corrected.count) chars)", subsystem: .transcription)
                    continue
                }
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
        Logger.info("Transcript refine: \(rewritten) segment(s) rewritten across \(windows.count) window(s) in \(elapsed)ms for \(meetingID)", subsystem: .transcription)

        return finish(working, meetingID: meetingID)
    }

    /// Start a run detached from the caller — used by the manual "Re-transcribe" action.
    func start(meetingID: UUID, segments: [MeetingSegment], audioURL: URL?) {
        guard runTask == nil, shouldRun(for: segments, audioURL: audioURL) else { return }
        MeetingManager.shared.setProcessing(.polishing, for: meetingID)
        runTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.run(meetingID: meetingID, segments: segments)
            MeetingManager.shared.setProcessing(nil, for: meetingID)
            self.runTask = nil
        }
    }

    func cancel(meetingID: UUID) {
        guard activeMeetingID == meetingID else { return }
        cancelledMeetingID = meetingID
        runTask?.cancel()
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

    /// A light sanity guard, deliberately not `TranscriptPostValidator(.strict)`: that profile
    /// exists to catch an LLM drifting off a line it was told to preserve, and a genuine second
    /// decode legitimately differs far more than it allows. This only rejects the two failure
    /// modes a decode actually has — an empty result, and a hallucination spiral or a dropped
    /// utterance that changes the length beyond recognition.
    private static func isPlausible(_ candidate: String, replacing original: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard original.count >= 8 else { return true }
        let ratio = Double(candidate.count) / Double(original.count)
        return ratio >= 0.4 && ratio <= 2.5
    }
}

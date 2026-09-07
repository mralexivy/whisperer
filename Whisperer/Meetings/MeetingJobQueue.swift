//
//  MeetingJobQueue.swift
//  Whisperer
//
//  Process-wide owner of the meeting post-processing pipeline.
//
//  The pipeline previously lived in an unstored `Task { [weak self] }` in `MeetingSession`,
//  anchored to a view-owned @StateObject. Three things went wrong together: the strong ref
//  from `AppState.activeMeetingSession` was nilled before the Task finished, `startRecording()`
//  reset `meetingID`/`segments` mid-flight, and a crash killed the whole structure. This class
//  holds the pipeline Task for the process lifetime.
//
//  Architecture:
//  - One job runs at a time, serial FIFO.
//  - Recording preempts: the running job is cancelled and requeued at the head with status
//    `.pausedForRecording`. It resumes after the recording stops.
//  - Each stage transition writes a JSON sidecar before entering the stage, so a crash
//    inside stage N restarts at N, not N+1.
//  - `restore()` runs at launch, after `recoverCrashedSessions()`, and re-enqueues any jobs
//    whose sidecars survived.
//
//  Relationship to `ModelWorkQueue`: this queue schedules *meetings* (minutes long). Each
//  stage submits its inner work units through `ModelWorkQueue` as before. Two layers.
//

import Combine
import Foundation

@MainActor
final class MeetingJobQueue: ObservableObject {

    static let shared = MeetingJobQueue()
    private init() {}

    /// Maximum number of attempts before a job becomes `.failed`.
    private static let maxAttempts = 3

    // MARK: - Published state

    @Published private(set) var jobs: [MeetingJob] = []

    // MARK: - Private state

    private var runningTask: Task<Void, Never>?
    private var isSuspended = false

    // MARK: - Enqueue

    /// Called from `MeetingSession.stopRecording()` after tail delivery.
    ///
    /// Persists a `.fineTuning` job immediately, then starts it if the queue is idle and
    /// not suspended for recording.
    func enqueue(
        meetingID: UUID,
        segments: [MeetingSegment],
        audioURL: URL?,
        currentTitle: String
    ) {
        guard jobs.first(where: { $0.id == meetingID && $0.status != .done && $0.status != .failed }) == nil else {
            Logger.debug("MeetingJobQueue: \(meetingID) already queued — skipping duplicate enqueue", subsystem: .transcription)
            return
        }
        var job = MeetingJob(
            id: meetingID,
            stage: .fineTuning,
            status: .queued,
            enqueuedAt: Date(),
            startedAt: nil,
            attempts: 0,
            lastError: nil
        )
        MeetingJobStore.save(job)
        jobs.append(job)
        Logger.info("MeetingJobQueue: enqueued \(meetingID) (queued=\(jobs.count))", subsystem: .transcription)

        if !isSuspended && runningTask == nil {
            startNext(capturedSegments: segments, capturedAudioURL: audioURL, capturedTitle: currentTitle)
        }
    }

    /// Remove a job (meeting deleted or done).
    func remove(meetingID: UUID) {
        if let running = runningTask, jobs.first(where: { $0.id == meetingID })?.status == .running {
            running.cancel()
            runningTask = nil
        }
        jobs.removeAll { $0.id == meetingID }
        MeetingJobStore.remove(meetingID: meetingID)
    }

    /// Manually retry a `.failed` job.
    func retry(meetingID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == meetingID && $0.status == .failed }) else { return }
        jobs[idx].status = .queued
        jobs[idx].attempts = 0
        jobs[idx].lastError = nil
        MeetingJobStore.save(jobs[idx])
        if !isSuspended && runningTask == nil { startNext() }
    }

    // MARK: - Preemption

    /// Called when a new meeting recording starts.
    ///
    /// Must be called BEFORE `ModelWorkQueue.setMeetingActive(true)` so the job stops
    /// enqueueing inner work units before the gate rises.
    func suspendForRecording() {
        guard !isSuspended else { return }
        isSuspended = true
        Logger.info("MeetingJobQueue: suspended for recording", subsystem: .transcription)

        guard let idx = jobs.firstIndex(where: { $0.status == .running }) else { return }
        jobs[idx].status = .pausedForRecording
        jobs[idx].attempts += 1
        MeetingJobStore.save(jobs[idx])

        runningTask?.cancel()
        runningTask = nil

        MeetingTranscriptRefiner.shared.cancel(meetingID: jobs[idx].id)

        // Move paused job to head so it resumes before any newer job.
        let paused = jobs.remove(at: idx)
        jobs.insert(paused, at: 0)
    }

    /// Called after a meeting recording stops.
    func resumeAfterRecording() {
        guard isSuspended else { return }
        isSuspended = false
        Logger.info("MeetingJobQueue: resumed after recording", subsystem: .transcription)
        if runningTask == nil { startNext() }
    }

    // MARK: - Launch restore

    /// Run at launch after `MeetingManager.recoverCrashedSessions()`.
    ///
    /// Transitions in-flight and crashed states, drops orphans (no CoreData row), then re-enqueues.
    func restore() async {
        let onDisk = MeetingJobStore.allJobs()
        guard !onDisk.isEmpty else { return }

        var restored = 0
        for var job in onDisk {
            // Drop orphans: no MeetingEntity row in CoreData.
            let exists = await MeetingManager.shared.meeting(id: job.id) != nil
            guard exists else {
                Logger.info("MeetingJobQueue: dropping orphaned job for \(job.id) — no CoreData row", subsystem: .transcription)
                MeetingJobStore.remove(meetingID: job.id)
                continue
            }
            // Only one process runs at a time. `.running` on disk means a crash.
            if job.status == .running {
                job.status = .queued
                job.attempts += 1
            }
            if job.status == .pausedForRecording {
                job.status = .queued
            }
            // `.finalizing` is not cross-launch resumable (awaitTailDelivery checks live state).
            if job.stage == .finalizing {
                job.stage = .fineTuning
            }
            if job.attempts >= Self.maxAttempts {
                job.status = .failed
                job.lastError = "Post-processing didn't complete after \(job.attempts) attempts."
                MeetingJobStore.save(job)
                jobs.append(job)
                Logger.warning("MeetingJobQueue: \(job.id) exceeded attempt ceiling — marked failed", subsystem: .transcription)
                continue
            }
            job.status = .queued
            MeetingJobStore.save(job)
            jobs.append(job)
            restored += 1
        }
        if restored > 0 {
            Logger.info("MeetingJobQueue: restore() re-enqueued \(restored) job(s)", subsystem: .transcription)
            if !isSuspended && runningTask == nil { startNext() }
        }
    }

    // MARK: - Private pipeline

    private func startNext(
        capturedSegments: [MeetingSegment]? = nil,
        capturedAudioURL: URL? = nil,
        capturedTitle: String? = nil
    ) {
        guard !isSuspended, runningTask == nil else { return }
        guard let idx = jobs.firstIndex(where: { $0.status == .queued || $0.status == .pausedForRecording }) else { return }

        jobs[idx].status = .running
        jobs[idx].startedAt = Date()
        jobs[idx].attempts += 1
        MeetingJobStore.save(jobs[idx])

        let job = jobs[idx]
        Logger.info("MeetingJobQueue: starting \(job.id) stage=\(job.stage.rawValue) attempt=\(job.attempts)", subsystem: .transcription)

        runningTask = Task {
            await runPipeline(
                jobID: job.id,
                startingAt: job.stage,
                capturedSegments: capturedSegments,
                capturedAudioURL: capturedAudioURL,
                capturedTitle: capturedTitle
            )
        }
    }

    private func runPipeline(
        jobID meetingID: UUID,
        startingAt stage: MeetingJobStage,
        capturedSegments: [MeetingSegment]?,
        capturedAudioURL: URL?,
        capturedTitle: String?
    ) async {
        var segments = capturedSegments ?? []

        // MARK: fineTuning
        if [MeetingJobStage.fineTuning, .finalizing].contains(stage) {
            transition(meetingID: meetingID, to: .fineTuning, status: .running)
            MeetingManager.shared.setProcessing(.fineTuning, for: meetingID)

            // When `enqueue` fires while the queue is suspended for a recording, `startNext`
            // is called later (by `resumeAfterRecording`) with no captured state. Recover from
            // CoreData so `shouldRun` and `run` have what they need — mirroring what the naming
            // stage already does below.
            var audioURL = capturedAudioURL
            if segments.isEmpty || audioURL == nil,
               let record = await MeetingManager.shared.meeting(id: meetingID) {
                if segments.isEmpty { segments = record.segments }
                if audioURL == nil  { audioURL = record.resolvedAudioURL }
            }

            let willPolish = MeetingTranscriptRefiner.shared.shouldRun(for: segments, audioURL: audioURL)

            if willPolish {
                if let reason = MeetingTranscriptRefiner.shared.blockingReason(for: meetingID, audioURL: audioURL) {
                    Logger.warning("MeetingJobQueue: cleanup skipped — \(reason)", subsystem: .transcription)
                    MeetingManager.shared.setProcessing(.fineTuning, notice: "Cleanup skipped — model not downloaded", for: meetingID)
                } else {
                    if Task.isCancelled { return await finishCancelled(meetingID: meetingID) }
                    // `redoAll: true` re-runs language detection over the whole recording and
                    // resets every card, so a wrong live pin (e.g. "ru" on a Hebrew meeting)
                    // is caught and corrected without a manual re-transcribe.
                    let refined = await MeetingTranscriptRefiner.shared.run(
                        meetingID: meetingID, segments: segments, redoAll: true)
                    if Task.isCancelled { return await finishCancelled(meetingID: meetingID) }
                    segments = await runEditorPass(segments: refined, meetingID: meetingID)
                }
            } else {
                let skipReason = audioURL == nil ? "audio file not found on disk"
                    : "all segments already polished"
                Logger.info("MeetingJobQueue: fine-tuning skipped — \(skipReason)", subsystem: .transcription)
            }
        }

        if Task.isCancelled { return await finishCancelled(meetingID: meetingID) }

        // MARK: naming
        if [MeetingJobStage.fineTuning, .naming, .finalizing].contains(stage) {
            transition(meetingID: meetingID, to: .naming, status: .running)
            MeetingManager.shared.setProcessing(.naming, for: meetingID)

            if segments.isEmpty, let existing = await MeetingManager.shared.meeting(id: meetingID) {
                segments = existing.segments
            }

            let titleForGeneration: String
            if let t = capturedTitle {
                titleForGeneration = t
            } else if let record = await MeetingManager.shared.meeting(id: meetingID) {
                titleForGeneration = record.title ?? ""
            } else {
                titleForGeneration = ""
            }
            await MeetingAIService.shared.generateTitle(
                segments: segments,
                meetingID: meetingID,
                currentTitle: titleForGeneration
            )
        }

        if Task.isCancelled { return await finishCancelled(meetingID: meetingID) }

        // MARK: summarizing
        transition(meetingID: meetingID, to: .summarizing, status: .running)
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
        MeetingManager.shared.setProcessing(.summarizing, notice: intelligenceNotice, for: meetingID)
        await MeetingAIService.shared.generateOverview(segments: segments, meetingID: meetingID)

        if Task.isCancelled { return await finishCancelled(meetingID: meetingID) }

        // Done
        MeetingManager.shared.setProcessing(nil, for: meetingID)
        transition(meetingID: meetingID, to: .done, status: .done)
        MeetingJobStore.remove(meetingID: meetingID)
        Logger.info("MeetingJobQueue: \(meetingID) complete", subsystem: .transcription)

        runningTask = nil
        startNext()
    }

    /// Runs the mmBERT + deterministic polish pass off the main actor.
    ///
    /// This is `@MainActor` (inherits class isolation) intentionally: it reads main-actor
    /// properties (`DictionaryManager.entries`, `AppState.selectedLanguage`) before delegating
    /// the heavy compute to `MeetingSession.polishAll` which is `@concurrent`. Same structure
    /// as `MeetingSession.applyEditor`.
    private func runEditorPass(
        segments: [MeetingSegment],
        meetingID: UUID
    ) async -> [MeetingSegment] {
        guard PolishFeatureFlags.isFastPolishEnabled else { return segments }
        let entries = DictionaryManager.shared.entries
        let editor = DeterministicPolisher.forTranscript(dictionaryEntries: entries, formatsLists: true)
        let selected = AppState.shared.selectedLanguage
        let context = EditContext(
            language: selected == .auto ? nil : selected,
            pass: .authoritative
        )
        let outcome = await MeetingSession.polishAll(segments, with: editor, context: context)
        let refined = outcome.segments
        let count = outcome.rewritten
        guard count > 0 else { return segments }

        await MeetingManager.shared.updateSegments(meetingID: meetingID, segments: refined)
        NotificationCenter.default.post(
            name: .meetingSegmentsDidRefine,
            object: meetingID,
            userInfo: ["segments": refined]
        )
        Logger.info("MeetingJobQueue editor: \(count)/\(refined.count) segment(s) polished", subsystem: .transcription)
        return refined
    }

    private func finishCancelled(meetingID: UUID) async {
        Logger.info("MeetingJobQueue: \(meetingID) pipeline cancelled (preempted or removed)", subsystem: .transcription)
        runningTask = nil
        // Job was already moved to .pausedForRecording by suspendForRecording(), or removed.
    }

    private func transition(meetingID: UUID, to stage: MeetingJobStage, status: MeetingJobStatus) {
        guard let idx = jobs.firstIndex(where: { $0.id == meetingID }) else { return }
        jobs[idx].stage = stage
        jobs[idx].status = status
        MeetingJobStore.save(jobs[idx])
    }
}

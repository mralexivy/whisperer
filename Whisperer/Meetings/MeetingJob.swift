//
//  MeetingJob.swift
//  Whisperer
//
//  Codable record for one meeting's post-processing pipeline.
//  Persisted as a JSON sidecar at
//  ~/Library/Application Support/Whisperer/Meetings/Jobs/<uuid>-job.json.
//
//  Stage granularity is deliberately coarse: each stage already checkpoints below itself
//  and is idempotent. The exception is `.finalizing` — `awaitTailDelivery` polls
//  `AppState.activeMeetingSession`, which is meaningless in a new process. A restored
//  `.finalizing` job restarts at `.fineTuning`, which is covered by `MeetingPendingStore`
//  + `recoverCrashedSessions`.
//

import Foundation

nonisolated enum MeetingJobStage: String, Codable, Sendable, CaseIterable {
    /// Waiting for in-process tail delivery. Not cross-launch resumable — restore at `.fineTuning`.
    case finalizing
    /// Re-decoding audio and deterministic polish pass.
    case fineTuning
    /// LLM title generation.
    case naming
    /// LLM overview generation.
    case summarizing
    case done
}

nonisolated enum MeetingJobStatus: String, Codable, Sendable {
    case queued
    case running
    /// Paused because a new recording started. Job is at the queue head.
    case pausedForRecording
    /// Exceeded the 3-attempt ceiling. Terminal until the user retries.
    case failed
    case done
}

nonisolated struct MeetingJob: Codable, Sendable, Identifiable {
    /// Same UUID as the `MeetingEntity` row this job processes.
    let id: UUID
    var stage: MeetingJobStage
    var status: MeetingJobStatus
    var enqueuedAt: Date
    var startedAt: Date?
    /// Incremented on each start; ceiling is 3. A job that exceeds it moves to `.failed`.
    var attempts: Int
    var lastError: String?
}

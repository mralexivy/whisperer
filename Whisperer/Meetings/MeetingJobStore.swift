//
//  MeetingJobStore.swift
//  Whisperer
//
//  JSON sidecar persistence for `MeetingJob`. Same atomic-write pattern as
//  `MeetingPendingStore` — ~100 µs writes at transition boundaries rather than
//  a CoreData fetch that can't synchronously checkpoint mid-pipeline.
//
//  Path: ~/Library/Application Support/Whisperer/Meetings/Jobs/<uuid>-job.json
//

import Foundation

nonisolated enum MeetingJobStore {

    private static func jobsDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Whisperer/Meetings/Jobs")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func jobURL(for meetingID: UUID) -> URL {
        jobsDirectory().appendingPathComponent("\(meetingID.uuidString)-job.json")
    }

    /// Atomically persist a job. Called at every status and stage transition.
    static func save(_ job: MeetingJob) {
        guard let data = try? JSONEncoder().encode(job) else { return }
        try? data.write(to: jobURL(for: job.id), options: .atomic)
    }

    /// Remove the sidecar. Called when a job reaches `.done` or the meeting is deleted.
    static func remove(meetingID: UUID) {
        try? FileManager.default.removeItem(at: jobURL(for: meetingID))
    }

    /// Load a specific job. Returns nil if absent or decode fails.
    static func load(meetingID: UUID) -> MeetingJob? {
        let url = jobURL(for: meetingID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingJob.self, from: data)
    }

    /// All jobs on disk, sorted by `enqueuedAt` ascending. Used by `MeetingJobQueue.restore()`.
    static func allJobs() -> [MeetingJob] {
        let fm = FileManager.default
        let dir = jobsDirectory()
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items.compactMap { url -> MeetingJob? in
            guard url.lastPathComponent.hasSuffix("-job.json") else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MeetingJob.self, from: data)
        }
        .sorted { $0.enqueuedAt < $1.enqueuedAt }
    }
}

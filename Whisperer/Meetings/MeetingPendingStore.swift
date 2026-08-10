//
//  MeetingPendingStore.swift
//  Whisperer
//
//  Crash-safe sidecar store for the in-progress (not yet flushed) segment of a
//  meeting recording. Written synchronously on the main thread after every whisper
//  chunk so the text survives a crash. Cleared after each durable CoreData flush.
//

import Foundation

struct MeetingPendingSegment: Codable {
    var text: String
    var startTimestamp: Double
}

enum MeetingPendingStore {

    private static func pendingURL(for meetingID: UUID) -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Whisperer/Meetings")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(meetingID.uuidString)-pending.json")
    }

    /// Persist the current accumulated segment text. Pass empty text to clear.
    static func save(meetingID: UUID, text: String, startTimestamp: Double) {
        if text.isEmpty {
            clear(meetingID: meetingID)
            return
        }
        let pending = MeetingPendingSegment(text: text, startTimestamp: startTimestamp)
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: pendingURL(for: meetingID), options: .atomic)
    }

    /// Remove the pending file (segment has been committed to CoreData).
    static func clear(meetingID: UUID) {
        try? FileManager.default.removeItem(at: pendingURL(for: meetingID))
    }

    /// Load a pending segment for recovery. Returns nil if no file or decode fails.
    static func load(meetingID: UUID) -> MeetingPendingSegment? {
        let url = pendingURL(for: meetingID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingPendingSegment.self, from: data)
    }

    /// Returns all meeting UUIDs that have a pending file on disk.
    static func allPendingMeetingIDs() -> [UUID] {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Whisperer/Meetings")
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url -> UUID? in
            let name = url.lastPathComponent
            guard name.hasSuffix("-pending.json") else { return nil }
            let uuidStr = String(name.dropLast("-pending.json".count))
            return UUID(uuidString: uuidStr)
        }
    }
}

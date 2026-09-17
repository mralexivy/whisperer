//
//  MeetingListItem.swift
//  Whisperer
//
//  Lightweight list-only struct — scalar CoreData fields only, no JSON decode.
//  Used for the paginated meeting library list; full MeetingRecord is loaded on demand.
//

import Foundation

struct MeetingListItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var duration: Double
    var wordCount: Int
    var audioFileURL: String?
    let language: String
    var isInProgress: Bool
    /// The recording never received a non-silent sample — see `MeetingRecord.captureFailed`.
    var captureFailed: Bool = false
    /// True when the user explicitly set the title; LLM auto-naming must not overwrite it.
    var titleIsUserSet: Bool = false
    var sourceBundleID: String?
    var sourceAppName: String?

    // MARK: - Computed (mirrors MeetingRecord)

    var displayDuration: String {
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var formattedDate: String {
        MeetingListItem.dateFormatter.string(from: createdAt)
    }

    var formattedTime: String {
        MeetingListItem.timeFormatter.string(from: createdAt)
    }

    // MARK: - Static formatters (one allocation per process)

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt
    }()

    var resolvedAudioURL: URL? {
        guard let rel = audioFileURL else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Whisperer/Meetings/\(rel)")
    }

    // MARK: - Init from CoreData (no JSON decode — O(1) regardless of segment count)

    init(from entity: MeetingEntity) {
        self.id = entity.id
        self.title = entity.title
        self.createdAt = entity.createdAt
        self.duration = entity.duration
        self.audioFileURL = entity.audioFileURL
        self.wordCount = Int(entity.wordCount)
        self.language = entity.language
        self.isInProgress = entity.isInProgress
        self.captureFailed = entity.captureFailed
        self.titleIsUserSet = entity.titleIsUserSet
        self.sourceBundleID = entity.sourceBundleID
        self.sourceAppName = entity.sourceAppName
    }

    // MARK: - Init for new session (before CoreData write)

    init(id: UUID, title: String, language: String,
         sourceBundleID: String? = nil, sourceAppName: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.duration = 0
        self.wordCount = 0
        self.audioFileURL = nil
        self.language = language
        self.isInProgress = true
        self.captureFailed = false
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }
}

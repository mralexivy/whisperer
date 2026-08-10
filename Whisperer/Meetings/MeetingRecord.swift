//
//  MeetingRecord.swift
//  Whisperer
//
//  SwiftUI-friendly value type wrapping MeetingEntity.
//

import Foundation

struct MeetingRecord: Identifiable, Equatable {
    static func == (lhs: MeetingRecord, rhs: MeetingRecord) -> Bool {
        lhs.id == rhs.id &&
        lhs.audioFileURL == rhs.audioFileURL &&
        lhs.isInProgress == rhs.isInProgress
    }

    let id: UUID
    var title: String
    let createdAt: Date
    var duration: Double
    var audioFileURL: String?
    var segments: [MeetingSegment]
    var notes: [MeetingNote]
    var aiSummary: MeetingAISummary?
    var wordCount: Int
    var language: String
    var modelUsed: String
    var isInProgress: Bool

    // MARK: - Computed

    var fullTranscript: String {
        segments.map { $0.text }.joined(separator: " ")
    }

    var speakerNames: [String] {
        Array(Set(segments.map { $0.speakerName })).sorted()
    }

    var uniqueSpeakers: [(index: Int, name: String)] {
        var seen: Set<Int> = []
        var result: [(Int, String)] = []
        for seg in segments where !seen.contains(seg.speakerIndex) {
            seen.insert(seg.speakerIndex)
            result.append((seg.speakerIndex, seg.speakerName))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    var resolvedAudioURL: URL? {
        guard let rel = audioFileURL else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Whisperer/Meetings/\(rel)")
    }

    var displayDuration: String {
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: createdAt)
    }

    // MARK: - Init from CoreData

    init(from entity: MeetingEntity) {
        self.id = entity.id
        self.title = entity.title
        self.createdAt = entity.createdAt
        self.duration = entity.duration
        self.audioFileURL = entity.audioFileURL
        self.wordCount = Int(entity.wordCount)
        self.language = entity.language
        self.modelUsed = entity.modelUsed
        self.isInProgress = entity.isInProgress

        let decoder = JSONDecoder()

        if let json = entity.segmentsJSON, let data = json.data(using: .utf8),
           let segs = try? decoder.decode([MeetingSegment].self, from: data) {
            self.segments = segs
        } else {
            self.segments = []
        }

        if let json = entity.notesJSON, let data = json.data(using: .utf8),
           let ns = try? decoder.decode([MeetingNote].self, from: data) {
            self.notes = ns
        } else {
            self.notes = []
        }

        if let json = entity.aiSummaryJSON, let data = json.data(using: .utf8),
           let summary = try? decoder.decode(MeetingAISummary.self, from: data) {
            self.aiSummary = summary
        } else {
            self.aiSummary = nil
        }
    }

    // MARK: - New meeting init

    init(id: UUID = UUID(), title: String, language: String, modelUsed: String) {
        let now = Date()
        self.id = id
        self.title = title
        self.createdAt = now
        self.duration = 0
        self.audioFileURL = nil
        self.segments = []
        self.notes = []
        self.aiSummary = nil
        self.wordCount = 0
        self.language = language
        self.modelUsed = modelUsed
        self.isInProgress = true
    }
}

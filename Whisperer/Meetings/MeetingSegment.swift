//
//  MeetingSegment.swift
//  Whisperer
//
//  Codable value types stored as JSON columns in MeetingEntity.
//

import Foundation

// MARK: - Segment

struct MeetingSegment: Codable, Identifiable, Equatable {
    var id: UUID
    var timestamp: Double          // seconds from meeting start
    var endTimestamp: Double       // estimated end (start + chunk duration)
    var text: String
    var speakerName: String        // default "Speaker 1", user-editable inline
    var speakerIndex: Int          // 0-7, drives color from palette
    var tags: [SegmentTag]

    init(id: UUID = UUID(), timestamp: Double, endTimestamp: Double, text: String,
         speakerName: String = "Speaker 1", speakerIndex: Int = 0, tags: [SegmentTag] = []) {
        self.id = id
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.text = text
        self.speakerName = speakerName
        self.speakerIndex = speakerIndex
        self.tags = tags
    }
}

enum SegmentTag: String, Codable, CaseIterable {
    case keyPoint = "KEY POINT"
    case decision = "DECISION"
    case risk     = "RISK"
    case action   = "ACTION"

    var color: String {
        switch self {
        case .keyPoint: return "5B6CF7"
        case .decision: return "10B981"
        case .risk:     return "F59E0B"
        case .action:   return "8B5CF6"
        }
    }
}

// MARK: - Note

struct MeetingNote: Codable, Identifiable {
    var id: UUID
    var kind: NoteKind
    var timestamp: Double
    var text: String

    init(id: UUID = UUID(), kind: NoteKind, timestamp: Double, text: String = "") {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
    }
}

enum NoteKind: String, Codable, CaseIterable {
    case decision = "DECISION"
    case risk     = "RISK"
    case idea     = "IDEA"

    var colorHex: String {
        switch self {
        case .decision: return "10B981"
        case .risk:     return "F59E0B"
        case .idea:     return "5B6CF7"
        }
    }
}

// MARK: - Action item

struct MeetingActionItem: Codable, Identifiable {
    var id: UUID
    var text: String
    var ownerName: String
    var dueLabel: String?
    var isDone: Bool

    init(id: UUID = UUID(), text: String, ownerName: String = "", dueLabel: String? = nil, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.ownerName = ownerName
        self.dueLabel = dueLabel
        self.isDone = isDone
    }
}

// MARK: - AI summary sub-types

struct TopicItem: Codable, Identifiable {
    var id: UUID
    var text: String
    var timestampSeconds: Double

    init(id: UUID = UUID(), text: String, timestampSeconds: Double = 0) {
        self.id = id
        self.text = text
        self.timestampSeconds = timestampSeconds
    }
}

struct DecisionItem: Codable, Identifiable {
    var id: UUID
    var label: String
    var text: String
    var timestampSeconds: Double

    init(id: UUID = UUID(), label: String, text: String, timestampSeconds: Double = 0) {
        self.id = id
        self.label = label
        self.text = text
        self.timestampSeconds = timestampSeconds
    }
}

struct QuestionItem: Codable, Identifiable {
    var id: UUID
    var text: String
    var timestampSeconds: Double

    init(id: UUID = UUID(), text: String, timestampSeconds: Double = 0) {
        self.id = id
        self.text = text
        self.timestampSeconds = timestampSeconds
    }
}

// MARK: - AI summary

struct MeetingAISummary: Codable {
    var overview: String
    var keyTopics: [TopicItem]
    var decisions: [DecisionItem]
    var openQuestions: [QuestionItem]
    var nextMeeting: String?
    var actionItems: [MeetingActionItem]
    var generatedAt: Date?              // nil for summaries generated before this field existed

    // CodingKeys declared here so the custom init(from:) in the extension can reference them
    // while the memberwise init (used by `empty` and callers) is auto-synthesized.
    enum CodingKeys: String, CodingKey {
        case overview, keyTopics, decisions, openQuestions, nextMeeting, actionItems, generatedAt
    }

    static var empty: MeetingAISummary {
        MeetingAISummary(overview: "", keyTopics: [], decisions: [], openQuestions: [], nextMeeting: nil, actionItems: [], generatedAt: nil)
    }
}

extension MeetingAISummary {
    // Lenient decoder: missing or malformed fields fall back to empty defaults instead of
    // throwing. This lets the JSON repair path return a partial-but-usable summary when
    // the LLM output is truncated by a generation timeout.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overview      = (try? c.decode(String.self,                forKey: .overview))      ?? ""
        keyTopics     = (try? c.decode([TopicItem].self,           forKey: .keyTopics))     ?? []
        decisions     = (try? c.decode([DecisionItem].self,        forKey: .decisions))     ?? []
        openQuestions = (try? c.decode([QuestionItem].self,        forKey: .openQuestions)) ?? []
        nextMeeting   = try? c.decode(String.self,                 forKey: .nextMeeting)
        actionItems   = (try? c.decode([MeetingActionItem].self,   forKey: .actionItems))   ?? []
        generatedAt   = try? c.decode(Date.self,                   forKey: .generatedAt)
    }
}

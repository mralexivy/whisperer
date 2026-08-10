//
//  MCPMeetingTools.swift
//  Whisperer
//
//  MCP tools for meeting notes: list_meetings, get_meeting.
//  Reads CoreData directly on a background context — no main actor dependency.
//

import Foundation
import CoreData
import MCP

enum MCPMeetingTools {

    // MARK: - Tool Definitions

    static var toolDefinitions: [Tool] {
        [listMeetingsTool, getMeetingTool]
    }

    private static let listMeetingsTool = Tool(
        name: "list_meetings",
        description: "List recorded meetings. Returns id, title, date, duration, word count, language, and whether an AI summary exists.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum number of meetings to return (default 20)"),
                    "default": .int(20),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "description": .string("Pagination offset (default 0)"),
                    "default": .int(0),
                ]),
            ]),
        ])
    )

    private static let getMeetingTool = Tool(
        name: "get_meeting",
        description: "Get full details of a meeting by its UUID, including all transcript segments, AI summary, action items, and notes.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("id")]),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Meeting UUID"),
                ]),
            ]),
        ])
    )

    // MARK: - Handler

    static func handle(name: String, arguments: [String: Value]?) async throws -> CallTool.Result? {
        switch name {
        case "list_meetings": return try await listMeetings(arguments: arguments)
        case "get_meeting":   return try await getMeeting(arguments: arguments)
        default: return nil
        }
    }

    // MARK: - list_meetings

    private static func listMeetings(arguments: [String: Value]?) async throws -> CallTool.Result {
        let limit  = intArg(arguments, key: "limit",  default: 20)
        let offset = intArg(arguments, key: "offset", default: 0)

        let ctx = HistoryDatabase.shared.newBackgroundContext()
        let rows: [[String: Any]] = await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            req.fetchLimit  = max(1, min(limit, 100))
            req.fetchOffset = max(0, offset)
            guard let entities = try? ctx.fetch(req) else { return [] }
            return entities.map { e in
                [
                    "id":           e.id.uuidString,
                    "title":        e.title,
                    "createdAt":    iso8601(e.createdAt),
                    "duration":     e.duration,
                    "wordCount":    Int(e.wordCount),
                    "language":     e.language,
                    "isInProgress": e.isInProgress,
                    "hasAISummary": e.aiSummaryJSON.map { !$0.isEmpty } ?? false,
                    "segmentCount": jsonArrayCount(e.segmentsJSON),
                ]
            }
        }

        return CallTool.Result(content: [.text(text: jsonString(rows) ?? "[]", annotations: nil, _meta: nil)])
    }

    // MARK: - get_meeting

    private static func getMeeting(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let idStr = strArg(arguments, key: "id"),
            let uuid = UUID(uuidString: idStr)
        else {
            return CallTool.Result(
                content: [.text(text: "Error: missing or invalid 'id' argument", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let ctx = HistoryDatabase.shared.newBackgroundContext()
        let row: [String: Any]? = await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            req.fetchLimit = 1
            guard let e = try? ctx.fetch(req).first else { return nil }

            var result: [String: Any] = [
                "id":           e.id.uuidString,
                "title":        e.title,
                "createdAt":    iso8601(e.createdAt),
                "duration":     e.duration,
                "wordCount":    Int(e.wordCount),
                "language":     e.language,
                "modelUsed":    e.modelUsed,
                "isInProgress": e.isInProgress,
            ]

            // Segments
            let dec = JSONDecoder()
            if let raw = e.segmentsJSON, !raw.isEmpty,
               let data = raw.data(using: .utf8),
               let segs = try? dec.decode([MeetingSegment].self, from: data) {
                result["segments"] = segs.map { seg -> [String: Any] in
                    var s: [String: Any] = [
                        "timestamp":    seg.timestamp,
                        "endTimestamp": seg.endTimestamp,
                        "text":         seg.text,
                        "speaker":      seg.speakerName,
                    ]
                    if !seg.tags.isEmpty { s["tags"] = seg.tags.map { $0.rawValue } }
                    return s
                }
            } else {
                result["segments"] = []
            }

            // AI Summary
            if let raw = e.aiSummaryJSON, !raw.isEmpty,
               let data = raw.data(using: .utf8),
               let summary = try? dec.decode(MeetingAISummary.self, from: data) {
                result["aiSummary"] = [
                    "overview":      summary.overview,
                    "keyTopics":     summary.keyTopics.map { $0.text },
                    "decisions":     summary.decisions.map { ["label": $0.label, "text": $0.text] },
                    "openQuestions": summary.openQuestions.map { $0.text },
                    "actionItems":   summary.actionItems.map { item -> [String: Any] in
                        var a: [String: Any] = ["text": item.text, "owner": item.ownerName, "isDone": item.isDone]
                        if let d = item.dueLabel { a["dueLabel"] = d }
                        return a
                    },
                ] as [String: Any]
            }

            // Notes
            if let raw = e.notesJSON, !raw.isEmpty,
               let data = raw.data(using: .utf8),
               let notes = try? dec.decode([MeetingNote].self, from: data) {
                result["notes"] = notes.map { note -> [String: Any] in
                    ["kind": note.kind.rawValue, "text": note.text, "timestamp": note.timestamp]
                }
            } else {
                result["notes"] = []
            }

            return result
        }

        guard let row else {
            return CallTool.Result(
                content: [.text(text: "Meeting not found: \(idStr)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        return CallTool.Result(content: [.text(text: jsonString(row) ?? "{}", annotations: nil, _meta: nil)])
    }

    // MARK: - Helpers

    private static func intArg(_ args: [String: Value]?, key: String, default fallback: Int) -> Int {
        guard let v = args?[key] else { return fallback }
        if case .int(let i) = v { return i }
        if case .double(let d) = v { return Int(d) }
        return fallback
    }

    private static func strArg(_ args: [String: Value]?, key: String) -> String? {
        guard case .string(let s) = args?[key] else { return nil }
        return s
    }

    private static func jsonArrayCount(_ json: String?) -> Int {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 0 }
        return arr.count
    }

    private static func iso8601(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

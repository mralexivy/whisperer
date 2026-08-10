//
//  MCPTranscriptionTools.swift
//  Whisperer
//
//  MCP tools for transcription history: search_transcriptions, get_transcription.
//  Reads CoreData directly on a background context — no main actor dependency.
//

import Foundation
import CoreData
import MCP

enum MCPTranscriptionTools {

    // MARK: - Tool Definitions

    static var toolDefinitions: [Tool] {
        [searchTranscriptionsTool, getTranscriptionTool]
    }

    private static let searchTranscriptionsTool = Tool(
        name: "search_transcriptions",
        description: "Search dictation transcription history. Returns matching records sorted newest-first. Omit all arguments to list the most recent transcriptions.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Text to search for in transcription content (case-insensitive)"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum number of results to return (default 20, max 100)"),
                    "default": .int(20),
                ]),
                "dateFrom": .object([
                    "type": .string("string"),
                    "description": .string("ISO 8601 date string — return only transcriptions on or after this date"),
                ]),
                "dateTo": .object([
                    "type": .string("string"),
                    "description": .string("ISO 8601 date string — return only transcriptions on or before this date"),
                ]),
            ]),
        ])
    )

    private static let getTranscriptionTool = Tool(
        name: "get_transcription",
        description: "Get full details of a single transcription by its UUID, including text, duration, language, model used, pinned/flagged status, and AI-enhanced text if available.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("id")]),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Transcription UUID"),
                ]),
            ]),
        ])
    )

    // MARK: - Handler

    static func handle(name: String, arguments: [String: Value]?) async throws -> CallTool.Result? {
        switch name {
        case "search_transcriptions": return try await searchTranscriptions(arguments: arguments)
        case "get_transcription":     return try await getTranscription(arguments: arguments)
        default: return nil
        }
    }

    // MARK: - search_transcriptions

    private static func searchTranscriptions(arguments: [String: Value]?) async throws -> CallTool.Result {
        let query    = strArg(arguments, key: "query")
        let limit    = intArg(arguments, key: "limit",  default: 20)
        let dateFrom = parseDate(strArg(arguments, key: "dateFrom"))
        let dateTo   = parseDate(strArg(arguments, key: "dateTo"))

        let ctx = HistoryDatabase.shared.newBackgroundContext()
        let rows: [[String: Any]] = await ctx.perform {
            let req = TranscriptionEntity.fetchRequest()

            var predicates: [NSPredicate] = []
            if let q = query, !q.isEmpty {
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "transcription CONTAINS[cd] %@", q),
                    NSPredicate(format: "editedTranscription CONTAINS[cd] %@", q),
                ]))
            }
            if let from = dateFrom {
                predicates.append(NSPredicate(format: "createdAt >= %@", from as NSDate))
            }
            if let to = dateTo {
                predicates.append(NSPredicate(format: "createdAt <= %@", to as NSDate))
            }

            if !predicates.isEmpty {
                req.predicate = predicates.count == 1
                    ? predicates[0]
                    : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            }

            req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            req.fetchLimit = max(1, min(limit, 100))

            guard let entities = try? ctx.fetch(req) else { return [] }

            return entities.map { e in
                var row: [String: Any] = [
                    "id":            e.id.uuidString,
                    "text":          e.editedTranscription ?? e.transcription,
                    "timestamp":     iso8601(e.timestamp),
                    "createdAt":     iso8601(e.createdAt),
                    "duration":      e.duration,
                    "wordCount":     Int(e.wordCount),
                    "language":      e.language,
                    "isPinned":      e.isPinned,
                    "isFlagged":     e.isFlagged,
                ]
                if let app = e.targetAppName { row["targetApp"] = app }
                return row
            }
        }

        return CallTool.Result(content: [.text(text: jsonString(rows) ?? "[]", annotations: nil, _meta: nil)])
    }

    // MARK: - get_transcription

    private static func getTranscription(arguments: [String: Value]?) async throws -> CallTool.Result {
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
            let req = TranscriptionEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            req.fetchLimit = 1
            guard let e = try? ctx.fetch(req).first else { return nil }

            var result: [String: Any] = [
                "id":            e.id.uuidString,
                "transcription": e.transcription,
                "timestamp":     iso8601(e.timestamp),
                "createdAt":     iso8601(e.createdAt),
                "duration":      e.duration,
                "wordCount":     Int(e.wordCount),
                "language":      e.language,
                "modelUsed":     e.modelUsed,
                "isPinned":      e.isPinned,
                "isFlagged":     e.isFlagged,
            ]
            if let ed = e.editedTranscription { result["editedTranscription"] = ed }
            if let ai = e.aiEnhancedText      { result["aiEnhancedText"] = ai }
            if let mode = e.aiModeName        { result["aiModeName"] = mode }
            if let app = e.targetAppName      { result["targetApp"] = app }
            if let notes = e.notes            { result["notes"] = notes }
            return result
        }

        guard let row else {
            return CallTool.Result(
                content: [.text(text: "Transcription not found: \(idStr)", annotations: nil, _meta: nil)],
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

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

//
//  MCPMeetingTools.swift
//  Whisperer
//
//  MCP tools for meetings. Built for long meetings and small context windows:
//
//  - `get_meeting` returns the summary, the notes and an outline — not the transcript. A
//    two-hour meeting is ~25k words; dumping it on every call burned the client's context.
//  - `get_meeting_transcript` pages the transcript as compact text lines
//    ("[12:05] Dana: …"), bounded by a character budget, optionally by a time window or a
//    speaker, with a cursor for the next page.
//  - `search_meetings` finds the moments that matter (one meeting or all) and returns short
//    snippets with timestamps, so an agent reads only what it needs.
//  - Note tools let an AI app add its thoughts to a meeting: they are stored in Whisperer,
//    shown in the meeting, and used by Ask AI. AI apps can change only their own notes.
//
//  All reads run on a background Core Data context; JSON is compact (no pretty printing).
//

import Foundation
import CoreData
import MCP

nonisolated enum MCPMeetingTools {

    // MARK: - Tool Definitions

    static var toolDefinitions: [Tool] {
        var tools = [listMeetingsTool, getMeetingTool, getTranscriptTool, searchTool, listNotesTool]
        if MCPNoteWrites.enabled { tools += [addNoteTool, updateNoteTool, deleteNoteTool] }
        return tools
    }

    /// Names of tools that change data — annotated as not read-only.
    static let writeToolNames: Set<String> = ["add_meeting_note", "update_meeting_note", "delete_meeting_note"]
    static let destructiveToolNames: Set<String> = ["delete_meeting_note"]

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        var s: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { s["required"] = .array(required.map { .string($0) }) }
        return .object(s)
    }

    private static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let listMeetingsTool = Tool(
        name: "list_meetings",
        description: "List recorded meetings, newest first: id, title, date, duration, word count, language, whether it has an AI summary, and how many notes it has. Optional `query` filters by title.",
        inputSchema: schema([
            "limit": prop("integer", "Maximum meetings to return (default 20, max 100)"),
            "offset": prop("integer", "Pagination offset (default 0)"),
            "query": prop("string", "Only meetings whose title contains this text"),
        ])
    )

    private static let getMeetingTool = Tool(
        name: "get_meeting",
        description: "A meeting's summary, decisions, action items, open questions, notes (yours and AI-added), topic outline with timestamps, and transcript size. Does NOT include the transcript — use get_meeting_transcript or search_meetings for that.",
        inputSchema: schema(["id": prop("string", "Meeting UUID")], required: ["id"])
    )

    private static let getTranscriptTool = Tool(
        name: "get_meeting_transcript",
        description: "A page of a meeting's transcript as compact lines '[mm:ss] Speaker: text'. Bounded by max_chars; returns next_cursor when there is more. Narrow with from_seconds / to_seconds or speaker instead of reading everything.",
        inputSchema: schema([
            "id": prop("string", "Meeting UUID"),
            "cursor": prop("integer", "Segment index to start from (from a previous next_cursor)"),
            "from_seconds": prop("number", "Only lines at or after this time"),
            "to_seconds": prop("number", "Only lines before this time"),
            "speaker": prop("string", "Only this speaker's lines"),
            "max_chars": prop("integer", "Character budget for this page (default 12000, max 60000)"),
        ], required: ["id"])
    )

    private static let searchTool = Tool(
        name: "search_meetings",
        description: "Find moments in meeting transcripts and notes that match the query. Searches one meeting (meeting_id) or recent meetings. Returns short snippets with meeting id, title and timestamp; open the surrounding context with get_meeting_transcript(from_seconds:).",
        inputSchema: schema([
            "query": prop("string", "Words to look for"),
            "meeting_id": prop("string", "Only search this meeting"),
            "limit": prop("integer", "Maximum results (default 10, max 50)"),
        ], required: ["query"])
    )

    private static let listNotesTool = Tool(
        name: "list_meeting_notes",
        description: "The notes on a meeting: the user's own and those AI apps added, each with id, kind, timestamp (seconds into the meeting; -1 = about the whole meeting), author (null = the user) and text.",
        inputSchema: schema(["id": prop("string", "Meeting UUID")], required: ["id"])
    )

    private static let addNoteTool = Tool(
        name: "add_meeting_note",
        description: "Save a note to a meeting in Whisperer — a thought, decision, risk or idea worth keeping. It is shown in the meeting next to the user's notes, labelled with your name, and used when the user asks questions about the meeting later. Tie it to a moment with timestamp_seconds when it is about one.",
        inputSchema: schema([
            "meeting_id": prop("string", "Meeting UUID"),
            "text": prop("string", "The note (plain text, keep it short and specific)"),
            "kind": .object(["type": .string("string"), "enum": .array(NoteKind.allCases.map { .string($0.rawValue.lowercased()) }),
                             "description": .string("note (default), decision, risk or idea")]),
            "timestamp_seconds": prop("number", "Seconds into the meeting it refers to; omit for the whole meeting"),
            "author": prop("string", "Your name as the user knows you, e.g. 'Claude' or 'Codex'"),
        ], required: ["meeting_id", "text"])
    )

    private static let updateNoteTool = Tool(
        name: "update_meeting_note",
        description: "Change the text or kind of a note you added. The user's own notes can't be changed.",
        inputSchema: schema([
            "meeting_id": prop("string", "Meeting UUID"),
            "note_id": prop("string", "Note id from list_meeting_notes or add_meeting_note"),
            "text": prop("string", "New text"),
            "kind": prop("string", "note, decision, risk or idea"),
        ], required: ["meeting_id", "note_id", "text"])
    )

    private static let deleteNoteTool = Tool(
        name: "delete_meeting_note",
        description: "Remove a note you added. The user's own notes can't be removed.",
        inputSchema: schema([
            "meeting_id": prop("string", "Meeting UUID"),
            "note_id": prop("string", "Note id"),
        ], required: ["meeting_id", "note_id"])
    )

    // MARK: - Handler

    @concurrent static func handle(name: String, arguments: [String: Value]?) async throws -> CallTool.Result? {
        switch name {
        case "list_meetings":          return await listMeetings(arguments)
        case "get_meeting":            return await getMeeting(arguments)
        case "get_meeting_transcript": return await getTranscript(arguments)
        case "search_meetings":        return await search(arguments)
        case "list_meeting_notes":     return await listNotes(arguments)
        case "add_meeting_note":       return await addNote(arguments)
        case "update_meeting_note":    return await updateNote(arguments)
        case "delete_meeting_note":    return await deleteNote(arguments)
        default: return nil
        }
    }

    // MARK: - Loading

    /// Decoded meeting, from a background context.
    struct Loaded {
        var id: UUID
        var title: String
        var createdAt: Date?
        var duration: Double
        var wordCount: Int
        var language: String
        var isInProgress: Bool
        var segments: [MeetingSegment]
        var summary: MeetingAISummary?
        var notes: [MeetingNote]
    }

    static func load(_ id: UUID) async -> Loaded? {
        let ctx = await HistoryDatabase.shared.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            guard let e = try? ctx.fetch(req).first else { return nil }
            return loaded(e)
        }
    }

    nonisolated private static func loaded(_ e: MeetingEntity, segments includeSegments: Bool = true) -> Loaded {
        let dec = JSONDecoder()
        func decode<T: Decodable>(_ raw: String?, _ type: T.Type) -> T? {
            guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
            return try? dec.decode(type, from: data)
        }
        return Loaded(
            id: e.id, title: e.title, createdAt: e.createdAt, duration: e.duration,
            wordCount: Int(e.wordCount), language: e.language, isInProgress: e.isInProgress,
            segments: includeSegments ? (decode(e.segmentsJSON, [MeetingSegment].self) ?? []) : [],
            summary: decode(e.aiSummaryJSON, MeetingAISummary.self),
            notes: decode(e.notesJSON, [MeetingNote].self) ?? [])
    }

    // MARK: - list_meetings

    private static func listMeetings(_ arguments: [String: Value]?) async -> CallTool.Result {
        let limit  = max(1, min(intArg(arguments, "limit") ?? 20, 100))
        let offset = max(0, intArg(arguments, "offset") ?? 0)
        let query  = strArg(arguments, "query")?.trimmingCharacters(in: .whitespaces)

        let ctx = await HistoryDatabase.shared.newBackgroundContext()
        let rows: [[String: Any]] = await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            req.fetchLimit  = limit
            req.fetchOffset = offset
            if let query, !query.isEmpty {
                req.predicate = NSPredicate(format: "title CONTAINS[cd] %@", query)
            }
            guard let entities = try? ctx.fetch(req) else { return [] }
            return entities.map { e in
                [
                    "id":           e.id.uuidString,
                    "title":        e.title,
                    "createdAt":    iso8601(e.createdAt),
                    "durationSeconds": Int(e.duration),
                    "wordCount":    Int(e.wordCount),
                    "language":     e.language,
                    "isInProgress": e.isInProgress,
                    "hasAISummary": e.aiSummaryJSON.map { !$0.isEmpty } ?? false,
                    // Counted without decoding: list calls used to parse every transcript.
                    "noteCount":    occurrences(of: "\"kind\"", in: e.notesJSON),
                ]
            }
        }
        return ok(jsonString(["meetings": rows, "offset": offset, "nextOffset": rows.count == limit ? offset + limit : NSNull()]))
    }

    // MARK: - get_meeting

    private static func getMeeting(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard let id = uuidArg(arguments, "id") else { return error("Missing or invalid 'id'") }
        guard let m = await load(id) else { return error("Meeting not found: \(id.uuidString)") }

        var result: [String: Any] = [
            "id": m.id.uuidString,
            "title": m.title,
            "createdAt": iso8601(m.createdAt),
            "durationSeconds": Int(m.duration),
            "language": m.language,
            "isInProgress": m.isInProgress,
            "transcript": transcriptInfo(m.segments),
            "notes": m.notes.map(noteJSON),
        ]
        if let s = m.summary {
            result["summary"] = [
                "overview": s.overview,
                "topics": s.keyTopics.map { ["text": $0.text, "at": clock($0.timestampSeconds), "seconds": Int($0.timestampSeconds)] },
                "decisions": s.decisions.map { ["label": $0.label, "text": $0.text, "at": clock($0.timestampSeconds)] },
                "openQuestions": s.openQuestions.map { $0.text },
                "actionItems": s.actionItems.map { item -> [String: Any] in
                    var a: [String: Any] = ["text": item.text, "owner": item.ownerName, "done": item.isDone]
                    if let d = item.dueLabel { a["due"] = d }
                    return a
                },
                "nextMeeting": s.nextMeeting ?? NSNull(),
            ] as [String: Any]
        }
        if let p = MeetingAIProvenance.lookup(m.id), !p.isLocal { result["summaryBy"] = p.displayName }
        return ok(jsonString(result))
    }

    static func transcriptInfo(_ segments: [MeetingSegment]) -> [String: Any] {
        let chars = segments.reduce(0) { $0 + $1.text.count }
        var speakers: [String] = []
        for s in segments where !speakers.contains(s.speakerName) { speakers.append(s.speakerName) }
        return [
            "segments": segments.count,
            "characters": chars,
            "approxTokens": chars / 4,
            "speakers": speakers,
            "hint": "Read with get_meeting_transcript (paged, filter by from_seconds/to_seconds/speaker) or find moments with search_meetings.",
        ]
    }

    // MARK: - get_meeting_transcript

    static let defaultPageChars = 12_000
    static let maxPageChars = 60_000

    struct Page: Equatable {
        var lines: [String]
        var firstIndex: Int
        var nextCursor: Int?
    }

    /// Pure paging so it can be tested: lines from `cursor`, filtered, until `maxChars`.
    static func page(_ segments: [MeetingSegment], cursor: Int, from: Double?, to: Double?,
                     speaker: String?, maxChars: Int) -> Page {
        var lines: [String] = []
        var used = 0
        var i = max(0, cursor)
        let start = i
        let speakerKey = speaker?.lowercased()
        while i < segments.count {
            let s = segments[i]
            if let to, s.timestamp >= to { return Page(lines: lines, firstIndex: start, nextCursor: nil) }
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = !text.isEmpty
                && (from.map { s.timestamp >= $0 || s.endTimestamp > $0 } ?? true)
                && (speakerKey.map { s.speakerName.lowercased() == $0 } ?? true)
            if matches {
                let line = "[\(clock(s.timestamp))] \(s.speakerName): \(text)"
                if used + line.count > maxChars && !lines.isEmpty {
                    return Page(lines: lines, firstIndex: start, nextCursor: i)
                }
                lines.append(line)
                used += line.count + 1
            }
            i += 1
        }
        return Page(lines: lines, firstIndex: start, nextCursor: nil)
    }

    private static func getTranscript(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard let id = uuidArg(arguments, "id") else { return error("Missing or invalid 'id'") }
        guard let m = await load(id) else { return error("Meeting not found: \(id.uuidString)") }
        let budget = max(500, min(intArg(arguments, "max_chars") ?? defaultPageChars, maxPageChars))
        let p = page(m.segments, cursor: intArg(arguments, "cursor") ?? 0,
                     from: doubleArg(arguments, "from_seconds"), to: doubleArg(arguments, "to_seconds"),
                     speaker: strArg(arguments, "speaker"), maxChars: budget)
        var header = "\(m.title) — \(p.lines.count) line(s)"
        if let next = p.nextCursor {
            header += ", more remain: call again with cursor=\(next)"
        } else {
            header += ", end of transcript"
        }
        return ok(header + "\n\n" + p.lines.joined(separator: "\n"))
    }

    // MARK: - search_meetings

    struct Hit: Equatable {
        var meetingID: UUID
        var title: String
        var seconds: Double
        var speaker: String
        var snippet: String
        var score: Int
        var isNote: Bool
    }

    static func terms(_ query: String) -> [String] {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// Scores every segment and note by query-term hits; phrase matches score higher.
    static func search(in m: Loaded, terms: [String], phrase: String) -> [Hit] {
        guard !terms.isEmpty else { return [] }
        func score(_ text: String) -> Int {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            var s = terms.reduce(0) { $0 + (folded.contains($1) ? 1 : 0) }
            if s > 0, terms.count > 1, folded.contains(phrase) { s += terms.count }
            return s
        }
        var hits: [Hit] = []
        for seg in m.segments {
            let s = score(seg.text)
            if s > 0 {
                hits.append(Hit(meetingID: m.id, title: m.title, seconds: seg.timestamp, speaker: seg.speakerName,
                                snippet: snippet(seg.text, around: terms), score: s, isNote: false))
            }
        }
        for note in m.notes where !note.text.isEmpty {
            let s = score(note.text)
            if s > 0 {
                hits.append(Hit(meetingID: m.id, title: m.title, seconds: max(0, note.timestamp),
                                speaker: note.author ?? "You (note)", snippet: snippet(note.text, around: terms),
                                score: s + 1, isNote: true))
            }
        }
        return hits
    }

    static func snippet(_ text: String, around terms: [String], radius: Int = 110) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard text.count > radius * 2,
              let first = terms.compactMap({ folded.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return text
        }
        let center = folded.distance(from: folded.startIndex, to: first.lowerBound)
        let lo = max(0, center - radius), hi = min(text.count, center + radius)
        let start = text.index(text.startIndex, offsetBy: lo), end = text.index(text.startIndex, offsetBy: hi)
        return (lo > 0 ? "…" : "") + text[start..<end] + (hi < text.count ? "…" : "")
    }

    private static func search(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard let query = strArg(arguments, "query"), !terms(query).isEmpty else { return error("Missing 'query'") }
        let limit = max(1, min(intArg(arguments, "limit") ?? 10, 50))
        let t = terms(query)
        let phrase = t.joined(separator: " ")

        var meetings: [Loaded] = []
        if let id = uuidArg(arguments, "meeting_id") {
            guard let m = await load(id) else { return error("Meeting not found: \(id.uuidString)") }
            meetings = [m]
        } else {
            let ctx = await HistoryDatabase.shared.newBackgroundContext()
            meetings = await ctx.perform {
                let req = MeetingEntity.fetchRequest()
                req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                req.fetchLimit = 200
                return ((try? ctx.fetch(req)) ?? []).map { loaded($0) }
            }
        }
        let hits = meetings.flatMap { search(in: $0, terms: t, phrase: phrase) }
            .sorted { ($0.score, -$0.seconds) > ($1.score, -$1.seconds) }
            .prefix(limit)
        let rows: [[String: Any]] = hits.map { h in
            ["meetingId": h.meetingID.uuidString, "title": h.title, "at": clock(h.seconds), "seconds": Int(h.seconds),
             "speaker": h.speaker, "text": h.snippet, "source": h.isNote ? "note" : "transcript"]
        }
        return ok(jsonString(["query": query, "results": rows]))
    }

    // MARK: - Notes

    static func noteJSON(_ n: MeetingNote) -> [String: Any] {
        [
            "id": n.id.uuidString,
            "kind": n.kind.rawValue.lowercased(),
            "seconds": n.isGeneral ? -1 : Int(n.timestamp),
            "at": n.isGeneral ? "whole meeting" : clock(n.timestamp),
            "author": n.author ?? NSNull(),
            "text": n.text,
        ]
    }

    private static func listNotes(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard let id = uuidArg(arguments, "id") else { return error("Missing or invalid 'id'") }
        guard let notes = await MeetingNotesService.notes(meetingID: id) else { return error("Meeting not found: \(id.uuidString)") }
        return ok(jsonString(["notes": notes.map(noteJSON)]))
    }

    private static func addNote(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard MCPNoteWrites.enabled else { return error("Adding notes is turned off in Whisperer → MCP → Advanced.") }
        guard let id = uuidArg(arguments, "meeting_id") else { return error("Missing or invalid 'meeting_id'") }
        guard let text = strArg(arguments, "text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return error("Missing 'text'")
        }
        guard text.count <= 4_000 else { return error("Note too long (max 4000 characters).") }
        let kind = strArg(arguments, "kind").flatMap { NoteKind(rawValue: $0.uppercased()) } ?? .note
        let author = cleanAuthor(strArg(arguments, "author"))
        let note = MeetingNote(kind: kind, timestamp: doubleArg(arguments, "timestamp_seconds") ?? -1,
                               text: text, author: author)
        do {
            _ = try await MeetingNotesService.add(note, to: id)
            Logger.info("MCP: \(author) added a note to \(id)", subsystem: .app)
            return ok(jsonString(["saved": true, "note": noteJSON(note)]))
        } catch {
            return self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private static func updateNote(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard MCPNoteWrites.enabled else { return error("Changing notes is turned off in Whisperer → MCP → Advanced.") }
        guard let id = uuidArg(arguments, "meeting_id"), let noteID = uuidArg(arguments, "note_id") else {
            return error("Missing or invalid 'meeting_id' / 'note_id'")
        }
        guard let text = strArg(arguments, "text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return error("Missing 'text'")
        }
        let kind = strArg(arguments, "kind").flatMap { NoteKind(rawValue: $0.uppercased()) }
        do {
            let notes = try await MeetingNotesService.update(noteID: noteID, text: text, kind: kind, in: id, asAuthor: "mcp")
            let saved: Any = notes.first { $0.id == noteID }.map(noteJSON) ?? NSNull()
            return ok(jsonString(["saved": true, "note": saved]))
        } catch {
            return self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private static func deleteNote(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard MCPNoteWrites.enabled else { return error("Changing notes is turned off in Whisperer → MCP → Advanced.") }
        guard let id = uuidArg(arguments, "meeting_id"), let noteID = uuidArg(arguments, "note_id") else {
            return error("Missing or invalid 'meeting_id' / 'note_id'")
        }
        do {
            _ = try await MeetingNotesService.delete(noteID: noteID, in: id, asAuthor: "mcp")
            return ok(jsonString(["deleted": true]))
        } catch {
            return self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// The name shown on an AI-written note. Anything empty or long becomes "AI assistant".
    static func cleanAuthor(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return "AI assistant" }
        return trimmed
    }

    // MARK: - Helpers

    private static func ok(_ text: String?) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text ?? "{}", annotations: nil, _meta: nil)])
    }

    private static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)], isError: true)
    }

    private static func intArg(_ args: [String: Value]?, _ key: String) -> Int? {
        switch args?[key] {
        case .int(let i)?: return i
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }

    private static func doubleArg(_ args: [String: Value]?, _ key: String) -> Double? {
        switch args?[key] {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        case .string(let s)?: return Double(s)
        default: return nil
        }
    }

    private static func strArg(_ args: [String: Value]?, _ key: String) -> String? {
        guard case .string(let s) = args?[key] else { return nil }
        return s
    }

    private static func uuidArg(_ args: [String: Value]?, _ key: String) -> UUID? {
        strArg(args, key).flatMap { UUID(uuidString: $0) }
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    nonisolated private static func occurrences(of needle: String, in haystack: String?) -> Int {
        guard let haystack, !haystack.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    nonisolated private static func iso8601(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    static func jsonString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

/// Whether AI apps may add and change notes through MCP. On by default; the switch lives in
/// the MCP page's Advanced section.
nonisolated enum MCPNoteWrites {
    static let key = "mcpAllowNoteWrites"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

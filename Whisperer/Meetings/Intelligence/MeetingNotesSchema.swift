//
//  MeetingNotesSchema.swift
//  Whisperer
//
//  The one output contract every connected provider answers in: a JSON object with the
//  title first, then the summary fields `MeetingAISummary` stores. The local model keeps
//  its numbered line format (tuned for a 4B decoder) and is mapped into the same type by
//  `MeetingOverviewParser`; everything downstream sees `MeetingNotes`.
//
//  The schema is written to be accepted by OpenAI strict structured outputs (Codex
//  `--output-schema`, Responses `json_schema`), which requires every property to be listed
//  in `required` and `additionalProperties: false`. Optional values are nullable instead.
//

import Foundation

nonisolated enum MeetingNotesSchema {

    /// JSON Schema for the full notes artifact.
    static let full: String = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "overview", "topics", "decisions", "openQuestions", "nextMeeting", "actionItems"],
      "properties": {
        "title": { "type": "string", "description": "3 to 7 words naming the subject matter" },
        "overview": { "type": "string", "description": "The summary prose, paragraphs separated by a blank line" },
        "topics": {
          "type": "array",
          "items": {
            "type": "object", "additionalProperties": false,
            "required": ["text", "seconds"],
            "properties": { "text": { "type": "string" }, "seconds": { "type": ["number", "null"] } }
          }
        },
        "decisions": {
          "type": "array",
          "items": {
            "type": "object", "additionalProperties": false,
            "required": ["label", "text", "seconds"],
            "properties": {
              "label": { "type": "string" }, "text": { "type": "string" },
              "seconds": { "type": ["number", "null"] }
            }
          }
        },
        "openQuestions": {
          "type": "array",
          "items": {
            "type": "object", "additionalProperties": false,
            "required": ["text", "seconds"],
            "properties": { "text": { "type": "string" }, "seconds": { "type": ["number", "null"] } }
          }
        },
        "nextMeeting": { "type": ["string", "null"] },
        "actionItems": {
          "type": "array",
          "items": {
            "type": "object", "additionalProperties": false,
            "required": ["task", "owner", "due"],
            "properties": {
              "task": { "type": "string" },
              "owner": { "type": ["string", "null"] },
              "due": { "type": ["string", "null"] }
            }
          }
        }
      }
    }
    """

    /// Same contract, compact — for providers that take the schema on the command line.
    static var fullCompact: String {
        guard let data = full.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: compact, encoding: .utf8) else { return full }
        return text
    }

    // MARK: - Wire format

    /// Lenient mirror of the schema. Every field is optional so a truncated or slightly
    /// off-schema reply still yields whatever it did contain.
    struct Wire: Decodable {
        struct Stamped: Decodable { var text: String?; var seconds: Double? }
        struct Decision: Decodable { var label: String?; var text: String?; var seconds: Double? }
        struct Action: Decodable { var task: String?; var owner: String?; var due: String? }

        var title: String?
        var overview: String?
        var topics: [Stamped]?
        var decisions: [Decision]?
        var openQuestions: [Stamped]?
        var nextMeeting: String?
        var actionItems: [Action]?

        enum CodingKeys: String, CodingKey {
            case title, overview, topics, decisions, openQuestions, nextMeeting, actionItems
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title         = try? c.decode(String.self, forKey: .title)
            overview      = try? c.decode(String.self, forKey: .overview)
            topics        = try? c.decode([Stamped].self, forKey: .topics)
            decisions     = try? c.decode([Decision].self, forKey: .decisions)
            openQuestions = try? c.decode([Stamped].self, forKey: .openQuestions)
            nextMeeting   = try? c.decode(String.self, forKey: .nextMeeting)
            actionItems   = try? c.decode([Action].self, forKey: .actionItems)
        }
    }

    // MARK: - Decoding

    /// Decodes a provider reply into `MeetingNotes`. Accepts the bare object, an object
    /// wrapped in a ```json fence, or an object preceded or followed by chatter (CLIs that
    /// echo their input under a pty). Returns nil when no object with a usable overview
    /// is present — the router then falls back.
    static func decode(_ reply: String) -> MeetingNotes? {
        for candidate in jsonObjectCandidates(in: reply) {
            guard let data = candidate.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(Wire.self, from: data) else { continue }
            if let notes = notes(from: wire) { return notes }
        }
        return nil
    }

    /// Decodes an already-parsed JSON value (Claude Code's `structured_output`).
    static func decode(object: Any) -> MeetingNotes? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return decode(text)
    }

    static func notes(from wire: Wire) -> MeetingNotes? {
        let overview = (wire.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else { return nil }

        func clean(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        let topics = (wire.topics ?? []).compactMap { item -> TopicItem? in
            guard let text = clean(item.text) else { return nil }
            return TopicItem(text: text, timestampSeconds: max(0, item.seconds ?? 0))
        }
        let decisions = (wire.decisions ?? []).compactMap { item -> DecisionItem? in
            guard let text = clean(item.text) else { return nil }
            return DecisionItem(label: clean(item.label) ?? "", text: text,
                                timestampSeconds: max(0, item.seconds ?? 0))
        }
        let questions = (wire.openQuestions ?? []).compactMap { item -> QuestionItem? in
            guard let text = clean(item.text) else { return nil }
            return QuestionItem(text: text, timestampSeconds: max(0, item.seconds ?? 0))
        }
        // Unknown owner stays empty — never invented. "Unknown"/"N/A" from a model means the same.
        let unknownOwners: Set<String> = ["unknown", "n/a", "none", "tbd", "unassigned", "-"]
        let actions = (wire.actionItems ?? []).compactMap { item -> MeetingActionItem? in
            guard let task = clean(item.task) else { return nil }
            var owner = clean(item.owner) ?? ""
            if unknownOwners.contains(owner.lowercased()) { owner = "" }
            var due = clean(item.due)
            if let d = due, unknownOwners.contains(d.lowercased()) { due = nil }
            return MeetingActionItem(text: task, ownerName: owner, dueLabel: due)
        }

        let summary = MeetingAISummary(
            overview: overview,
            keyTopics: topics,
            decisions: decisions,
            openQuestions: questions,
            nextMeeting: clean(wire.nextMeeting),
            actionItems: actions,
            generatedAt: nil)
        return MeetingNotes(title: clean(wire.title), summary: summary)
    }

    /// Balanced-brace scan for top-level JSON objects, string-aware. Last candidate first:
    /// a CLI that echoes the prompt prints the answer after it.
    static func jsonObjectCandidates(in text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                if depth > 0 { inString = true }
            } else if ch == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if ch == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    results.append(String(text[s...i]))
                    start = nil
                }
            }
            i = text.index(after: i)
        }
        return results.reversed()
    }

    // MARK: - Streaming title

    private static let titleRegex = try! NSRegularExpression(
        pattern: #""title"\s*:\s*"((?:[^"\\]|\\.)*)""#)

    /// The title from a partial JSON stream, as soon as its closing quote has arrived.
    /// The schema lists `title` first, so on a streaming provider this fires seconds before
    /// the summary under it is done.
    static func streamedTitle(in partial: String) -> String? {
        let ns = partial as NSString
        guard let match = titleRegex.firstMatch(in: partial, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let escaped = ns.substring(with: match.range(at: 1))
        // Re-use JSON's own unescaping for \" \n א and friends.
        guard let data = "\"\(escaped)\"".data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

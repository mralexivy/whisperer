//
//  MeetingOverviewParser.swift
//  Whisperer
//
//  Parses the LLM's line-based meeting overview format into MeetingAISummary.
//  Each field is one line with a prefix and pipe-separated values — much more
//  robust than JSON for on-device LLMs that produce occasional syntax errors.
//
//  Format:
//    OVERVIEW: <text>
//    TOPIC: <text> | <seconds>
//    DECISION: <label> | <text> | <seconds>
//    OPEN: <text> | <seconds>
//    NEXT: <text or "none">
//    ACTION: <text> | <ownerName> | <dueLabel or "none">
//

import Foundation

enum MeetingOverviewParser {

    /// Every label the format defines. Any line that starts with one of these ends
    /// a multi-paragraph OVERVIEW.
    private static let labels = ["OVERVIEW:", "TOPIC:", "DECISION:", "OPEN:", "NEXT:", "ACTION:"]

    // MARK: - Public entry point

    static func parse(_ raw: String) -> MeetingAISummary? {
        var overviewLines = [String]()
        var inOverview    = false
        var keyTopics     = [TopicItem]()
        var decisions     = [DecisionItem]()
        var openQuestions = [QuestionItem]()
        var nextMeeting:    String? = nil
        var actionItems   = [MeetingActionItem]()

        for rawLine in raw.components(separatedBy: "\n") {
            let line     = rawLine.trimmingCharacters(in: .whitespaces)
            let isLabel  = labels.contains { line.hasPrefix($0) }

            // The overview runs to several paragraphs, so it continues across every
            // line — blank ones included, since those carry the paragraph breaks —
            // until the next label appears.
            if inOverview && !isLabel {
                overviewLines.append(line)
                continue
            }
            inOverview = false
            guard !line.isEmpty else { continue }

            if line.hasPrefix("OVERVIEW:") {
                overviewLines = [field(line, after: "OVERVIEW:")]
                inOverview = true

            } else if line.hasPrefix("TOPIC:") {
                let parts = parts(line, after: "TOPIC:", count: 2)
                if let text = parts.first.map(cleanText), !text.isEmpty {
                    let secs = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
                    keyTopics.append(TopicItem(text: text, timestampSeconds: secs))
                }

            } else if line.hasPrefix("DECISION:") {
                let parts = parts(line, after: "DECISION:", count: 3)
                if parts.count >= 2 {
                    let label = cleanText(parts[0])
                    let text  = cleanText(parts[1])
                    let secs  = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
                    if !label.isEmpty && !text.isEmpty {
                        decisions.append(DecisionItem(label: label, text: text, timestampSeconds: secs))
                    }
                }

            } else if line.hasPrefix("OPEN:") {
                let parts = parts(line, after: "OPEN:", count: 2)
                if let text = parts.first.map(cleanText), !text.isEmpty {
                    let secs = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
                    openQuestions.append(QuestionItem(text: text, timestampSeconds: secs))
                }

            } else if line.hasPrefix("NEXT:") {
                let val = cleanText(field(line, after: "NEXT:"))
                nextMeeting = (val.lowercased() == "none" || val.isEmpty) ? nil : val

            } else if line.hasPrefix("ACTION:") {
                let parts = parts(line, after: "ACTION:", count: 3)
                if parts.count >= 2 {
                    let text  = cleanText(parts[0])
                    let owner = cleanText(parts[1])
                    let due   = parts.count > 2 ? (parts[2].lowercased() == "none" ? nil : cleanText(parts[2])) : nil
                    // Reject if owner is empty or looks like a timestamp (e.g. "0:5:10")
                    let isTimestamp = owner.range(of: #"^\d+:\d"#, options: .regularExpression) != nil
                    if !text.isEmpty && !owner.isEmpty && !isTimestamp {
                        actionItems.append(MeetingActionItem(text: text, ownerName: owner, dueLabel: due))
                    }
                }
            }
        }

        let overview = joinParagraphs(overviewLines)
        guard !overview.isEmpty else { return nil }
        return MeetingAISummary(
            overview:      overview,
            keyTopics:     keyTopics,
            decisions:     decisions,
            openQuestions: openQuestions,
            nextMeeting:   nextMeeting,
            actionItems:   actionItems,
            generatedAt:   nil
        )
    }

    // MARK: - Private helpers

    /// Reflows the collected overview lines: blank lines become paragraph breaks,
    /// consecutive non-blank lines are joined into one paragraph (the model wraps
    /// mid-sentence, so a raw newline join would leave ragged text in the card).
    private static func joinParagraphs(_ lines: [String]) -> String {
        var paragraphs = [String]()
        var current    = [String]()

        for line in lines {
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                }
            } else {
                let cleaned = cleanText(line)
                if !cleaned.isEmpty { current.append(cleaned) }
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }

        return paragraphs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func cleanText(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix("<") { result = String(result.dropFirst()) }
        while result.hasSuffix(">") { result = String(result.dropLast()) }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func field(_ line: String, after prefix: String) -> String {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest
    }

    private static func parts(_ line: String, after prefix: String, count: Int) -> [String] {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest
            .components(separatedBy: "|")
            .prefix(count)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

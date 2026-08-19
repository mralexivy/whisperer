//
//  MeetingOverviewParser.swift
//  Whisperer
//
//  Parses the LLM's line-based meeting overview format into MeetingAISummary.
//  Each field is one line with a prefix and pipe-separated values — much more
//  robust than JSON for on-device LLMs that produce occasional syntax errors.
//
//  Format:
//    TITLE: <text>
//    OVERVIEW: <text>
//    TOPIC: <text> | <seconds>
//    DECISION: <label> | <text> | <seconds>
//    OPEN: <text> | <seconds>
//    NEXT: <text or "none">
//    ACTION: <text> | <ownerName> | <dueLabel or "none">
//
//  TITLE is the merged artifact pass's first line — it is parsed out of the stream long
//  before the rest arrives (see `firstCompleteTitle`) and carries no field in
//  `MeetingAISummary`, so `parse` recognizes it only to keep it out of the OVERVIEW.
//  TOPICS: and SUMMARY: are tolerated spellings of TOPIC: and OVERVIEW: — a 4B asked for
//  a seven-label artifact pluralizes one label per few dozen runs, and an unrecognized
//  label is not merely dropped: it is absorbed into whatever multi-line field precedes it.
//

import Foundation

enum MeetingOverviewParser {

    /// Every label the format defines. Any line that starts with one of these ends
    /// a multi-paragraph OVERVIEW.
    private static let labels = [
        "TITLE:", "OVERVIEW:", "SUMMARY:", "TOPIC:", "TOPICS:", "DECISION:", "OPEN:", "NEXT:", "ACTION:"
    ]

    // MARK: - Title

    private static let titleLabel = "TITLE:"

    /// The TITLE field of a *complete* artifact, or nil when there is none.
    ///
    /// Only a leading TITLE counts, same rule as the streaming path: a `TITLE:` the model
    /// emits halfway through an OVERVIEW is the format coming apart, and naming the recording
    /// from it is worse than leaving the placeholder in place.
    static func title(in raw: String) -> String? {
        for rawLine in raw.components(separatedBy: "\n") {
            let line = undecorate(rawLine)
            guard !line.isEmpty else { continue }
            guard line.hasPrefix(titleLabel) else { return nil }
            let value = cleanText(field(line, after: titleLabel))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The TITLE field of a *partial* stream, but only once the line is provably finished.
    ///
    /// The merged artifact emits TITLE first precisely so the library row can be named while
    /// the summary is still decoding. The line is only complete when a newline follows it —
    /// returning early would name a meeting "Redis migration plan" as "Redis mig".
    ///
    /// Callers poll this once per generated token, so it looks only at the opening
    /// `titleScanChars` of the output: the TITLE line is the first thing the prompt asks for,
    /// and rescanning a two-thousand-character accumulator every token would be quadratic.
    static func firstCompleteTitle(in partial: String) -> String? {
        let head = partial.count > titleScanChars ? String(partial.prefix(titleScanChars)) : partial
        guard head.contains("\n") else { return nil }
        for rawLine in head.components(separatedBy: "\n").dropLast() {
            let line = undecorate(rawLine)
            guard !line.isEmpty else { continue }
            // A finished line that is not the title means the artifact did not lead with one,
            // and no later line will change that — stop rather than pick up a TITLE the model
            // emitted in the middle of the OVERVIEW.
            guard line.hasPrefix(titleLabel) else { return nil }
            let value = cleanText(field(line, after: titleLabel))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// How far into a stream a TITLE line may start. Comfortably past a 70-character title
    /// plus its label, and short enough that per-token polling stays cheap.
    private static let titleScanChars = 300

    // MARK: - Public entry point

    static func parse(_ raw: String) -> MeetingAISummary? {
        var overviewLines = [String]()
        var inOverview    = false
        // SUMMARY is the merged artifact's alternative spelling of OVERVIEW, absorbed the same
        // way and used only when no OVERVIEW line appeared — a model that emits both wrote the
        // OVERVIEW it was asked for, and that one wins.
        var summaryLines  = [String]()
        var inSummary     = false
        var keyTopics     = [TopicItem]()
        var decisions     = [DecisionItem]()
        var openQuestions = [QuestionItem]()
        var nextMeeting:    String? = nil
        var actionItems   = [MeetingActionItem]()
        // Prose emitted before any label at all. Short notes come back as a bare sentence
        // from every model measured — the label is the first thing a small model drops when
        // the answer is one line long — and that sentence is unambiguously the overview.
        var strayLines    = [String]()
        var sawLabel      = false

        for rawLine in raw.components(separatedBy: "\n") {
            let line     = undecorate(rawLine)
            let isLabel  = labels.contains { line.hasPrefix($0) }

            // The overview runs to several paragraphs, so it continues across every
            // line — blank ones included, since those carry the paragraph breaks —
            // until the next label appears.
            if inOverview && !isLabel {
                overviewLines.append(line)
                continue
            }
            if inSummary && !isLabel {
                summaryLines.append(line)
                continue
            }
            inOverview = false
            inSummary  = false
            guard !line.isEmpty else { continue }

            // TITLE deliberately does not count: it carries no summary field, and a model that
            // emits `TITLE:` and then a bare unlabeled paragraph — the failure mode short notes
            // already had before the merge — must still reach the strayLines fallback below.
            if isLabel && !line.hasPrefix(titleLabel) { sawLabel = true }

            if line.hasPrefix("OVERVIEW:") {
                overviewLines = [field(line, after: "OVERVIEW:")]
                inOverview = true

            } else if line.hasPrefix("SUMMARY:") {
                summaryLines = [field(line, after: "SUMMARY:")]
                inSummary = true

            } else if line.hasPrefix("TITLE:") {
                // Consumed by `title(in:)` and by the streaming path; recognized here only so
                // it terminates an absorbing field instead of being pulled into one.
                continue

            } else if line.hasPrefix("TOPIC:") || line.hasPrefix("TOPICS:") {
                let label = line.hasPrefix("TOPICS:") ? "TOPICS:" : "TOPIC:"
                let parts = parts(line, after: label, count: 2)
                if let text = parts.first.map(cleanItem), !text.isEmpty {
                    let secs = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
                    keyTopics.append(TopicItem(text: text, timestampSeconds: secs))
                }

            } else if line.hasPrefix("DECISION:") {
                let parts = parts(line, after: "DECISION:", count: 3)
                if parts.count >= 2 {
                    let label = cleanItem(parts[0])
                    let text  = cleanItem(parts[1])
                    let secs  = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
                    if !label.isEmpty && !text.isEmpty {
                        decisions.append(DecisionItem(label: label, text: text, timestampSeconds: secs))
                    }
                }

            } else if line.hasPrefix("OPEN:") {
                let parts = parts(line, after: "OPEN:", count: 2)
                if let text = parts.first.map(cleanItem), !text.isEmpty {
                    let secs = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
                    openQuestions.append(QuestionItem(text: text, timestampSeconds: secs))
                }

            } else if line.hasPrefix("NEXT:") {
                let val = cleanItem(field(line, after: "NEXT:"))
                nextMeeting = (val.lowercased() == "none" || val.isEmpty) ? nil : val

            } else if line.hasPrefix("ACTION:") {
                let parts = parts(line, after: "ACTION:", count: 3)
                if parts.count >= 2 {
                    let text  = cleanItem(parts[0])
                    let owner = cleanItem(parts[1])
                    let due   = parts.count > 2 ? (parts[2].lowercased() == "none" ? nil : cleanItem(parts[2])) : nil
                    // Reject if owner is empty or looks like a timestamp (e.g. "0:5:10")
                    let isTimestamp = owner.range(of: #"^\d+:\d"#, options: .regularExpression) != nil
                    if !text.isEmpty && !owner.isEmpty && !isTimestamp {
                        actionItems.append(MeetingActionItem(text: text, ownerName: owner, dueLabel: due))
                    }
                }

            } else if !sawLabel {
                strayLines.append(line)
            }
        }

        // Unlabeled prose is used only when the model produced no OVERVIEW at all. It lets a
        // refusal through as a summary, which is the cost of not throwing away every
        // correctly-summarized short note — measured, both Qwen2.5-1.5B and Qwen3.5-4B drop
        // the label on those.
        var overview = joinParagraphs(overviewLines)
        if overview.isEmpty { overview = joinParagraphs(summaryLines) }
        if overview.isEmpty { overview = joinParagraphs(strayLines) }
        overview = truncatingLoop(overview)
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

    // MARK: - Degeneration

    // A structural gate passes a degenerate output: `TOPIC: the speaker is the is the is the…`
    // parses, has a timestamp in range and is non-empty, so it logged "parsed successfully" and
    // was written to CoreData as a summary. The decoder's own guard counts *identical consecutive*
    // tokens, which a two-token cycle never trips, so the content check has to live here.
    //
    // Consecutive n-gram repetition only. A distinct-word ratio was the other candidate and is
    // the wrong instrument: healthy prose in Hebrew or Russian carries far more inflected repeats
    // than English, so any threshold that catches a loop also flags real summaries in one of the
    // three languages this has to work in. A phrase repeated back-to-back three times is not
    // something a working decode does in any of them.

    /// Longest n-gram considered. Beyond ~5 words a "loop" is more likely a real refrain.
    private static let maxLoopPhrase = 5

    /// Word index at which the output starts looping, or nil when it never does.
    private static func loopStart(_ words: [String]) -> Int? {
        guard words.count >= 3 else { return nil }
        var earliest: Int? = nil

        for n in 1...maxLoopPhrase {
            // A single word has to repeat more before it counts: "no, no, no" is speech, and
            // "the the the" is not something the decoder produces without the longer runs too.
            let needed = n == 1 ? 5 : 3
            guard words.count >= n * needed else { continue }

            var i = 0
            while i + n * needed <= words.count {
                var repeats = 1
                while i + n * (repeats + 1) <= words.count,
                      Array(words[(i + n * repeats)..<(i + n * (repeats + 1))])
                        == Array(words[i..<(i + n)]) {
                    repeats += 1
                }
                if repeats >= needed {
                    // Keep the first occurrence — it is usually the tail of a real sentence.
                    earliest = min(earliest ?? Int.max, i + n)
                    break
                }
                i += 1
            }
        }
        return earliest
    }

    private static func isLooping(_ text: String) -> Bool {
        loopStart(words(of: text)) != nil
    }

    /// Cuts a looping tail off `text` and backs up to the last sentence terminator, so what
    /// survives reads as prose rather than stopping mid-clause. Returns "" when nothing does.
    private static func truncatingLoop(_ text: String) -> String {
        let parts = words(of: text)
        guard let start = loopStart(parts) else { return text }

        let kept = parts[0..<start].joined(separator: " ")
        Logger.warning("Meeting overview: looping output trimmed at word \(start) of \(parts.count)", subsystem: .transcription)

        guard let end = lastSentenceEnd(in: kept) else { return "" }
        return String(kept[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `cleanText` for a one-line field. A looping TOPIC / DECISION / OPEN / ACTION is dropped
    /// whole rather than trimmed — the line is one short phrase, and half of one is not a topic.
    private static func cleanItem(_ s: String) -> String {
        let cleaned = cleanText(s)
        guard isLooping(cleaned) else { return cleaned }
        Logger.warning("Meeting overview: dropped looping item \"\(cleaned.prefix(60))\"", subsystem: .transcription)
        return ""
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    /// Index just past the last sentence terminator, requiring whitespace or end-of-string after
    /// it so the `.` in "3.5 million" is not mistaken for one.
    private static func lastSentenceEnd(in text: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        var found: String.Index? = nil
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if terminators.contains(text[i]), next == text.endIndex || text[next].isWhitespace {
                found = next
            }
            i = next
        }
        return found
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

    /// Strips the markdown a small model adds around a label it was told not to decorate —
    /// `**OVERVIEW:**`, `## TOPIC:`, `- OPEN:`. The decoration carries no information, and
    /// two asterisks were enough to make `hasPrefix("OVERVIEW:")` miss and drop a whole summary.
    /// Applied to body lines too, which turns a stray bullet back into the plain sentence the
    /// prompt asked for.
    private static func undecorate(_ line: String) -> String {
        var s = line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        while let first = s.first, first == "#" || first == "*" || first == "-" || first == ">" || first == " " || first == "\t" {
            s = String(s.dropFirst())
        }
        return s.trimmingCharacters(in: .whitespaces)
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

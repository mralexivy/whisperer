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
    ///
    /// Two spelling families are accepted for backward compatibility:
    /// - English labels from the old prompt (TITLE:, OVERVIEW:, …)
    /// - Numbered markers from the current prompt (1|, 2|, 3|, …)
    ///   Digits and | survive any model translation, so they work in any language.
    private static let labels = [
        "TITLE:", "OVERVIEW:", "SUMMARY:", "TOPIC:", "TOPICS:", "DECISION:", "OPEN:", "NEXT:", "ACTION:",
        "1|", "2|", "3|", "4|", "5|", "6|", "7|"
    ]

    // MARK: - Title

    private static let titleLabel = "TITLE:"
    /// Numbered-marker spelling for the title (current prompt format).
    private static let titleMarker = "1|"

    /// Extracts the title text from a line that starts with either `TITLE:` or `1|`.
    private static func extractTitle(from line: String) -> String? {
        if line.hasPrefix(titleLabel) {
            let v = cleanText(field(line, after: titleLabel))
            return v.isEmpty ? nil : v
        }
        if line.hasPrefix(titleMarker) {
            let v = cleanText(field(line, after: titleMarker))
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Whether a line is a title line in either format.
    private static func isTitleLine(_ line: String) -> Bool {
        line.hasPrefix(titleLabel) || line.hasPrefix(titleMarker)
    }

    /// The TITLE field of a *complete* artifact, or nil when there is none.
    ///
    /// Only a leading TITLE counts, same rule as the streaming path: a `TITLE:` or `1|` the
    /// model emits halfway through an OVERVIEW is the format coming apart, and naming the
    /// recording from it is worse than leaving the placeholder in place.
    static func title(in raw: String) -> String? {
        for rawLine in raw.components(separatedBy: "\n") {
            let line = undecorate(rawLine)
            guard !line.isEmpty else { continue }
            guard isTitleLine(line) else { return nil }
            return extractTitle(from: line)
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
            guard isTitleLine(line) else { return nil }
            return extractTitle(from: line)
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
            // emits `TITLE:` or `1|` and then a bare unlabeled paragraph — the failure mode
            // short notes already had before the merge — must still reach the strayLines fallback.
            if isLabel && !isTitleLine(line) { sawLabel = true }

            if line.hasPrefix("OVERVIEW:") || line.hasPrefix("3|") {
                let pfx = line.hasPrefix("3|") ? "3|" : "OVERVIEW:"
                overviewLines = [field(line, after: pfx)]
                inOverview = true

            } else if line.hasPrefix("SUMMARY:") {
                summaryLines = [field(line, after: "SUMMARY:")]
                inSummary = true

            } else if isTitleLine(line) {
                // Consumed by `title(in:)` and by the streaming path; recognized here only so
                // it terminates an absorbing field instead of being pulled into one.
                continue

            } else if line.hasPrefix("TOPIC:") || line.hasPrefix("TOPICS:") || line.hasPrefix("2|") {
                let label = line.hasPrefix("TOPICS:") ? "TOPICS:" : (line.hasPrefix("2|") ? "2|" : "TOPIC:")
                let parts = parts(line, after: label, count: 2)
                if let text = parts.first.map(cleanItem), !text.isEmpty {
                    let secs = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
                    keyTopics.append(TopicItem(text: text, timestampSeconds: secs))
                }

            } else if line.hasPrefix("DECISION:") || line.hasPrefix("4|") {
                let pfx = line.hasPrefix("4|") ? "4|" : "DECISION:"
                let parts = parts(line, after: pfx, count: 3)
                if parts.count >= 2 {
                    let label = cleanItem(parts[0])
                    let text  = cleanItem(parts[1])
                    let secs  = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
                    if !label.isEmpty && !text.isEmpty {
                        decisions.append(DecisionItem(label: label, text: text, timestampSeconds: secs))
                    }
                }

            } else if line.hasPrefix("OPEN:") || line.hasPrefix("5|") {
                let pfx = line.hasPrefix("5|") ? "5|" : "OPEN:"
                let parts = parts(line, after: pfx, count: 2)
                if let text = parts.first.map(cleanItem), !text.isEmpty {
                    let secs = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
                    openQuestions.append(QuestionItem(text: text, timestampSeconds: secs))
                }

            } else if line.hasPrefix("NEXT:") || line.hasPrefix("6|") {
                let pfx = line.hasPrefix("6|") ? "6|" : "NEXT:"
                let val = cleanItem(field(line, after: pfx))
                nextMeeting = (val.lowercased() == "none" || val.isEmpty) ? nil : val

            } else if line.hasPrefix("ACTION:") || line.hasPrefix("7|") {
                let pfx = line.hasPrefix("7|") ? "7|" : "ACTION:"
                let parts = parts(line, after: pfx, count: 3)
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

        // Unlabeled prose is used only when the model produced no OVERVIEW at all.
        // It lets a correctly-summarized short note through when the model drops the
        // label (measured on Qwen2.5-1.5B and Qwen3.5-4B). But a long raw generation
        // that had no recognised label — because the model translated them or emitted
        // an entirely different structure — must NOT be shipped as-is: the whole dump
        // falls here and the user sees raw model output, labels, timestamps and all.
        // Guard: only accept stray lines when they look like a short unlabeled note.
        var overview = joinParagraphs(overviewLines)
        if overview.isEmpty { overview = joinParagraphs(summaryLines) }
        if overview.isEmpty {
            let strayText = joinParagraphs(strayLines)
            if isAcceptableStrayOverview(strayText) {
                overview = strayText
            } else if !strayText.isEmpty {
                Logger.warning("Meeting overview: rejecting \(strayText.count)-char stray dump — no label recognised and content looks structured", subsystem: .transcription)
            }
        }
        overview = truncatingLoop(overview)
        overview = stripTimestampDensity(overview)
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

    /// `loopStart` splits on whitespace, so a character spiral — which contains none — reads as a
    /// single word and cannot trip it. Checking both means a degenerate TOPIC or OVERVIEW line
    /// goes through `truncatingLoop` / `cleanItem` instead of being written to CoreData.
    private static func isLooping(_ text: String) -> Bool {
        loopStart(words(of: text)) != nil || TranscriptRepetition.containsCharacterLoop(in: text)
    }

    /// Cuts a looping tail off `text` and backs up to the last sentence terminator, so what
    /// survives reads as prose rather than stopping mid-clause. Returns "" when nothing does.
    private static func truncatingLoop(_ text: String) -> String {
        // Character spirals are collapsed before the word scan rather than truncated by it: they
        // are a single word, so `loopStart` returns nil for them and the text would come back
        // untouched. Collapsing keeps the prose that precedes the wall.
        let text = TranscriptRepetition.collapsingDegenerateRuns(in: text)
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

    // MARK: - Stray-lines guard

    /// Maximum word count for an overview assembled entirely from unlabeled prose.
    ///
    /// Short notes sometimes come back as one bare sentence — both Qwen2.5-1.5B and
    /// Qwen3.5-4B drop the label on them. That is the only case where stray lines are
    /// the right answer. Anything longer is a broken artifact: the model emitted a
    /// full structured generation but with translated or omitted labels, and the whole
    /// raw dump fell here. 120 words is comfortably above the note tier (~70 words) and
    /// comfortably below the brief tier (~146 words), so it draws the line correctly.
    private static let maxStrayWords = 120

    /// True when unlabeled prose looks like a short note rather than a raw model dump.
    ///
    /// Three conditions: short enough to be a note, no pipe-separated fields (which
    /// indicate structured lines the parser should have parsed), and no unrecognised
    /// `WORD:` or `N|` patterns (which indicate the model emitted labels we missed).
    private static func isAcceptableStrayOverview(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount <= maxStrayWords else { return false }
        // Pipe separators inside stray prose → structured fields that should have parsed.
        if text.contains("|") { return false }
        // Lines like "OVERVIEWING:" or "3|" — unrecognised label, do not let through.
        let structuredLine = text.range(
            of: #"(?m)^(?:[A-Z]{3,}:|[1-7]\|)"#, options: .regularExpression)
        if structuredLine != nil { return false }
        return true
    }

    // MARK: - Timestamp-density guard

    /// Strips recognised timestamp markers and rejects the overview if they made up
    /// more than `maxTimestampFraction` of its token mass, or if the prose that
    /// remains is below `minProseWords` words.
    ///
    /// The prompt forbids [Ns] markers inside the OVERVIEW, so a high density of them
    /// is unambiguously degenerate output — typically a model that reproduced the
    /// transcript's `[95s] …` format verbatim, or put TOPIC/DECISION timestamps
    /// inside the overview text. `loopStart` cannot catch this because the timestamps
    /// are all distinct numbers.
    private static let maxTimestampFraction: Double = 0.25
    private static let minProseWords = 8

    /// Timestamp patterns that should never appear in a clean OVERVIEW line.
    private static let timestampPatterns: [NSRegularExpression] = {
        let raw = [
            #"\[\d+s\]"#,           // [95s]
            #"\b\d+s\b"#,           // bare 95s
            #"\|\s*\d+\s*\w*\s*$"#  // | 3480 שניות at end of a pipe field
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Returns `""` when the overview has too many timestamp markers; otherwise returns it
    /// with the markers stripped so they don't appear in the rendered card.
    private static func stripTimestampDensity(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var stripped = text
        for re in timestampPatterns {
            let nsText = stripped as NSString
            stripped = re.stringByReplacingMatches(
                in: stripped,
                range: NSRange(location: 0, length: nsText.length),
                withTemplate: "")
        }
        stripped = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // How many words did we strip?
        let originalWords = Double(text.split(whereSeparator: { $0.isWhitespace }).count)
        let strippedWords = Double(stripped.split(whereSeparator: { $0.isWhitespace }).count)
        let removedFraction = originalWords > 0 ? (originalWords - strippedWords) / originalWords : 0

        // Only apply the density gate when timestamps were actually found. A clean
        // overview with no timestamps passes regardless of word count — the
        // minProseWords floor only makes sense when we know markers were present.
        guard removedFraction > 0 else { return stripped }

        if removedFraction >= maxTimestampFraction || strippedWords < Double(minProseWords) {
            Logger.warning(
                "Meeting overview: rejected — timestamp density \(Int(removedFraction * 100))% " +
                "(\(Int(originalWords - strippedWords)) of \(Int(originalWords)) words were markers)",
                subsystem: .transcription)
            return ""
        }
        return stripped
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

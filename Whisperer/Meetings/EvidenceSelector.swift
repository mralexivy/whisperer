//
//  EvidenceSelector.swift
//  Whisperer
//
//  Compresses a finalized meeting transcript down to the utterances an artifact pass
//  actually needs, so one LLM call can cover a long meeting instead of prefilling
//  ~12,000 tokens of transcript it mostly ignores.
//
//  Text-only by construction. Meetings transcribe on Nemotron, whose `ASRCapabilities`
//  is empty — there are no word timings and no token probabilities to score with, and a
//  selector that quietly depended on either would work in a Whisper-backed test and
//  select nothing in production. Everything here reads `MeetingSegment.text` and the
//  segment's start time, both of which exist on every backend.
//

import Foundation

// MARK: - Selected evidence

/// One kept utterance. `segmentID` is the whole point of the type: a DECISION the model
/// writes from this line can be resolved back to the segment it came from, and from there
/// to an audio offset the UI can play.
struct EvidenceLine: Identifiable, Equatable {
    let segmentID: UUID
    let timestamp: Double
    let text: String
    /// Selection score. Kept so a caller can explain *why* a line survived, and so tests
    /// can assert the ranking rather than just the output size.
    let score: Int
    /// First utterance of a new 5-minute chapter bucket — placeholder topic segmentation
    /// until mmBERT boundary heads land.
    let isTopicBoundary: Bool
    /// Position in the meeting's non-empty segment list. Only used to spot the gaps left by
    /// dropped material when rendering; the durable reference back to the audio is `segmentID`.
    let sourceIndex: Int

    var id: UUID { segmentID }
}

/// Result of one selection pass.
struct SelectedEvidence {
    let lines: [EvidenceLine]
    /// Estimated prompt tokens of `transcriptText()`, by the same chars-per-token rule
    /// `LLMPostProcessor` sizes its output budget with.
    let estimatedTokens: Int
    /// Non-empty segments left out. Zero means the artifact pass sees the whole meeting.
    let droppedSegmentCount: Int

    var isEmpty: Bool { lines.isEmpty }
    var isComplete: Bool { droppedSegmentCount == 0 }

    /// The evidence rendered for the prompt, in chronological order, with the same `[Ns]`
    /// markers `MeetingAIService.narrativeTranscript` uses — the artifact prompt tells the
    /// model to copy those numbers into its seconds fields, and they have to look identical
    /// whether or not selection ran.
    ///
    /// A gap between kept lines is marked with an ellipsis line. Without it the model reads
    /// two unrelated moments as consecutive and invents the transition between them.
    func transcriptText() -> String {
        var out = [String]()
        var previousIndexInMeeting: Int? = nil
        for line in lines {
            if let previous = previousIndexInMeeting, line.sourceIndex > previous + 1 {
                out.append("…")
            }
            previousIndexInMeeting = line.sourceIndex
            out.append("[\(Int(line.timestamp))s] \(line.text)")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Selector

enum EvidenceSelector {

    /// Upper bound on what the artifact pass is handed. The plan's band is 1,500–3,000
    /// tokens: below ~1,500 a long meeting loses whole chapters, above ~3,000 the prefill
    /// stops being the thing this exists to remove.
    static let defaultTokenBudget = 3_000

    /// Placeholder topic segmentation: the same 5-minute chapter buckets the meeting UI
    /// already groups by. A real boundary detector replaces this, not the surrounding code.
    static let chapterBucketSeconds: Double = 300

    /// Selects evidence from `segments` under `tokenBudget`.
    ///
    /// Deterministic: the same segments in, the same lines out, every time. Ranking ties
    /// break on timestamp and then on UUID string, so nothing depends on hash order.
    static func select(_ segments: [MeetingSegment], tokenBudget: Int = defaultTokenBudget) -> SelectedEvidence {
        let usable = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
        guard !usable.isEmpty else {
            return SelectedEvidence(lines: [], estimatedTokens: 0, droppedSegmentCount: 0)
        }

        let scored = score(usable)

        // Whole meeting fits: selecting anything at all would only lose material for nothing.
        let wholeCost = scored.reduce(0) { $0 + $1.cost }
        if wholeCost <= tokenBudget {
            let lines = scored.map { $0.line }
            return SelectedEvidence(
                lines: lines,
                estimatedTokens: wholeCost,
                droppedSegmentCount: 0
            )
        }

        // Greedy by score, packing rather than stopping at the first line that does not fit:
        // one long low-value monologue near the top of the ranking would otherwise waste the
        // remaining budget that several short decisions could have used.
        let ranked = scored.sorted {
            if $0.line.score != $1.line.score { return $0.line.score > $1.line.score }
            if $0.line.timestamp != $1.line.timestamp { return $0.line.timestamp < $1.line.timestamp }
            return $0.line.segmentID.uuidString < $1.line.segmentID.uuidString
        }

        var used = 0
        var keptIndices = Set<Int>()
        for candidate in ranked {
            guard used + candidate.cost <= tokenBudget else { continue }
            used += candidate.cost
            keptIndices.insert(candidate.line.sourceIndex)
        }
        // A budget smaller than the single highest-scoring utterance would otherwise return
        // nothing and make the artifact pass summarize an empty transcript.
        if keptIndices.isEmpty, let first = ranked.first {
            keptIndices.insert(first.line.sourceIndex)
            used = first.cost
        }

        let lines = scored
            .filter { keptIndices.contains($0.line.sourceIndex) }
            .map { $0.line }

        Logger.info(
            "Meeting evidence: kept \(lines.count)/\(usable.count) utterances, ~\(used) of \(tokenBudget) tokens (full transcript ~\(wholeCost))",
            subsystem: .transcription
        )

        return SelectedEvidence(
            lines: lines,
            estimatedTokens: used,
            droppedSegmentCount: usable.count - lines.count
        )
    }

    // MARK: - Scoring

    private struct ScoredLine {
        let line: EvidenceLine
        /// Prompt cost of this line as rendered, including its `[Ns]` marker and newline.
        let cost: Int
    }

    private static func score(_ segments: [MeetingSegment]) -> [ScoredLine] {
        // Boundary set is computed over the whole meeting first: a boundary's *neighbour*
        // scores too, because the sentence that opens a chapter is usually the throat-clear
        // and the one after it is the actual subject.
        var boundaryIndices = Set<Int>()
        var neighbourIndices = Set<Int>()
        var lastBucket = -1
        for (index, segment) in segments.enumerated() {
            let bucket = Int(segment.timestamp / chapterBucketSeconds)
            guard bucket != lastBucket else { continue }
            lastBucket = bucket
            boundaryIndices.insert(index)
            if index + 1 < segments.count { neighbourIndices.insert(index + 1) }
        }

        let lastIndex = segments.count - 1
        return segments.enumerated().map { index, segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = text.lowercased()
            let words = text.split(whereSeparator: { $0.isWhitespace })

            var score = 0
            let hasDecision = contains(folded, any: decisionCues)
            let hasAction   = contains(folded, any: actionCues)
            let hasQuestion = text.contains(where: { questionMarks.contains($0) })
                || contains(folded, any: questionCues)

            if hasDecision { score += 4 }
            if hasAction   { score += 3 }
            if hasQuestion { score += 2 }

            // Specifics are what an overview is judged on — a line carrying a number or a
            // proper noun says something a paraphrase of it cannot.
            if text.contains(where: { $0.isNumber }) { score += 1 }
            if hasInteriorCapital(words) { score += 1 }

            if boundaryIndices.contains(index)  { score += 3 }
            if neighbourIndices.contains(index) { score += 2 }

            // Head and tail: the opening states the subject and the closing usually states
            // the conclusion. Same reasoning as the title excerpt in MeetingAIService.
            if index <= 1                  { score += 3 }
            if index >= lastIndex - 1      { score += 2 }

            // Filler-dense stretches are the cheapest thing to drop: "yeah, um, right, so,
            // like, yeah" costs tokens and carries nothing. Cue-bearing lines are exempt —
            // "um, so we'll go with Redis" is filler-dense and is the decision.
            if !hasDecision && !hasAction {
                if words.count < 4 { score -= 3 }
                if fillerRatio(words) > 0.5 { score -= 3 }
            }

            let line = EvidenceLine(
                segmentID:       segment.id,
                timestamp:       segment.timestamp,
                text:            text,
                score:           score,
                isTopicBoundary: boundaryIndices.contains(index),
                sourceIndex:     index
            )
            return ScoredLine(line: line, cost: estimatedTokens(of: "[\(Int(segment.timestamp))s] \(text)") + 1)
        }
    }

    private static func hasInteriorCapital(_ words: [Substring]) -> Bool {
        guard words.count > 1 else { return false }
        return words.dropFirst().contains { $0.first?.isUppercase == true }
    }

    private static func fillerRatio(_ words: [Substring]) -> Double {
        guard !words.isEmpty else { return 1 }
        let hits = words.reduce(0) { acc, word in
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return acc + (fillerWords.contains(bare) ? 1 : 0)
        }
        return Double(hits) / Double(words.count)
    }

    private static func contains(_ folded: String, any needles: [String]) -> Bool {
        needles.contains { folded.contains($0) }
    }

    // MARK: - Token estimate

    /// Mirrors the chars-per-token split in `LLMPostProcessor.process` — 4 chars per token
    /// for Latin script, 2 for Hebrew/Arabic/CJK. An English-calibrated estimate lets a
    /// Hebrew meeting through at twice the budget it was supposed to be held to.
    static func estimatedTokens(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / (containsNonLatinScript(text) ? 2 : 4))
    }

    private static func containsNonLatinScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x0590 && v <= 0x05FF { return true }  // Hebrew
            if v >= 0x0600 && v <= 0x06FF { return true }  // Arabic
            if v >= 0x3040 && v <= 0x30FF { return true }  // Hiragana + Katakana
            if v >= 0x3400 && v <= 0x4DBF { return true }  // CJK Extension A
            if v >= 0x4E00 && v <= 0x9FFF { return true }  // CJK Unified Ideographs
            if v >= 0xAC00 && v <= 0xD7AF { return true }  // Hangul
        }
        return false
    }

    // MARK: - Cue lexicons

    // Substring matches, not word matches: the transcript is ASR output with inflection and
    // no reliable punctuation, and "решили" has to hit inside "мы решили" and "порешили"
    // alike. Covers the three languages this app is tested in — English, Hebrew, Russian —
    // and degrades to the structural signals (boundary, head/tail, numbers) in any other.

    private static let decisionCues = [
        "we decided", "we've decided", "decision", "decided to", "let's go with",
        "we'll go with", "going with", "we agreed", "agreed to", "settled on", "we picked",
        "we chose", "final call",
        "решили", "договорились", "решение", "выбрали", "остановились на",
        "החלטנו", "סיכמנו", "החלטה", "בחרנו"
    ]

    private static let actionCues = [
        "i'll ", "i will ", "we'll ", "action item", "takes care of", "take care of",
        "follow up", "next step", "by monday", "by tuesday", "by wednesday", "by thursday",
        "by friday", "deadline", "due date", "assigned to", "owner is", "todo", "to-do",
        "сделаю", "отправлю", "назначим", "задача", "дедлайн", "срок",
        "אני אעשה", "אשלח", "משימה", "דדליין", "אחראי"
    ]

    private static let questionCues = [
        "how do we", "what about", "should we", "do we need", "open question",
        "открытый вопрос", "как мы", "нужно ли",
        "שאלה פתוחה", "האם", "מה עם"
    ]

    private static let questionMarks: Set<Character> = ["?", "？", "؟"]

    private static let fillerWords: Set<String> = [
        "um", "uh", "er", "erm", "hmm", "mm", "mhm", "yeah", "yep", "ok", "okay", "right",
        "so", "like", "well", "just", "actually", "basically", "literally", "anyway",
        "ну", "вот", "это", "типа", "короче", "значит", "эээ", "ага", "да",
        "אה", "אמ", "כאילו", "יעני", "טוב", "אוקיי", "כן"
    ]
}

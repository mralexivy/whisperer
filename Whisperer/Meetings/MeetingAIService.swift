//
//  MeetingAIService.swift
//  Whisperer
//
//  LLM-powered meeting overview generation and whole-transcript Q&A.
//  ask() passes the full timestamped transcript in the system prompt, enabling
//  KV-cache reuse so repeated questions about the same meeting are fast.
//

import Foundation

// MARK: - Chunk value type (citation resolved from an LLM response)

/// Represents a segment of the meeting transcript cited by the LLM in its answer.
/// Moved here from the deleted MeetingRAGEngine. Must stay Codable — MeetingChatStore
/// persists assistant messages with their sources as JSON.
struct RAGChunk: Codable, Equatable {
    let text: String
    let startTimestamp: Double
    let endTimestamp: Double
    let speakers: [String]
    var score: Float

    var formattedStart: String {
        let s = Int(startTimestamp)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var speakersLabel: String {
        speakers.isEmpty ? "Speaker" : speakers.joined(separator: ", ")
    }
}

// MARK: - Answer model

struct RAGAnswer {
    let text: String
    let sources: [RAGChunk]   // citations parsed from the LLM response
    let usedRAG: Bool
}

// MARK: - Service

actor MeetingAIService {
    static let shared = MeetingAIService()

    /// Pre-compiled regex for citation parsing. The pattern is a string literal
    /// that never fails to compile, so force-try is safe.
    private static let citationRegex = try! NSRegularExpression(pattern: #"\[(\d+)s\]"#)

    private init() {}

    // MARK: - LLM borrow helpers

    /// Acquires the meeting intelligence LLM. Returns nil when unavailable.
    /// Callers MUST call releaseLLM() on every code path after a successful acquire.
    private func acquireLLM() async -> LLMPostProcessor? {
        #if canImport(FluidAudio)
        return await MeetingEngines.shared.borrowLLM()
        #else
        let (llm, loaded) = await MainActor.run {
            (AppState.shared.llmPostProcessor, AppState.shared.llmPostProcessor?.isModelLoaded ?? false)
        }
        guard let llm, loaded else { return nil }
        return llm
        #endif
    }

    private func releaseLLM() {
        #if canImport(FluidAudio)
        // MeetingEngines is @MainActor — hop via Task since defer blocks cannot await.
        // Both borrowLLM() and releaseLLM() pass through the MainActor queue, so
        // ordering is preserved even if a subsequent borrow is enqueued immediately.
        Task { @MainActor in MeetingEngines.shared.releaseLLM() }
        #endif
    }

    // MARK: - Q&A

    /// Ask a question about a meeting. Passes the whole timestamped transcript in the
    /// system prompt and sets `reuseWarmCache: true` so repeated questions about the
    /// same meeting hit the cached KV prefix instead of recomputing it.
    func ask(question: String, meetingID: UUID, segments: [MeetingSegment]) async -> RAGAnswer {
        guard !question.isEmpty else {
            return RAGAnswer(text: "Please enter a question.", sources: [], usedRAG: false)
        }

        guard let llm = await acquireLLM() else {
            Logger.warning("Meeting AI: skipped — meeting intelligence engine not ready", subsystem: .transcription)
            return RAGAnswer(
                text: "Meeting intelligence engine is not ready. Download it from Settings → Meeting Engines.",
                sources: [], usedRAG: false
            )
        }
        defer { releaseLLM() }

        // For very long transcripts, prefilter segments to the most relevant ones so the
        // system prompt stays within ~3,000 tokens. Log when this path is taken.
        let useSegments: [MeetingSegment]
        let usedBM25: Bool
        let fullTranscript = Self.timestampedTranscript(segments)
        if fullTranscript.count > Self.maxTranscriptChars {
            Logger.info("Meeting Q&A: transcript \(fullTranscript.count) chars — applying BM25 prefilter", subsystem: .transcription)
            useSegments = Self.bm25PrefilterSegments(segments, question: question)
            usedBM25 = true
        } else {
            useSegments = segments
            usedBM25 = false
        }

        let transcript = Self.timestampedTranscript(useSegments)
        let systemPrompt = Self.askSystemPrompt(transcript: transcript)

        do {
            let response = try await llm.process(
                text:           question,
                systemPrompt:   systemPrompt,
                userMessage:    question,
                temperature:    0.3,
                maxTokensCap:   512,
                // Cache only when the system prompt is stable (same full transcript every call).
                // BM25 prefilter builds a question-specific subset, so the prompt changes on
                // every question — reuseWarmCache would silently evict + rebuild the KV prefix
                // each time rather than reusing it, wasting the flag's purpose.
                reuseWarmCache: !usedBM25
            )
            let answer = response.trimmingCharacters(in: .whitespacesAndNewlines)
            let sources = parseCitations(from: answer, segments: segments)
            return RAGAnswer(text: answer, sources: sources, usedRAG: false)
        } catch {
            Logger.error("Meeting Q&A failed: \(error)", subsystem: .transcription)
            return RAGAnswer(text: "Sorry, I couldn't answer that. Please try again.", sources: [], usedRAG: false)
        }
    }

    // MARK: - Title generation

    /// Names an untitled recording from its content. Run before `generateOverview`
    /// so the library row gets a real name within a couple of seconds instead of
    /// waiting out the full summary pass. No-op once the user has titled it.
    func generateTitle(segments: [MeetingSegment], meetingID: UUID, currentTitle: String) async {
        guard Self.isAutoGeneratedTitle(currentTitle) else {
            Logger.info("Meeting title: skipped — \"\(currentTitle)\" was set by the user", subsystem: .transcription)
            return
        }
        let transcript = Self.plainTranscript(segments)
        guard transcript.count >= 40 else { return }

        guard let llm = await acquireLLM() else {
            Logger.warning("Meeting AI: skipped — meeting intelligence engine not ready", subsystem: .transcription)
            return
        }
        defer { releaseLLM() }

        let systemPrompt = """
        You name voice recordings. Read the transcript and reply with a title for it.

        RULES:
        1. Reply with the title and nothing else. No quotes, no label, no explanation, no trailing period.
        2. Between 3 and 7 words, on one line.
        3. Name the actual subject matter. "Google AI course breakdown" is a good title. "Recording", "Meeting notes" and "Transcript" say nothing — never use them.
        4. Do not begin with "Summary of", "Notes on", "Discussion about" or "A recording of".
        5. Write the title in the language of the transcript.
        6. Never use the characters < or >.
        """

        // Head plus tail: the opening states the subject and the closing usually
        // states the conclusion. The middle rarely changes what to call it.
        let excerpt = Self.headAndTail(transcript, headChars: 1600, tailChars: 500)

        do {
            let raw = try await llm.process(
                text:                   excerpt,
                systemPrompt:           systemPrompt,
                userMessage:            excerpt,
                temperature:            0.2,
                repetitionPenalty:      1.1,
                maxTokensCap:           48,
                outputTokensHint:       32,
                timeoutSecondsOverride: 25,
                throwOnFallback:        true,
                // One-shot prompt, and the overview pass that follows uses a different one.
                reuseWarmCache:         false
            )
            guard let title = Self.sanitizeTitle(raw) else {
                Logger.warning("Meeting title: unusable LLM output \"\(raw.prefix(80))\"", subsystem: .transcription)
                return
            }
            await MeetingManager.shared.updateTitle(meetingID: meetingID, title: title)
            // The detail header caches the title in @State, so it needs telling.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .meetingTitleDidGenerate, object: meetingID, userInfo: ["title": title]
                )
            }
            Logger.info("Meeting title: named \(meetingID) \"\(title)\"", subsystem: .transcription)
        } catch {
            Logger.error("Meeting title: generation failed: \(error.localizedDescription)", subsystem: .transcription)
        }
    }

    // MARK: - Overview generation

    func generateOverview(segments: [MeetingSegment], meetingID: UUID) async {
        let transcript = Self.timestampedTranscript(segments)
        Logger.info("Meeting overview: starting for \(meetingID), transcript=\(transcript.count) chars", subsystem: .transcription)
        guard !transcript.isEmpty else {
            Logger.warning("Meeting overview: skipped — transcript is empty", subsystem: .transcription)
            await MainActor.run { NotificationCenter.default.post(name: .meetingOverviewDidFail, object: meetingID) }
            return
        }

        guard let llm = await acquireLLM() else {
            Logger.warning("Meeting AI: skipped — meeting intelligence engine not ready", subsystem: .transcription)
            await MainActor.run { NotificationCenter.default.post(name: .meetingOverviewDidFail, object: meetingID) }
            return
        }
        defer { releaseLLM() }

        Logger.info("Meeting overview: LLM ready, starting generation", subsystem: .transcription)

        // A voice memo of a few sentences has nothing to structure — asking for the
        // full label set only makes the model invent decisions and owners.
        let wordCount = Self.plainTranscript(segments).split(whereSeparator: { $0 == " " || $0.isNewline }).count
        let isNote = wordCount < 60

        let systemPrompt = isNote ? Self.notePrompt : Self.overviewPrompt
        let userMessage = "TRANSCRIPT:\n\(transcript)"

        let raw: String
        do {
            raw = try await llm.process(
                text:                   transcript,
                systemPrompt:           systemPrompt,
                userMessage:            userMessage,
                temperature:            0.15,
                repetitionPenalty:      1.15,
                maxTokensCap:           2048,
                outputTokensHint:       isNote ? 200 : 1200,
                timeoutSecondsOverride: isNote ? 30 : 120,
                throwOnFallback:        true,
                // Runs once per meeting; warming this prefix only evicts the dictation cache.
                reuseWarmCache:         false
            )
        } catch {
            Logger.error("Meeting overview: LLM generation failed: \(error.localizedDescription)", subsystem: .transcription)
            await MainActor.run { NotificationCenter.default.post(name: .meetingOverviewDidFail, object: meetingID) }
            return
        }

        Logger.info("Meeting overview: LLM produced \(raw.count) chars", subsystem: .transcription)

        guard var summary = MeetingOverviewParser.parse(raw) else {
            Logger.warning("Meeting overview: parse failed (no OVERVIEW line). Raw: \(raw.prefix(300))", subsystem: .transcription)
            await MainActor.run { NotificationCenter.default.post(name: .meetingOverviewDidFail, object: meetingID) }
            return
        }

        Logger.info("Meeting overview: parsed successfully — overview=\(summary.overview.prefix(80))…", subsystem: .transcription)
        summary.generatedAt = Date()
        await MeetingManager.shared.updateAISummary(meetingID: meetingID, summary: summary)
        Logger.info("Meeting overview: saved to CoreData for \(meetingID)", subsystem: .transcription)
        // Must post on main thread — onReceive handlers mutate @State
        await MainActor.run {
            NotificationCenter.default.post(name: .meetingOverviewDidGenerate, object: meetingID)
        }
    }

    // MARK: - Prompts

    /// Full-length summary. The bulk of the prompt is about OVERVIEW because that
    /// is what the user reads — the earlier "2-4 sentences" instruction produced
    /// summaries that said a topic was discussed without saying what was said.
    private static let overviewPrompt = """
    You summarize voice recordings. The input is a speech-to-text transcript, so it contains filler words, false starts and misheard words. Summarize what was meant, not the exact wording.

    Every transcript line begins with a marker like [95s] giving the number of seconds from the start. Copy those numbers into the seconds fields below. Never put a marker inside the OVERVIEW.

    OUTPUT FORMAT — each label on its own line, in this order. Emit a label only when the recording actually contains that thing.

    OVERVIEW: the summary
    TOPIC: short phrase | seconds
    DECISION: short label | what was decided | seconds
    OPEN: a question that was raised and never answered | seconds
    NEXT: when and where the next session is
    ACTION: the task | the person's name | the due date

    HOW TO WRITE THE OVERVIEW — this is the part that matters:
    - 250 to 350 words, as 2 to 4 paragraphs separated by a blank line. Write the label OVERVIEW: once, at the start; every paragraph after it belongs to it.
    - Do not stop after three sentences. A reader who never heard the recording must finish the OVERVIEW knowing the actual content.
    - Follow the order of the recording.
    - Keep the specifics: names, numbers, tools, definitions, comparisons and examples that were given.
    - State the point that was made, not that a point was made. Write "machine learning is a subfield of AI in the way thermodynamics is a subfield of physics" — not "the speaker explained how machine learning relates to AI".
    - Do not open with "In this recording", "The speaker discusses" or "This transcript". Start with the substance.
    - Plain sentences only inside the OVERVIEW. No bullets, no markdown, no headings.

    THE OTHER LABELS:
    - TOPIC: 3 to 6 lines, one per section of the recording, in the order they occur.
    - DECISION, OPEN, NEXT and ACTION apply to real discussions. A lecture, a video or a solo note usually has none of them, and leaving them out is the correct answer. Never invent a decision, an owner or a due date to fill the format.
    - ACTION requires a real person named in the transcript. If nobody was named, write no ACTION line.

    ALWAYS:
    - Write every line in the language of the transcript.
    - Never state anything the transcript does not say.
    - Never use the characters < or >.
    """

    /// Very short recordings — one line out, nothing to structure.
    private static let notePrompt = """
    You summarize short voice notes. Reply with exactly one line:

    OVERVIEW: two or three sentences saying what the note is about

    RULES:
    1. Keep every specific detail from the note — names, numbers, places, tasks.
    2. Write no other label. No TOPIC, no DECISION, no ACTION.
    3. No markdown, no bullets, no quotes.
    4. Never state anything the note does not say.
    5. Write in the language of the note.
    6. Never use the characters < or >.
    """

    // MARK: - Ask system prompt

    /// System prompt for Q&A. Stable per meeting — the transcript is embedded verbatim,
    /// so every question about the same meeting hits the same KV-cache prefix.
    private static func askSystemPrompt(transcript: String) -> String {
        """
        You are an AI assistant analyzing a meeting transcript. Answer questions about this meeting concisely, citing specific moments using [Xs] timestamps from the transcript when relevant.

        Transcript:
        \(transcript)
        """
    }

    // MARK: - Citation parsing

    /// Scan the LLM response for [Ns] timestamp patterns and resolve each to the
    /// closest segment in the transcript (within ±30s). Returns deduplicated citations.
    private func parseCitations(from text: String, segments: [MeetingSegment]) -> [RAGChunk] {
        guard !segments.isEmpty, !text.isEmpty else { return [] }
        var results: [RAGChunk] = []
        var seen = Set<Int>()   // segment indices already included

        let nsText = text as NSString
        let matches = MeetingAIService.citationRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard let range = Range(match.range(at: 1), in: text),
                  let seconds = Double(text[range]) else { continue }

            // Find the segment whose timestamp is closest to this cited moment.
            let best = segments.enumerated().min {
                abs($0.element.timestamp - seconds) < abs($1.element.timestamp - seconds)
            }
            guard let (idx, seg) = best,
                  !seen.contains(idx),
                  abs(seg.timestamp - seconds) <= 30 else { continue }
            seen.insert(idx)
            results.append(RAGChunk(
                text:           seg.text,
                startTimestamp: seg.timestamp,
                endTimestamp:   seg.endTimestamp,
                speakers:       [seg.speakerName],
                score:          0
            ))
        }
        return results
    }

    // MARK: - Long-meeting prefilter

    /// Threshold above which a BM25-style prefilter is applied before building the
    /// system prompt, to keep the context within ~3,000 tokens.
    private static let maxTranscriptChars = 12_000

    /// Simple term-frequency prefilter for transcripts exceeding `maxTranscriptChars`.
    /// Groups segments into buckets, scores each by question-word overlap, and returns
    /// the top-5 buckets in original timestamp order. No external dependency.
    private static func bm25PrefilterSegments(
        _ segments: [MeetingSegment], question: String
    ) -> [MeetingSegment] {
        let questionWords = Set(
            question.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 }
        )
        guard !questionWords.isEmpty else { return segments }

        let chunkSize = 5
        var groups: [(range: Range<Int>, score: Int)] = []
        var i = 0
        while i < segments.count {
            let end = min(i + chunkSize, segments.count)
            let text = segments[i..<end].map { $0.text }.joined(separator: " ").lowercased()
            let score = questionWords.reduce(0) { acc, word in acc + (text.contains(word) ? 1 : 0) }
            groups.append((i..<end, score))
            i = end
        }

        // Take top-5 groups by score, then restore original order.
        let topRanges = groups.sorted { $0.score > $1.score }.prefix(5).map { $0.range }
        return topRanges
            .flatMap { range in Array(segments[range]) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Auto-generated titles

    /// Titles produced by the app itself, which the LLM may replace. Anything the
    /// user typed is left alone. Kept in sync with `defaultNoteTitle()` in the
    /// meeting UI and the provider display names in `MeetingDetector`.
    private static let autoTitleAppNames: Set<String> = [
        "zoom", "microsoft teams", "webex", "facetime", "google meet",
        "google hangouts", "whereby", "around", "slack huddle", "slack"
    ]

    nonisolated static func isAutoGeneratedTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("Note ") || trimmed.hasPrefix("Meeting ") { return true }
        return autoTitleAppNames.contains(trimmed.lowercased())
    }

    // MARK: - Private helpers

    /// Transcript with a seconds marker per line. Without it the model has no
    /// timestamps to cite and fabricates the seconds fields in TOPIC/DECISION/OPEN.
    private static func timestampedTranscript(_ segments: [MeetingSegment]) -> String {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[\(Int($0.timestamp))s] \($0.speakerName): \($0.text)" }
            .joined(separator: "\n")
    }

    private static func plainTranscript(_ segments: [MeetingSegment]) -> String {
        segments.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headAndTail(_ text: String, headChars: Int, tailChars: Int) -> String {
        guard text.count > headChars + tailChars else { return text }
        return String(text.prefix(headChars)) + "\n…\n" + String(text.suffix(tailChars))
    }

    /// First usable line of the model's reply, stripped of the decorations small
    /// on-device models add (labels, quotes, trailing punctuation).
    private static func sanitizeTitle(_ raw: String) -> String? {
        guard var line = raw
            .components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        for label in ["TITLE:", "Title:", "OVERVIEW:"] where line.hasPrefix(label) {
            line = String(line.dropFirst(label.count))
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'\u{201C}\u{201D}«»<>*#.-–—"))
        line = line.replacingOccurrences(of: "<", with: "")
                   .replacingOccurrences(of: ">", with: "")
                   .trimmingCharacters(in: .whitespaces)

        guard line.count >= 3 else { return nil }
        guard !isAutoGeneratedTitle(line) else { return nil }
        return line.count > 70 ? String(line.prefix(70)).trimmingCharacters(in: .whitespaces) : line
    }
}

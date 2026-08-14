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
                // `process()` sizes its default timeout from `text` — the question — which is
                // a couple of hundred characters and buys 10s. The work is prefilling the whole
                // transcript underneath it: measured at 16s on a 4600-token meeting, so the
                // first question on a long meeting failed with "Sorry, I couldn't answer that"
                // before a token was generated. Scale with the prompt that is actually decoded.
                timeoutSecondsOverride: Self.askTimeout(promptChars: systemPrompt.count),
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
        let plain = Self.plainTranscript(segments)
        guard !plain.isEmpty else {
            Logger.warning("Meeting overview: skipped — transcript is empty", subsystem: .transcription)
            await MainActor.run { NotificationCenter.default.post(name: .meetingOverviewDidFail, object: meetingID) }
            return
        }

        // A voice memo of a few sentences has nothing to structure — asking for the
        // full label set only makes the model invent decisions and owners.
        let wordCount = plain.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        let request = Self.overviewRequest(transcriptWords: wordCount)
        let isNote = request.isNote

        // An overview summarizes what the recording was about, not who said it, so the
        // model is given the finished transcription rather than attributed lines. The
        // note prompt emits no seconds fields either, so it gets the flat text; the full
        // prompt keeps the [Ns] markers it cites from.
        let transcript = isNote ? plain : Self.narrativeTranscript(segments)
        Logger.info("Meeting overview: starting for \(meetingID), transcript=\(transcript.count) chars", subsystem: .transcription)

        guard let llm = await acquireLLM() else {
            Logger.warning("Meeting AI: skipped — meeting intelligence engine not ready", subsystem: .transcription)
            await MainActor.run { NotificationCenter.default.post(name: .meetingOverviewDidFail, object: meetingID) }
            return
        }
        defer { releaseLLM() }

        Logger.info("Meeting overview: LLM ready, starting generation", subsystem: .transcription)

        let userMessage = "TRANSCRIPT:\n\(transcript)"

        let raw: String
        do {
            raw = try await llm.process(
                text:                   transcript,
                systemPrompt:           request.systemPrompt,
                userMessage:            userMessage,
                temperature:            0.15,
                repetitionPenalty:      1.15,
                maxTokensCap:           2048,
                outputTokensHint:       request.outputTokensHint,
                timeoutSecondsOverride: request.timeoutSeconds,
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

    /// What to ask for, and how long to wait, given the size of the recording.
    ///
    /// A fixed "250 to 350 words" demand is itself a degeneration trigger on a short
    /// recording: asked for roughly twice as many words as it was handed, a greedy 4B
    /// decoder runs out of material and starts cycling — the shipped failure was a
    /// 150-word transcript answered with "to Michael to Michael to to to…" for 48
    /// tokens. The requested length therefore tracks the transcript, and the token hint
    /// tracks the request; 1200 output tokens for 150 words of source is a licence to
    /// ramble. Non-private so `LLMModelComparisonTests` benchmarks the identical shapes.
    ///
    /// The bands are measured, not chosen. 106 reference overviews written by a frontier
    /// model over this app's own meeting library came out at a median of 70 words for a
    /// note, 146 brief, 183 standard and 318 full — against a shipped median of **18**
    /// at 12% of the token budget, terminating on a clean EOS rather than a cap. The
    /// model was not running out of room; it believed it was finished, which makes the
    /// gap a prompt defect. `outputTokensHint` is sized for the top of each band in
    /// Hebrew and Russian, which run 2-3 tokens per word — an English-calibrated budget
    /// becomes the new ceiling the moment the prompt starts working.
    struct OverviewRequest {
        let systemPrompt: String
        let outputTokensHint: Int
        let timeoutSeconds: Double
        /// A note gets the flat transcript (no `[Ns]` markers) and the one-line prompt,
        /// because `notePrompt` emits no seconds fields to cite into.
        let isNote: Bool
    }

    static func overviewRequest(transcriptWords: Int) -> OverviewRequest {
        switch transcriptWords {
        case ..<60:
            return OverviewRequest(
                systemPrompt: notePrompt, outputTokensHint: 300, timeoutSeconds: 40, isNote: true)
        case ..<250:
            return OverviewRequest(
                systemPrompt: overviewPrompt(
                    lengthLine: "90 to 180 words, one paragraph",
                    lengthRule: "Write 90 to 180 words, as a single paragraph. Write the label OVERVIEW: once, at the start.",
                    topicCount: "2 to 4"),
                outputTokensHint: 700, timeoutSeconds: 90, isNote: false)
        case ..<700:
            return OverviewRequest(
                systemPrompt: overviewPrompt(
                    lengthLine: "140 to 240 words, one or two paragraphs",
                    lengthRule: "Write 140 to 240 words, as one or two paragraphs separated by a blank line. Write the label OVERVIEW: once, at the start; every paragraph after it belongs to it.",
                    topicCount: "3 to 5"),
                outputTokensHint: 1100, timeoutSeconds: 140, isNote: false)
        default:
            return OverviewRequest(
                systemPrompt: overviewPrompt(
                    lengthLine: "250 to 400 words, two to four paragraphs",
                    lengthRule: "Write 250 to 400 words, as 2 to 4 paragraphs separated by a blank line. Write the label OVERVIEW: once, at the start; every paragraph after it belongs to it. A reader who never heard the recording must finish the OVERVIEW knowing what was actually said.",
                    topicCount: "3 to 6"),
                outputTokensHint: 1600, timeoutSeconds: 180, isNote: false)
        }
    }

    /// Full-length summary. The bulk of the prompt is about OVERVIEW because that
    /// is what the user reads — the earlier "2-4 sentences" instruction produced
    /// summaries that said a topic was discussed without saying what was said.
    /// Only the length and TOPIC-count rules vary by transcript size; everything
    /// else is fixed, so the tiers cannot drift apart.
    ///
    /// Three things in here exist to stop the model answering in one sentence, which
    /// was the shipped behaviour at every tier:
    ///
    /// - **TOPIC is emitted before OVERVIEW.** `MeetingOverviewParser.parse` dispatches
    ///   each label independently, so the order costs nothing, and naming the sections
    ///   first turns "write more" — which a 4B ignores — into "cover these", which it
    ///   can execute. Five named sections cannot be covered in eighteen words.
    /// - **The length and the TOPIC count sit directly under the FORMAT block**, not in a
    ///   later bullet. Template shape beats a word count stated further down: while the
    ///   counts lived in `THE OTHER LABELS:` the model wrote one TOPIC line or none, and
    ///   over 34 meetings overview length tracks the number of TOPIC lines it actually
    ///   emits (2 topics → 46-176 words; 0 or 1 → 2-69). They are **under** the template
    ///   rather than inside it because anything appended to a template line gets copied
    ///   out as the value: `OVERVIEW: the summary — 140 to 240 words` produced literally
    ///   `OVERVIEW: 140m`, and the annotated TOPIC line produced `TOPIC: 0s | TOP: 37s`.
    /// - **Nothing tells it to stop any more.** "Say what it contained and stop", "do not
    ///   pad" and "padding it out is worse than a short answer" were anti-degeneration
    ///   hedges from before the repetition penalty reached the MTP decoder. Against
    ///   "write 140 to 240 words" a greedy decoder resolves the conflict toward the
    ///   instruction it can carry out immediately, and stopping is that instruction.
    ///
    /// `ALWAYS` names the six labels and pins them to English. "Write every line in the
    /// language of the transcript" is true of the text and false of the labels, and on a
    /// Hebrew transcript the model resolved that by emitting `OVERVIEWING:` — which
    /// `MeetingOverviewParser` drops, and cannot recover from, because `sawLabel` is
    /// already true by then and the `strayLines` fallback never fires.
    ///
    /// The worked example is contrastive rather than long: a full-length one would bias
    /// every tier toward its own length and triple the prefill. It is also entirely
    /// invented — a real recording must never be embedded in a shipped prompt.
    static func overviewPrompt(lengthLine: String, lengthRule: String, topicCount: String) -> String {
        """
    You summarize voice recordings. The input is a speech-to-text transcript, so it contains filler words, false starts and misheard words. Summarize what was meant, not the exact wording.

    Every transcript line begins with a marker like [95s] giving the number of seconds from the start. Copy those numbers into the seconds fields below. Never put a marker inside the OVERVIEW.

    OUTPUT FORMAT — each label on its own line, in this order. Emit a label only when the recording actually contains that thing. Write each label bare, exactly as shown: OVERVIEW: — never **OVERVIEW:**, never ## OVERVIEW.

    TOPIC: short phrase | seconds
    OVERVIEW: the summary
    DECISION: short label | what was decided | seconds
    OPEN: a question that was raised and never answered | seconds
    NEXT: when and where the next session is
    ACTION: the task | the person's name | the due date

    Those six lines are a template. Copy each label and each | exactly, and replace the description after it with real content — never with the description itself.

    Write \(topicCount) TOPIC lines first, one per section of the recording, in the order they occur. They are your plan: the OVERVIEW must then cover every one of them, in the same order, in \(lengthLine). The OVERVIEW is by far the longest thing you write; every other line is one line.

    HOW TO WRITE THE OVERVIEW — this is the part that matters:
    - \(lengthRule)
    - Cover every TOPIC line you wrote. A section you named and then did not describe is the main way this goes wrong.
    - Keep the specifics: names, numbers, tools, definitions, comparisons and examples that were given.
    - State the point that was made, not that a point was made. Write "machine learning is a subfield of AI in the way thermodynamics is a subfield of physics" — not "the speaker explained how machine learning relates to AI".
    - Do not open with "In this recording", "The speaker discusses" or "This transcript". Start with the substance.
    - Plain sentences only inside the OVERVIEW. No bullets, no markdown, no headings.

    THE LEVEL OF DETAIL EXPECTED. Suppose two people compared two databases and picked one.

    Too thin — never answer like this:
    OVERVIEW: The team discussed which database to use and made a decision.

    Correct:
    OVERVIEW: Postgres and DynamoDB were compared for the events table. Postgres won on the ad-hoc queries the analytics team runs weekly, which DynamoDB would have needed a second index and a nightly export to serve. Cost was close enough at the current 40 GB that it decided nothing, and they agreed to look again if the table passes 500 GB. Sara is writing the migration.

    The second one says what was compared, why one won, what the numbers were, and what was left open. Write at that density about every part of the recording.

    THE OTHER LABELS:
    - DECISION, OPEN, NEXT and ACTION apply to real discussions. A lecture, a video or a solo note usually has none of them, and leaving them out is the correct answer. Never invent a decision, an owner or a due date to fill the format.
    - ACTION requires a real person named in the transcript. If nobody was named, write no ACTION line.

    ALWAYS:
    - Write the text in the language of the transcript. The labels themselves are not text: TOPIC, OVERVIEW, DECISION, OPEN, NEXT and ACTION stay in English, spelled exactly as listed above, whatever language the transcript is in.
    - Never state anything the transcript does not say.
    - Never use the characters < or >.
    """
    }

    /// Very short recordings — one line out, nothing to structure. The word count is
    /// stated because "two or three sentences" was answered with one clause; reference
    /// overviews for notes this size run about 70 words.
    static let notePrompt = """
    You summarize short voice notes. Reply with exactly one line, and begin it with the word OVERVIEW followed by a colon:

    OVERVIEW: 40 to 90 words — three or four sentences saying what the note is about

    RULES:
    1. Begin the line with OVERVIEW: — bare, no asterisks and no heading marks. The reply is discarded without it.
    2. Keep every specific detail from the note — names, numbers, places, tasks. A detail you leave out is lost; the note is all the reader gets.
    3. Say what was said, not that something was said. Never write "the note is about" or "the speaker mentions" — start with the content itself.
    4. Write no other label. No TOPIC, no DECISION, no ACTION.
    5. No markdown, no bullets, no quotes.
    6. Never state anything the note does not say.
    7. Write in the language of the note.
    8. Never use the characters < or >.
    """

    /// Prefill dominates a Q&A turn — the answer is a few dozen tokens, the transcript
    /// underneath it is thousands. Roughly 4 chars per token at ~250 tok/s of prefill, doubled
    /// for headroom on a larger model, floored at 20s and capped at 90s so a stuck generation
    /// still surfaces rather than hanging the pane.
    static func askTimeout(promptChars: Int) -> Double {
        min(90, max(20, Double(promptChars) / 500))
    }

    // MARK: - Ask system prompt

    /// System prompt for Q&A. Stable per meeting — the transcript is embedded verbatim,
    /// so every question about the same meeting hits the same KV-cache prefix.
    static func askSystemPrompt(transcript: String) -> String {
        """
        You are an AI assistant analyzing a meeting transcript. Answer questions about this meeting concisely, citing specific moments using [Xs] timestamps from the transcript when relevant.

        Transcript:
        \(transcript)
        """
    }

    // MARK: - Citation parsing

    /// Scan the LLM response for [Ns] timestamp patterns and resolve each to the
    /// closest segment in the transcript (within ±30s). Returns deduplicated citations.
    func parseCitations(from text: String, segments: [MeetingSegment]) -> [RAGChunk] {
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
    ///
    /// Speaker-attributed — for Ask AI, where "who said X" is a fair question. The
    /// overview uses `narrativeTranscript` instead.
    static func timestampedTranscript(_ segments: [MeetingSegment]) -> String {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[\(Int($0.timestamp))s] \($0.speakerName): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Same seconds markers, no speaker names — an overview is about what was said,
    /// not who said it, and diarization labels only give the model a false axis to
    /// organize the summary around. It also removes an identical `Speaker N:` prefix
    /// from every single line, which is the most repetitive thing in the prompt and
    /// the pattern a greedy decode is most likely to latch onto and loop.
    static func narrativeTranscript(_ segments: [MeetingSegment]) -> String {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[\(Int($0.timestamp))s] \($0.text)" }
            .joined(separator: "\n")
    }

    static func plainTranscript(_ segments: [MeetingSegment]) -> String {
        segments.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func headAndTail(_ text: String, headChars: Int, tailChars: Int) -> String {
        guard text.count > headChars + tailChars else { return text }
        return String(text.prefix(headChars)) + "\n…\n" + String(text.suffix(tailChars))
    }

    /// First usable line of the model's reply, stripped of the decorations small
    /// on-device models add (labels, quotes, trailing punctuation).
    static func sanitizeTitle(_ raw: String) -> String? {
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

//
//  AppleIntelligenceProvider.swift
//  Whisperer
//
//  Meeting notes, Ask AI and transcript polish on the language model macOS ships
//  (Foundation Models). Nothing is downloaded, bundled or sent anywhere: the model is the
//  OS's, it runs on this Mac, and macOS updates improve it.
//
//  Its context window is small — `SystemLanguageModel.contextSize`, 8192 tokens on the M2 Pro
//  this was written on (4096 on earlier releases) — so a meeting never goes in whole:
//    - notes: the transcript is cut into windows, each window is digested into structured
//      facts, and the digests are reduced into one title and overview (hierarchically, when
//      the digests themselves outgrow a window);
//    - Ask AI: the caller has already narrowed the transcript to `maxTranscriptChars`;
//    - polish: plain `id | text` lines in small chunks (`polishesInLines`).
//
//  Languages: `supportsLocale` is false for Hebrew and Russian, but the model answers them.
//  The provider does not refuse on `supportsLocale`; it tries, and a refusal from the model
//  (`unsupportedLanguageOrLocale`) becomes `.unsupportedLanguage`, which the router answers by
//  falling back to the MLX model. See docs/knowledge/llm/knowledge.md.
//

import Foundation
import FoundationModels

// MARK: - Structured output

/// The lists a notes digest carries. `@Generable` makes the model fill typed fields, so a small
/// model cannot break JSON syntax.
@Generable
nonisolated struct AIStampedNote {
    @Guide(description: "One short sentence.")
    var text: String
    @Guide(description: "The number from the [Ns] marker of the line it came from; 0 if unknown.")
    var seconds: Int
}

@Generable
nonisolated struct AIDecisionNote {
    @Guide(description: "One to three words naming the decision.")
    var label: String
    var text: String
    @Guide(description: "The number from the [Ns] marker of the line it came from; 0 if unknown.")
    var seconds: Int
}

@Generable
nonisolated struct AIActionNote {
    var task: String
    @Guide(description: "The person's name as said in the transcript. Nil if nobody was named.")
    var owner: String?
    @Guide(description: "The deadline as said in the transcript. Nil if none was said.")
    var due: String?
}

/// What one window of transcript yields. `summary` is the window's overview.
@Generable
nonisolated struct AINotesDigest {
    @Guide(description: "3 to 7 words naming the actual subject. Never 'Meeting' or 'Notes'.")
    var title: String
    var summary: String
    var topics: [AIStampedNote]
    @Guide(description: "Only decisions that were actually made. Empty when there were none.")
    var decisions: [AIDecisionNote]
    @Guide(description: "Questions raised and left unanswered. Empty when there were none.")
    var openQuestions: [AIStampedNote]
    @Guide(description: "When and where the next session is. Nil if not said.")
    var nextMeeting: String?
    @Guide(description: "Tasks someone took on. Empty when there were none. Never invent one.")
    var actionItems: [AIActionNote]
}

/// The title and overview written from the digests of every window.
@Generable
nonisolated struct AINotesHead {
    @Guide(description: "3 to 7 words naming the actual subject. Never 'Meeting' or 'Notes'.")
    var title: String
    var overview: String
}

// MARK: - Provider

nonisolated struct AppleIntelligenceProvider: MeetingIntelligenceProvider {
    let id: AIProviderID = .appleIntelligence
    var modelLabel: String? { "Apple Intelligence" }

    /// The model to ask. A seam for tests that have none.
    var model: SystemLanguageModel = .default

    /// Characters per token the budgets assume. Hebrew and Russian run near 2 (English ~4), and a
    /// budget sized for English overflows the window on the very languages this app is for.
    static let charsPerToken = 2

    /// Tokens of the window that instructions, the schema and the reply take, not the transcript.
    static let reservedTokens = 2_400

    /// Characters of transcript one request carries.
    static func windowChars(contextSize: Int) -> Int {
        max(2_000, (contextSize - reservedTokens) * charsPerToken)
    }

    /// Forces small windows so a test can exercise the multi-window path on a short transcript.
    var windowCharsOverride: Int?

    var windowChars: Int { windowCharsOverride ?? Self.windowChars(contextSize: model.contextSize) }

    /// Forces the fold step on a short transcript. Reduce is sized from the real context, never
    /// from `windowCharsOverride`: summaries can't be folded below the size of one summary.
    var reduceCharsOverride: Int?

    var reduceChars: Int { reduceCharsOverride ?? Self.windowChars(contextSize: model.contextSize) }

    /// Ask AI also carries the header, the user's notes, the question and the chat history.
    var maxTranscriptChars: Int { windowChars * 3 / 4 }

    /// Notes cover the whole meeting by digesting it window by window.
    var maxNotesChars: Int { 400_000 }

    var polishesInLines: Bool { true }

    // MARK: Readiness

    func readiness() async -> ProviderReadiness {
        Self.readiness(for: model.availability)
    }

    static func readiness(for availability: SystemLanguageModel.Availability) -> ProviderReadiness {
        switch availability {
        case .available:
            return .ready(detail: nil)
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn't support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Turn on Apple Intelligence in System Settings")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence is still getting ready")
        case .unavailable:
            return .unavailable("Apple Intelligence isn't available")
        }
    }

    private func requireAvailable() throws {
        guard case .available = model.availability else { throw MeetingAIProviderError.notInstalled }
    }

    // MARK: Requests

    private func session(_ instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: instructions)
    }

    /// Notes and polish are background work: a dictation goes first.
    private func yieldToDictation() async throws {
        await ForegroundGate.shared.waitWhileRaisedAsync("AppleIntelligence", priority: .background)
        try Task.checkCancellation()
    }

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        try requireAvailable()
        try await yieldToDictation()
        do {
            let options = GenerationOptions(samplingMode: .greedy)
            return try await session(instructions).respond(to: input, options: options).content
        } catch {
            throw Self.map(error)
        }
    }

    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try requireAvailable()
        let prompt = MeetingCloudPrompts.askUserMessage(question: input.question, transcript: input.transcript)
        do {
            var latest = ""
            for try await snapshot in session(Self.askInstructions).streamResponse(to: prompt) {
                latest = snapshot.content
                onPartial(latest)
            }
            return latest
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Notes

    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        try requireAvailable()
        let windows = Self.windows(of: input.transcript, maxChars: windowChars)
        guard !windows.isEmpty else { throw MeetingAIProviderError.schemaMismatch(raw: "") }
        let instructions = Self.notesInstructions(languageName: input.languageName, isShortNote: input.isShortNote)

        var digests: [AINotesDigest] = []
        for (n, window) in windows.enumerated() {
            try await yieldToDictation()
            Logger.debug("Apple Intelligence: notes window \(n + 1)/\(windows.count), \(window.count) chars", subsystem: .transcription)
            do {
                let options = GenerationOptions(temperature: 0.2)
                let reply = try await session(instructions).respond(
                    to: MeetingCloudPrompts.notesUserMessage(transcript: window),
                    generating: AINotesDigest.self, options: options)
                digests.append(reply.content)
            } catch {
                throw Self.map(error)
            }
        }

        var title = digests.first?.title
        var overview = digests.first?.summary ?? ""
        if digests.count > 1 {
            let head = try await reduce(digests.map(\.summary), languageName: input.languageName)
            title = head.title
            overview = head.overview
        }
        if let title = Self.clean(title) { onTitle(title) }

        let merged = Self.merge(digests, title: title, overview: overview)
        guard let notes = MeetingNotesSchema.decode(object: merged) else {
            throw MeetingAIProviderError.schemaMismatch(raw: String(overview.prefix(500)))
        }
        return notes
    }

    /// Writes one title and overview from the per-window summaries. When the summaries do not fit
    /// a window together they are first folded group by group into shorter ones.
    private func reduce(_ summaries: [String], languageName: String?) async throws -> AINotesHead {
        var parts = summaries
        let budget = reduceChars
        while parts.joined(separator: "\n\n").count > budget, parts.count > 1 {
            var folded: [String] = []
            var group: [String] = []
            for part in parts {
                if !group.isEmpty, (group + [part]).joined(separator: "\n\n").count > budget {
                    folded.append(try await fold(group, languageName: languageName))
                    group = []
                }
                group.append(part)
            }
            if !group.isEmpty { folded.append(group.count == 1 ? group[0] : try await fold(group, languageName: languageName)) }
            guard folded.count < parts.count else { break }   // a fold that does not shrink must not loop
            parts = folded
        }
        try await yieldToDictation()
        do {
            let numbered = parts.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
            let reply = try await session(Self.headInstructions(languageName: languageName)).respond(
                to: numbered, generating: AINotesHead.self, options: GenerationOptions(temperature: 0.2))
            return reply.content
        } catch {
            throw Self.map(error)
        }
    }

    private func fold(_ group: [String], languageName: String?) async throws -> String {
        try await yieldToDictation()
        do {
            let language = languageName.map { "Write in \($0)." } ?? "Write in the language of the text."
            let prompt = "Combine these consecutive summaries of one meeting into one summary of the same facts, in order, about half as long. Keep the names and numbers; add nothing. \(language) Reply with the summary only."
            return try await session(prompt).respond(
                to: group.joined(separator: "\n\n"), options: GenerationOptions(samplingMode: .greedy)).content
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Prompts

    static func notesInstructions(languageName: String?, isShortNote: Bool) -> String {
        let language = languageName.map { "Write every field in \($0). Quote names and terms in their original language." }
            ?? "Write every field in the language the transcript is mostly in."
        let length = isShortNote
            ? "The summary is 40 to 90 words. Topics, decisions, open questions and action items are almost always empty for a short voice note."
            : "The summary is 60 to 160 words, in plain sentences covering every topic in order, keeping names, numbers, tools and reasons."
        return """
        You write notes from a speech-to-text transcript recorded on the user's Mac. It has filler \
        words, false starts and misheard words; write what was meant. Each line starts with a marker \
        like [95s], the seconds from the start.
        \(length)
        The summary carries what the speakers actually said: who, what and when, with the names and \
        numbers they used. Add nothing that was not said, and do not mention what was not said. \
        Too vague: "They discussed the schedule." Specific: "<who> agreed to <what> by <when>." \
        Never open with "The team" or "The speaker discusses". Never invent an owner, a date, a \
        decision or a task; leave a list empty when nothing fits.
        \(language)
        """
    }

    static func headInstructions(languageName: String?) -> String {
        let language = languageName.map { "Write in \($0)." } ?? "Write in the language of the parts."
        return """
        Below are summaries of consecutive parts of one meeting. Write the meeting's title (3 to 7 \
        words naming the actual subject) and an overview of 150 to 350 words in paragraphs separated \
        by a blank line, covering every part in order and keeping the names and numbers. \
        Add nothing that is not in the parts. No markdown. \(language)
        """
    }

    static let askInstructions = """
    You answer the user's questions about one of their meetings. The meeting transcript is in the \
    <meeting> block; the question is in <question>. The transcript is speech-to-text: words can be \
    misheard and speakers are guessed, so read it for what was meant.
    - Ground every statement in the transcript or notes. Never invent a name, number, date or quote. \
    If it was not said, say so in one short sentence.
    - Cite the moment a fact comes from as [Ns], using that line's number.
    - Answer in the language the question is written in. As short as the question allows. \
    Plain text, no markdown symbols.
    """

    // MARK: Windows and merging

    /// Cuts `transcript` into windows of at most `maxChars` characters along line boundaries, so a
    /// `[95s]` marker is never separated from its text. A single longer line is cut by characters.
    static func windows(of transcript: String, maxChars: Int) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { out.append(current); current = "" }
        }
        for rawLine in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(rawLine)
            while line.count > maxChars {
                flush()
                out.append(String(line.prefix(maxChars)))
                line = line.dropFirst(maxChars)
            }
            if !current.isEmpty, current.count + 1 + line.count > maxChars { flush() }
            current += current.isEmpty ? String(line) : "\n" + line
        }
        flush()
        return out
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The digests of every window as the JSON object `MeetingNotesSchema` decodes, so the cleaning
    /// rules (unknown owners, empty items) stay in one place. Lists keep window order and drop
    /// repeats; the caps keep a three-hour meeting's notes readable.
    static func merge(_ digests: [AINotesDigest], title: String?, overview: String) -> [String: Any] {
        func unique<T>(_ items: [T], key: (T) -> String, limit: Int) -> [T] {
            var seen = Set<String>()
            var out: [T] = []
            for item in items {
                let k = key(item).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty, seen.insert(k).inserted else { continue }
                out.append(item)
                if out.count == limit { break }
            }
            return out
        }
        func stamped(_ s: AIStampedNote) -> [String: Any] { ["text": s.text, "seconds": s.seconds] }
        let topics = unique(digests.flatMap(\.topics), key: \.text, limit: 14).map(stamped)
        let questions = unique(digests.flatMap(\.openQuestions), key: \.text, limit: 10).map(stamped)
        let decisions = unique(digests.flatMap(\.decisions), key: \.text, limit: 14).map {
            ["label": $0.label, "text": $0.text, "seconds": $0.seconds] as [String: Any]
        }
        let actions = unique(digests.flatMap(\.actionItems), key: \.task, limit: 20).map {
            ["task": $0.task, "owner": $0.owner as Any? ?? NSNull(), "due": $0.due as Any? ?? NSNull()] as [String: Any]
        }
        // The last window that named a next session wins: it is the one closest to the end.
        let next = digests.reversed().compactMap { clean($0.nextMeeting) }.first
        return [
            "title": title ?? "", "overview": overview,
            "topics": topics, "decisions": decisions, "openQuestions": questions,
            "nextMeeting": next as Any? ?? NSNull(), "actionItems": actions,
        ]
    }

    // MARK: Errors

    /// The model's failures in the router's vocabulary. Anything but a cancellation makes the
    /// caller fall back to the MLX model, so each case only chooses the message.
    static func map(_ error: Error) -> Error {
        if error is CancellationError || error is MeetingAIProviderError { return error }
        if #available(macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded:           return MeetingAIProviderError.contextTooLong
            case .unsupportedLanguageOrLocale:   return MeetingAIProviderError.unsupportedLanguage
            case .guardrailViolation, .refusal:  return MeetingAIProviderError.refused
            case .rateLimited:                   return MeetingAIProviderError.rateLimited(retryAfter: nil)
            case .timeout:                       return MeetingAIProviderError.timeout
            default:                             return MeetingAIProviderError.server(status: 0, body: e.localizedDescription)
            }
        }
        return mapLegacy(error)
    }

    @available(macOS, deprecated: 27.0, message: "Superseded by LanguageModelError")
    private static func mapLegacy(_ error: Error) -> Error {
        guard let e = error as? LanguageModelSession.GenerationError else {
            return MeetingAIProviderError.server(status: 0, body: error.localizedDescription)
        }
        switch e {
        case .exceededContextWindowSize:    return MeetingAIProviderError.contextTooLong
        case .unsupportedLanguageOrLocale:  return MeetingAIProviderError.unsupportedLanguage
        case .guardrailViolation, .refusal: return MeetingAIProviderError.refused
        case .rateLimited:                  return MeetingAIProviderError.rateLimited(retryAfter: nil)
        case .assetsUnavailable:            return MeetingAIProviderError.notInstalled
        default:                            return MeetingAIProviderError.server(status: 0, body: e.localizedDescription)
        }
    }
}

//
//  DeterministicPolisher.swift
//  Whisperer
//
//  The M2 pipeline as one call: protect → alias → normalize → format, every edit judged by
//  `ConfidenceGate`, nothing generated.
//
//  This is the type the plan's "one editor, two callers" rests on. Dictation invokes it per
//  utterance at the VAD endpoint; meetings invoke it per chunk. Neither passes anything the other
//  does not, and neither reads audio — which is what makes the meetings case (Nemotron, no
//  per-token evidence at all) the same code path as the dictation case rather than a degraded
//  variant of it.
//
//  `needsGenerativePass` is the other half of the point. It is the M2e replacement for
//  `AppState.applyLLMPostProcessing`'s `text.count <= 15` short-circuit: a content predicate
//  instead of a length one, so the 4B is invoked when there is genuinely a punctuation or casing
//  judgement left to make and not merely because the utterance was long.
//

import Foundation

struct DeterministicPolisher: Sendable {

    // MARK: - Result

    struct Result: Sendable {
        /// The polished text, after `ListFormatter`.
        let text: String
        /// The graph the text was rendered from, carrying its own edit log.
        let graph: TokenGraph
        /// Edits the gate accepted, in application order.
        let appliedEdits: [TranscriptEdit]
        /// Whether punctuation and casing still look unfinished — the only remaining LLM job.
        let needsGenerativePass: Bool
    }

    // MARK: - Configuration

    let aliases: AliasEngine
    let gate: ConfidenceGate
    /// User dictionary terms, hard-protected so no later pass can undo a correction the user made.
    let dictionaryTerms: Set<String>
    /// Whether to run `ListFormatter` on the rendered text. Off for mid-stream chunks, where an
    /// enumeration may straddle the cut.
    let formatsLists: Bool

    init(aliases: AliasEngine = AliasEngine(),
         gate: ConfidenceGate = ConfidenceGate(),
         dictionaryTerms: Set<String> = [],
         formatsLists: Bool = true) {
        self.aliases = aliases
        self.gate = gate
        self.dictionaryTerms = dictionaryTerms
        self.formatsLists = formatsLists
    }

    // MARK: - Polishing

    func polish(_ graph: TokenGraph) -> Result {
        var working = graph
        var applied: [TranscriptEdit] = []

        // 1. Protection first, unconditionally. Every later stage consults the mask, so a stage
        //    that ran before it would be editing against a graph where nothing was protected yet.
        ProtectionDetector.annotate(&working, dictionaryTerms: dictionaryTerms)

        // 2. Aliases before normalization: an alias may introduce a token normalization then has
        //    an opinion about, and `chat gpt → ChatGPT` collapses two words into one.
        applied += gate.apply(aliases.proposals(for: working), to: &working)

        // 3. Normalization, gate-simulated on its own scratch so its whitespace pass sees the same
        //    deletions the gate will actually accept.
        applied += gate.apply(TranscriptNormalizer.proposals(for: working, gate: gate), to: &working)

        // 4. Structure last, on text. `ListFormatter` rewrites line by line and reorders nothing,
        //    so it has no token-level representation to preserve.
        let rendered = working.render()
        let text = formatsLists ? ListFormatter.format(rendered) : rendered

        return Result(text: text,
                      graph: working,
                      appliedEdits: applied,
                      needsGenerativePass: Self.needsGenerativePass(text))
    }

    func polish(text: String) -> Result {
        polish(TokenGraph.from(text: text))
    }

    func polish(words: [WhisperStreamWord]) -> Result {
        polish(TokenGraph.from(words: words))
    }

    // MARK: - The remaining LLM job

    /// Whether punctuation and casing still need a model.
    ///
    /// Everything else the Correct prompt does — fillers, duplicates, whitespace, aliases,
    /// enumeration — has already happened by the time this is asked, so the question is narrow:
    /// does this text read as finished prose?
    ///
    /// Deliberately conservative in the *expensive* direction. A false "yes" costs one LLM call; a
    /// false "no" ships an unpunctuated transcript, which is the visible failure. Every clause is
    /// script-neutral: Hebrew has no case, so a caseless first letter satisfies the casing rules
    /// rather than failing them, and none of the tests can be written as an ASCII class.
    static func needsGenerativePass(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: \.isLetter) else { return false }  // nothing to punctuate

        guard let last = trimmed.last, terminators.contains(last) else { return true }
        guard startsCorrectly(trimmed) else { return true }

        // A capital and a full stop are cheap to satisfy and say nothing about the interior. Long
        // dictation arrives as one breath; if there is no punctuation for twenty-odd words, the
        // sentence boundaries have not been restored yet whatever the two ends look like.
        var wordsSincePunctuation = 0
        var sentenceStart = true
        for token in trimmed.split(whereSeparator: \.isWhitespace) {
            if sentenceStart, !startsCorrectly(String(token)) { return true }
            sentenceStart = token.last.map { terminators.contains($0) } ?? false
            if token.contains(where: { punctuation.contains($0) }) {
                wordsSincePunctuation = 0
            } else {
                wordsSincePunctuation += 1
                if wordsSincePunctuation > maxUnpunctuatedRun { return true }
            }
        }
        return false
    }

    private static let terminators: Set<Character> = [".", "!", "?", "׃", "…"]
    private static let punctuation: Set<Character> = [".", "!", "?", ",", ";", ":", "…", "׃", "־"]

    /// Twenty words is roughly two spoken sentences. Below it, a missing comma is a style
    /// question the 4B is not reliably better at than leaving it alone.
    private static let maxUnpunctuatedRun = 20

    /// A sentence may open with an uppercase letter, a digit, or any letter from a script that
    /// has no case at all — Hebrew, Arabic, CJK. Only a *lowercase* opener is evidence of
    /// unfinished text.
    private static func startsCorrectly(_ text: String) -> Bool {
        guard let first = text.first(where: { $0.isLetter || $0.isNumber }) else { return true }
        return !first.isLowercase
    }
}

// MARK: - One editor, two callers

extension DeterministicPolisher {

    /// The editor as both callers configure it: the user's dictionary as the alias table, the
    /// same terms hard-protected so no later pass can undo a correction the user made.
    ///
    /// The point of the factory is that "meetings run the same editor as dictation" is a fact
    /// about one function rather than about two call sites that happen to agree today and drift
    /// apart on the next edit to either. Both `MeetingSession` and
    /// `AppState.applyLLMPostProcessing` call it.
    ///
    /// Takes the entries rather than reading `DictionaryManager.shared` so it stays off the main
    /// actor and a test can build both callers' editors from the same dictionary.
    ///
    /// - Parameter formatsLists: whether enumeration reflow runs. Off mid-stream, where a list
    ///   may straddle the cut, and off in dictation, whose call sites already ran
    ///   `applyListFormatting`; on at the meeting endpoint.
    static func forTranscript(dictionaryEntries: [DictionaryEntry],
                              formatsLists: Bool) -> DeterministicPolisher {
        DeterministicPolisher(
            aliases: AliasEngine(entries: dictionaryEntries),
            dictionaryTerms: Set(dictionaryEntries.map(\.correctForm)),
            formatsLists: formatsLists
        )
    }
}

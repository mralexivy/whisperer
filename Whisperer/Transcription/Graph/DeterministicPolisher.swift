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
    /// Cased components of those terms, compiled once rather than split on every live hypothesis.
    let casingProtectedWords: Set<String>
    /// Whether to run `ListFormatter` on the rendered text. Off for mid-stream chunks, where an
    /// enumeration may straddle the cut.
    let formatsLists: Bool
    /// Whether this text is a mid-stream fragment rather than a whole utterance.
    ///
    /// A fragment begins wherever the VAD cut, which may be the middle of a sentence the previous
    /// chunk started — so its first word gets no sentence-initial capital and it gets no paragraph
    /// breaks at all, both boundaries being artefacts of the cut rather than of the speech. This
    /// is the same rule the fragment-mode LLM instruction states in prose at
    /// `AppState.applyLLMPostProcessing`.
    let isFragment: Bool
    /// Whether `SentenceTerminator` may close the sentence at the end of the text.
    ///
    /// Separate from `isFragment` because the two questions come apart. A meeting utterance is not
    /// a fragment — it wants sentence-initial capitals and it is a whole VAD chunk — but its *end*
    /// is a chunk boundary in the middle of a card, and whether the speaker finished a sentence
    /// there is only knowable from the silence that follows, which the next chunk carries. So the
    /// per-utterance pass declines to terminate and the card pass, which has the pause map, does it.
    let terminatesUtteranceEnd: Bool
    /// Whether `ParagraphSplitter` may insert breaks.
    ///
    /// Explicit rather than read from `PolishFeatureFlags` here, so a test constructing a polisher
    /// directly gets a fixed pipeline instead of one that depends on the machine's preferences.
    /// `forTranscript` is the seam that consults the flag.
    let splitsParagraphs: Bool

    /// The model, when one is loaded. `nil` is the ordinary case on a fresh install and the
    /// permanent case for a user who never downloads the weights — see `PolishEditor`.
    ///
    /// Only `polish(_:pauses:context:)`, the async form, consults it. The synchronous `polish`
    /// remains exactly the deterministic pipeline it always was, which is what lets the live
    /// per-utterance paths keep calling it from the main actor without an encoder pass landing
    /// on the thread that draws the meeting preview.
    let editor: (any EditingModel)?

    init(aliases: AliasEngine = AliasEngine(),
         gate: ConfidenceGate = ConfidenceGate(),
         dictionaryTerms: Set<String> = [],
         formatsLists: Bool = true,
         isFragment: Bool = false,
         terminatesUtteranceEnd: Bool = true,
         splitsParagraphs: Bool = true,
         editor: (any EditingModel)? = nil) {
        self.aliases = aliases
        self.gate = gate
        self.dictionaryTerms = dictionaryTerms
        self.casingProtectedWords = MidSentenceCaseNormalizer.protectedWords(in: dictionaryTerms)
        self.formatsLists = formatsLists
        self.isFragment = isFragment
        self.terminatesUtteranceEnd = terminatesUtteranceEnd
        self.splitsParagraphs = splitsParagraphs
        self.editor = editor
    }

    // MARK: - Polishing

    /// - Parameter pauses: inter-chunk silence, keyed by the whitespace token at each chunk
    ///   boundary. Supplied by `polish(chunks:)`; empty for every caller that has only a string,
    ///   in which case `ParagraphSplitter` falls back to its text-only rule.
    func polish(_ graph: TokenGraph, pauses: ParagraphSplitter.Pauses = [:]) -> Result {
        var working = graph
        let applied = deterministicStages(&working, pauses: pauses)
        return render(working, applied: applied)
    }

    /// The deterministic pipeline, then the model's proposals judged by the same gate.
    ///
    /// Separate from the synchronous `polish` rather than replacing it, because the model stage is
    /// an `await` and the two live paths that call the sync form — the meeting preview setter and
    /// the per-utterance pass — cannot suspend and must not pay an encoder pass at their cadence.
    /// So the split is not merely about async: it is the live/authoritative seam that
    /// `EditContext.Pass` already names. Only the authoritative callers get the model.
    ///
    /// The model runs **after** every deterministic stage and before rendering. Order matters in
    /// one direction only: the tagger conditions on the text it is shown, so showing it text the
    /// aliases and the normalizer have not touched yet would have it re-propose corrections the
    /// pipeline already made, and re-propose them at a lower precision than the rule that made
    /// them. Running it last means it sees settled text and its proposals are the residue.
    ///
    /// Its edits face `ConfidenceGate` exactly like every other stage's. The model has no path to
    /// the graph that does not go through the gate; that is what `EditingModel`'s contract of
    /// "propose, never mutate" buys, and it is why a mis-calibrated model costs rejected edits
    /// rather than corrupted text.
    func polish(_ graph: TokenGraph,
                pauses: ParagraphSplitter.Pauses = [:],
                context: EditContext) async -> Result {
        var working = graph
        var applied = deterministicStages(&working, pauses: pauses)

        if let editor {
            let proposals = await editor.propose(working.tokens, context: context)
            if !proposals.isEmpty {
                let accepted = gate.apply(proposals, to: &working)
                applied += accepted
                Logger.debug("Editor model: \(accepted.count)/\(proposals.count) proposals applied",
                             subsystem: .transcription)
            }
        }

        return render(working, applied: applied)
    }

    /// Stages 1–7: everything that does not need the model and cannot suspend.
    private func deterministicStages(_ working: inout TokenGraph,
                                     pauses: ParagraphSplitter.Pauses) -> [TranscriptEdit] {
        var applied: [TranscriptEdit] = []

        // 1. Protection first, unconditionally. Every later stage consults the mask, so a stage
        //    that ran before it would be editing against a graph where nothing was protected yet.
        ProtectionDetector.annotate(&working, dictionaryTerms: dictionaryTerms)

        // 2. Aliases before normalization: an alias may introduce a token normalization then has
        //    an opinion about, and `chat gpt → ChatGPT` collapses two words into one.
        applied += gate.apply(aliases.proposals(for: working), to: &working)

        // 3. Spoken numbers before normalization, because a conversion deletes words and the
        //    whitespace pass is what closes the gaps they leave.
        applied += gate.apply(SpokenNumberConverter.proposals(for: working), to: &working)

        // 4. Normalization, gate-simulated on its own scratch so its whitespace pass sees the same
        //    deletions the gate will actually accept.
        applied += gate.apply(TranscriptNormalizer.proposals(for: working, gate: gate), to: &working)

        // 5. Sentence boundaries, from the silence between chunks. Before the caser on purpose: a
        //    period this pass inserts creates a sentence opening, and the caser is what capitalises
        //    it. Reversed, every boundary found here would ship lowercase.
        applied += gate.apply(
            SentenceTerminator.proposals(for: working,
                                         pauses: pauses,
                                         terminatesEnd: !isFragment && terminatesUtteranceEnd),
            to: &working)

        // 6. Remove decoder-added title case before adding the capitals sentence structure does
        //    require. Running in this order means a genuine opening can never be lowered, while
        //    the next pass can still repair an ASR-lowercased opening.
        applied += gate.apply(
            MidSentenceCaseNormalizer.proposals(for: working,
                                                protectedWords: casingProtectedWords),
            to: &working)

        // 7. Sentence structure, after the text has settled: casing reads the sentence openings
        //    and paragraph breaks read the gaps between them, and both would be computed against
        //    the wrong tokens if a filler deletion were still pending.
        applied += gate.apply(
            SentenceCaser.proposals(for: working, capitalizesFirstWord: !isFragment),
            to: &working)
        if !isFragment, splitsParagraphs {
            applied += gate.apply(ParagraphSplitter.proposals(for: working, pauses: pauses),
                                  to: &working)
        }

        return applied
    }

    /// Stage 8. Structure last, on text: `ListFormatter` rewrites line by line and reorders
    /// nothing, so it has no token-level representation to preserve.
    private func render(_ working: TokenGraph, applied: [TranscriptEdit]) -> Result {
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

    func polish(text: String, context: EditContext) async -> Result {
        await polish(TokenGraph.from(text: text), context: context)
    }

    func polish(words: [WhisperStreamWord]) -> Result {
        polish(TokenGraph.from(words: words))
    }

    // MARK: - Chunked input

    /// One committed VAD chunk: its text and the audio span it was decoded from.
    ///
    /// `start` and `end` come from `TranscriptChunk`, which derives them from sample counts —
    /// `sampleIndex / sampleRate` — and not from ASR word timings. That is why this works behind
    /// Nemotron and meetings, where no per-word evidence exists at all.
    struct Chunk: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval

        init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Polish an utterance the caller still has in chunk form, using the silence between chunks
    /// as the paragraph signal.
    ///
    /// The chunks are joined with a single space — the same join `HistoryManager.appendChunk` and
    /// `StreamingTranscriber` already use, so the text is identical to what `polish(text:)` would
    /// have received. The only thing the chunk form adds is *where* the joins are and how long the
    /// speaker was silent at each, which is exactly the information a string cannot carry.
    func polish(chunks: [Chunk]) -> Result {
        guard let input = Self.join(chunks) else {
            return polish(text: Self.soleText(chunks))
        }
        return polish(input.graph, pauses: input.pauses)
    }

    /// The chunked form with the model stage, for the authoritative dictation pass.
    func polish(chunks: [Chunk], context: EditContext) async -> Result {
        guard let input = Self.join(chunks) else {
            return await polish(text: Self.soleText(chunks), context: context)
        }
        return await polish(input.graph, pauses: input.pauses, context: context)
    }

    private static func soleText(_ chunks: [Chunk]) -> String {
        chunks.lazy
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Join the chunks and locate the silence at each seam. `nil` when there is nothing to join —
    /// fewer than two non-empty chunks — in which case there are no seams and the string form is
    /// the identical input.
    private static func join(_ chunks: [Chunk]) -> (graph: TokenGraph,
                                                    pauses: ParagraphSplitter.Pauses)? {
        // Carry the whole chunk through the filter, not just its text. Matching a piece back to its
        // chunk by text looks equivalent and is not: two chunks with identical text — "yeah",
        // "okay", a repeated word — both resolve to the first, and every pause after the duplicate
        // is then measured against the wrong span.
        let kept = chunks.compactMap { chunk -> Chunk? in
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Chunk(text: text, start: chunk.start, end: chunk.end)
        }
        guard kept.count > 1 else { return nil }

        let text = kept.map(\.text).joined(separator: " ")
        let graph = TokenGraph.from(text: text)

        // The join offsets, walked in the same order the pieces were joined. Each is the single
        // space between two pieces, which is one whitespace token in the freshly built graph.
        var pauses: ParagraphSplitter.Pauses = [:]
        var cursor = text.startIndex
        for (offset, chunk) in kept.enumerated() {
            cursor = text.index(cursor, offsetBy: chunk.text.count)
            guard offset + 1 < kept.count else { break }

            let separator = cursor..<text.index(after: cursor)
            let nextStart = kept[offset + 1].start
            if let id = graph.tokenIDs(overlappingRawRange: separator).first, nextStart > chunk.end {
                pauses[id] = nextStart - chunk.end
            }
            cursor = separator.upperBound
        }

        return (graph, pauses)
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
    /// - Parameter splitsParagraphs: defaults to the user's setting, which is the whole point of
    ///   the factory — both shipping callers get the same answer to the same question. Passed
    ///   explicitly only by tests, which must not depend on the machine's preferences.
    /// - Parameter terminatesUtteranceEnd: whether the final sentence may be closed. False only for
    ///   the meetings per-utterance pass, whose text ends at a chunk cut rather than at a speaker's
    ///   full stop.
    /// - Parameter editor: the model, defaulting to whatever `PolishEditor` has loaded. Nil until
    ///   the weights are downloaded and compiled, and nil forever if the user never gets them —
    ///   in which case every caller falls back to the deterministic pipeline, which is what
    ///   shipped before the model existed. Passed explicitly only by tests and by the live paths
    ///   that deliberately decline it.
    static func forTranscript(dictionaryEntries: [DictionaryEntry],
                              formatsLists: Bool,
                              terminatesUtteranceEnd: Bool = true,
                              splitsParagraphs: Bool = PolishFeatureFlags.areParagraphsEnabled,
                              editor: (any EditingModel)? = PolishEditor.current())
        -> DeterministicPolisher {
        DeterministicPolisher(
            aliases: AliasEngine(entries: dictionaryEntries),
            dictionaryTerms: Set(dictionaryEntries.map(\.correctForm)),
            formatsLists: formatsLists,
            terminatesUtteranceEnd: terminatesUtteranceEnd,
            splitsParagraphs: splitsParagraphs,
            editor: editor
        )
    }
}

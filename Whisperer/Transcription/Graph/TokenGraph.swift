//
//  TokenGraph.swift
//  Whisperer
//
//  The transcript as an addressable sequence of tokens rather than a `String`.
//
//  Two builders, one graph type:
//
//  - `from(words:)` — whisper.cpp and WhisperKit, where per-word timings and probabilities
//    already exist and are currently thrown away at the `TranscriptionBackend` seam.
//  - `from(text:capabilities:)` — the universal floor. Script-aware Unicode tokenization,
//    every evidence field `nil`. This is the Nemotron path, and it is the one exercised by
//    default in tests so the evidence-rich path cannot quietly become load-bearing.
//
//  **Landing rule.** `render()` on a freshly built graph is byte-identical to the text it was
//  built from, on both builders. The graph goes in behind the existing string output and is
//  proven inert before anything consumes it — a representation change that also changes
//  behaviour cannot be debugged.
//

import Foundation

struct TokenGraph: Sendable {

    // MARK: - State

    private(set) var tokens: [TranscriptToken]

    /// What evidence the producing backend could supply. Carried on the graph rather than
    /// inferred from whether fields happen to be `nil`, because "this engine has no
    /// probabilities" and "this particular word had none" must not be confused.
    let capabilities: ASRCapabilities

    /// Exactly what the ASR produced, before any edit. Permanent.
    let rawTranscript: String

    /// Every edit that survived the gate, in application order.
    private(set) var appliedEdits: [AppliedEdit] = []

    /// Parallel to `tokens` as built. Not maintained across edits — it exists so text-based
    /// detectors (the protection patterns, which are regexes) can map a match back onto
    /// token IDs, and detection runs before any edit is applied.
    ///
    /// The invariant is enforced by `hasMutated` rather than documented: zipping a stale
    /// `rawRanges` against a shortened `tokens` silently pairs token *i* with the range of token
    /// *i+k*, which would hand `ProtectionDetector` the wrong span to hard-protect.
    private let rawRanges: [Range<String.Index>]

    /// True once any edit has been applied. `rawRanges` is meaningless from that point on.
    private var hasMutated = false

    /// `tokens` index for each live `TokenID`.
    ///
    /// `index(of:)` is called once per edit from both `ConfidenceGate.judge` and `apply`, so a
    /// linear scan made a polish pass O(tokens × edits) — quadratic on exactly the long
    /// single-breath dictation that produces the most edits. Maintained on every mutation that
    /// can move a token: replace does not, delete and insert renumber the suffix, which costs
    /// the same order as the array shift they already pay for.
    private var indexByID: [TokenID: Int]

    private var nextTokenValue: Int

    // MARK: - Builders

    /// Text-only builder. The floor every engine can reach.
    ///
    /// - Parameter capabilities: what the producing backend *could* have supplied. Defaults
    ///   to `[]` — if a caller has evidence it must say so explicitly, so that forgetting to
    ///   declare it degrades to conservative behaviour rather than to a wrong assumption.
    static func from(text: String, capabilities: ASRCapabilities = []) -> TokenGraph {
        let pieces = Self.tokenize(text)
        var tokens: [TranscriptToken] = []
        var ranges: [Range<String.Index>] = []
        tokens.reserveCapacity(pieces.count)
        ranges.reserveCapacity(pieces.count)

        for (index, piece) in pieces.enumerated() {
            tokens.append(TranscriptToken(id: TokenID(index),
                                          kind: piece.kind,
                                          rawText: String(text[piece.range])))
            ranges.append(piece.range)
        }

        return TokenGraph(tokens: tokens,
                          capabilities: capabilities,
                          rawTranscript: text,
                          rawRanges: ranges,
                          nextTokenValue: pieces.count)
    }

    /// Evidence-rich builder for backends that emit word-level output.
    ///
    /// `WhisperStreamWord.text` carries its own leading space when the BPE output had one, so
    /// the concatenation of every `text` is the transcript verbatim. That concatenation is
    /// what gets tokenized, and each resulting token inherits the evidence of the word whose
    /// text it came from — a word that splits into `word` + `punctuation` gives both pieces
    /// the same span and probability, which is the truth: the ASR scored them together.
    static func from(words: [WhisperStreamWord],
                     capabilities: ASRCapabilities = .whisperCpp) -> TokenGraph {
        let text = words.map(\.text).joined()
        let pieces = Self.tokenize(text)

        // Walk both sequences once. `wordEnds` are offsets into `text` at which each source
        // word finishes, so a linear scan attributes every piece to exactly one word.
        var wordEnds: [Int] = []
        var running = 0
        for word in words {
            running += word.text.count
            wordEnds.append(running)
        }

        var tokens: [TranscriptToken] = []
        var ranges: [Range<String.Index>] = []
        tokens.reserveCapacity(pieces.count)
        ranges.reserveCapacity(pieces.count)

        var wordIndex = 0
        for (index, piece) in pieces.enumerated() {
            let offset = text.distance(from: text.startIndex, to: piece.range.lowerBound)
            while wordIndex < wordEnds.count - 1 && offset >= wordEnds[wordIndex] {
                wordIndex += 1
            }
            let source: WhisperStreamWord? = words.indices.contains(wordIndex) ? words[wordIndex] : nil

            tokens.append(TranscriptToken(
                id: TokenID(index),
                kind: piece.kind,
                rawText: String(text[piece.range]),
                // Whitespace carries no acoustic meaning; attaching a probability to it would
                // let a gate read a confidence off a gap between words.
                audioStart: piece.kind == .whitespace ? nil : source.map(\.start),
                audioEnd: piece.kind == .whitespace ? nil : source.map(\.end),
                asrProbability: piece.kind == .whitespace ? nil : source.map(\.probability),
                asrTokens: piece.kind == .whitespace ? nil : source.map(\.tokens)))
            ranges.append(piece.range)
        }

        return TokenGraph(tokens: tokens,
                          capabilities: capabilities,
                          rawTranscript: text,
                          rawRanges: ranges,
                          nextTokenValue: pieces.count)
    }

    private init(tokens: [TranscriptToken],
                 capabilities: ASRCapabilities,
                 rawTranscript: String,
                 rawRanges: [Range<String.Index>],
                 nextTokenValue: Int) {
        self.tokens = tokens
        self.capabilities = capabilities
        self.rawTranscript = rawTranscript
        self.rawRanges = rawRanges
        self.nextTokenValue = nextTokenValue
        var map: [TokenID: Int] = Dictionary(minimumCapacity: tokens.count)
        for (index, token) in tokens.enumerated() { map[token.id] = index }
        self.indexByID = map
    }

    /// Renumber `indexByID` for every token from `start` onward. Called after an insertion or a
    /// removal, which are the only operations that move a token.
    private mutating func reindex(from start: Int) {
        for index in start..<tokens.count { indexByID[tokens[index].id] = index }
    }

    // MARK: - Rendering

    /// The transcript as it currently reads. A plain concatenation — which is why a freshly
    /// built graph renders byte-identically to its input, with no reassembly heuristics to
    /// get wrong around RTL text.
    func render() -> String {
        tokens.reduce(into: "") { $0 += $1.effectiveText }
    }

    // MARK: - Lookup

    /// O(1). The identity check is not paranoia for its own sake: a stale map mis-targets an
    /// edit, which is a worse failure than the linear scan this replaced, so a map that has
    /// somehow drifted degrades to "target not found" rather than to "wrong token".
    func index(of id: TokenID) -> Int? {
        guard let index = indexByID[id], index < tokens.count, tokens[index].id == id else {
            return nil
        }
        return index
    }

    func token(_ id: TokenID) -> TranscriptToken? {
        index(of: id).map { tokens[$0] }
    }

    /// Token IDs whose original text overlaps a range of `rawTranscript`.
    ///
    /// The bridge from text-based detectors to token addressing: the 13 protection patterns
    /// are regexes over text, and this is what turns a match into a set of tokens to mask.
    /// Valid only before edits are applied — detection runs first, which is when it is used.
    /// After the first edit this returns nothing rather than something wrong: `rawRanges` no
    /// longer lines up with `tokens`, so the zip below would pair each token with some other
    /// token's span and hand the caller IDs it never asked about.
    func tokenIDs(overlappingRawRange range: Range<String.Index>) -> [TokenID] {
        guard !hasMutated else {
            Logger.error("tokenIDs(overlappingRawRange:) called after an edit — raw ranges no "
                         + "longer address this graph; returning none", subsystem: .transcription)
            return []
        }
        return zip(tokens, rawRanges)
            .filter { $0.1.overlaps(range) || ($0.1.isEmpty && range.contains($0.1.lowerBound)) }
            .map { $0.0.id }
    }

    // MARK: - Mutation

    /// Mark tokens as protected. Raises only — a span already `hard` is never demoted by a
    /// later, weaker detector.
    mutating func protect(_ ids: some Sequence<TokenID>, as level: TokenProtection) {
        let wanted = Set(ids)
        for i in tokens.indices where wanted.contains(tokens[i].id) {
            tokens[i].protection = max(tokens[i].protection, level)
        }
    }

    /// Promote lifecycle. Raises only, for the same reason: `.userFinal` must not be walked
    /// back to `.asrStable` by a later streaming pass arriving out of order.
    mutating func promote(_ ids: some Sequence<TokenID>, to stage: TokenLifecycle) {
        let wanted = Set(ids)
        for i in tokens.indices where wanted.contains(tokens[i].id) {
            tokens[i].lifecycle = max(tokens[i].lifecycle, stage)
        }
    }

    /// Apply an edit that has already cleared the gate.
    ///
    /// Deliberately does not itself gate: `ConfidenceGate` decides, this executes, and
    /// keeping the two apart means the decision is testable without mutating anything. The
    /// two structural invariants that cannot be delegated are enforced here anyway — a hard
    /// span and a `.userFinal` token are never modified, whatever the caller believes.
    @discardableResult
    mutating func apply(_ edit: TranscriptEdit) -> Bool {
        guard !edit.operation.isNoOp, let i = index(of: edit.target) else { return false }
        guard tokens[i].protection != .hard, tokens[i].lifecycle != .userFinal else {
            Logger.debug("Edit rejected structurally: \(edit.target) is "
                         + "\(tokens[i].protection == .hard ? "hard-protected" : "user-final")",
                         subsystem: .transcription)
            return false
        }

        let previous = tokens[i].effectiveText
        switch edit.operation {
        case .keep:
            return false
        case .replace(let text):
            tokens[i].normalizedText = text
        case .delete:
            indexByID.removeValue(forKey: tokens[i].id)
            tokens.remove(at: i)
            reindex(from: i)
        case .insertAfter(let text):
            let inserted = TranscriptToken(id: TokenID(nextTokenValue),
                                           kind: Self.kind(ofSingle: text),
                                           rawText: "",
                                           lifecycle: tokens[i].lifecycle,
                                           normalizedText: text)
            nextTokenValue += 1
            tokens.insert(inserted, at: i + 1)
            reindex(from: i + 1)
        }

        hasMutated = true
        appliedEdits.append(AppliedEdit(edit: edit, previousText: previous))
        return true
    }

    // MARK: - Tokenization

    private struct Piece {
        let range: Range<String.Index>
        let kind: TokenKind
    }

    /// Script-aware, locale-free segmentation.
    ///
    /// A word is a run of letters, digits and combining marks, plus apostrophes and
    /// underscores *between* two such characters — enough to keep `don't`, `שלוש`, `snake_case`
    /// and `camelCase` whole. Everything else becomes one token per character: whitespace
    /// tokens so that rendering is a concatenation, punctuation tokens so that restoring
    /// sentence punctuation is an insertion rather than a rewrite of a neighbouring word.
    ///
    /// Not `enumerateSubstrings(.byWords)`: that drops the material between words, which is
    /// most of what punctuation restoration operates on, and reassembling around the holes
    /// is precisely the offset arithmetic this design exists to avoid.
    private static func tokenize(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace {
                let start = index
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
                pieces.append(Piece(range: start..<index, kind: .whitespace))
                continue
            }

            if isWordCharacter(character) {
                let start = index
                var end = text.index(after: index)
                while end < text.endIndex {
                    if isWordCharacter(text[end]) {
                        end = text.index(after: end)
                    } else if isWordConnector(text[end]) {
                        // A connector only stays inside the word if a word character follows.
                        // Otherwise `don't.` would swallow the period and `foo_` the underscore.
                        let after = text.index(after: end)
                        guard after < text.endIndex, isWordCharacter(text[after]) else { break }
                        end = text.index(after: after)
                    } else {
                        break
                    }
                }
                pieces.append(Piece(range: start..<end, kind: .word))
                index = end
                continue
            }

            let next = text.index(after: index)
            pieces.append(Piece(range: index..<next, kind: .punctuation))
            index = next
        }

        return pieces
    }

    /// Combining marks need no case of their own: Swift's `Character` is a grapheme cluster,
    /// so Hebrew niqqud and Cyrillic breves arrive already attached to the letter they modify
    /// and `isLetter` is true for the whole cluster.
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func isWordConnector(_ c: Character) -> Bool {
        c == "'" || c == "\u{2019}" || c == "_"
    }

    /// Kind for text an edit inserts. Insertions are punctuation in practice — a period, a
    /// comma — so anything without a word character is classified as such.
    private static func kind(ofSingle text: String) -> TokenKind {
        if text.allSatisfy(\.isWhitespace) { return .whitespace }
        return text.contains(where: isWordCharacter) ? .word : .punctuation
    }
}

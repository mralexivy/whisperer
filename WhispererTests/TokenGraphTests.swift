//
//  TokenGraphTests.swift
//  WhispererTests
//
//  Milestone 1's landing rule, as tests: a freshly built graph renders byte-identically to
//  the text it was built from, on *both* builders, and token addressing survives the
//  RTL/LTR mixtures where UTF-16 offset arithmetic fails silently.
//
//  The corpus here is the app's own history rather than invented strings — a tokenizer that
//  round-trips six hand-written sentences and mangles a real Hebrew dictation has not been
//  tested, it has been flattered.
//

import XCTest
@testable import whisperer

final class TokenGraphTests: XCTestCase {

    // MARK: - Round trip

    func testTextBuilderRoundTripsHandwrittenCases() {
        for sample in Self.samples {
            let graph = TokenGraph.from(text: sample)
            XCTAssertEqual(graph.render(), sample,
                           "text builder did not round-trip: \(Self.escape(sample))")
        }
    }

    /// The one the plan names: the worked example, which mixes Latin, Hebrew and Cyrillic in
    /// a single utterance.
    func testWorkedExampleRoundTrips() {
        let example = "okay um first send the deployment to chat gpt second update postgress "
                    + "and then כאילו restart the service сегодня"
        let graph = TokenGraph.from(text: example)
        XCTAssertEqual(graph.render(), example)

        // Every script segments into words rather than collapsing into punctuation runs.
        let words = graph.tokens.filter(\.isWord).map(\.rawText)
        XCTAssertTrue(words.contains("כאילו"), "Hebrew did not tokenize as a word: \(words)")
        XCTAssertTrue(words.contains("сегодня"), "Cyrillic did not tokenize as a word: \(words)")
        XCTAssertTrue(words.contains("postgress"))
    }

    /// Real transcripts, which contain things no hand-written sample thinks of: emoji,
    /// non-breaking spaces, doubled punctuation, bare newlines, mid-word apostrophes.
    func testTextBuilderRoundTripsRealHistory() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")

        var checked = 0
        for fixture in fixtures {
            let graph = TokenGraph.from(text: fixture.transcript)
            XCTAssertEqual(graph.render(), fixture.transcript,
                           "round-trip failed on fixture \(fixture.id.prefix(8))")
            checked += 1
        }
        // A silently empty corpus passes every assertion above.
        XCTAssertGreaterThan(checked, 50, "corpus too small to mean anything: \(checked)")
        print("TokenGraph round-tripped \(checked) real transcripts")
    }

    /// The golden set is the benchmark's quality reference, so the graph has to survive
    /// exactly the strings the benchmark will score against.
    func testTextBuilderRoundTripsGoldenSet() throws {
        try XCTSkipIf(GoldenSet.isEmpty, "golden set did not load")
        for (id, entry) in GoldenSet.entries {
            let graph = TokenGraph.from(text: entry.goldenTranscript)
            XCTAssertEqual(graph.render(), entry.goldenTranscript,
                           "round-trip failed on golden entry \(id.prefix(8))")
        }
        print("TokenGraph round-tripped \(GoldenSet.entries.count) golden transcripts")
    }

    // MARK: - Word builder

    func testWordBuilderRoundTripsAndCarriesEvidence() {
        let words = [
            WhisperStreamWord(text: "Hello", tokens: [1, 2], start: 0.0, end: 0.4, probability: 0.91),
            WhisperStreamWord(text: " world.", tokens: [3], start: 0.4, end: 0.9, probability: 0.77),
            WhisperStreamWord(text: " שלום", tokens: [4], start: 0.9, end: 1.3, probability: 0.62),
        ]
        let graph = TokenGraph.from(words: words)

        XCTAssertEqual(graph.render(), "Hello world. שלום")
        XCTAssertEqual(graph.capabilities, .whisperCpp)

        // "world." must split into a word and a period, both attributed to the same source
        // word — the ASR scored them together and pretending otherwise invents evidence.
        let period = graph.tokens.first { $0.rawText == "." }
        XCTAssertEqual(period?.kind, .punctuation)
        XCTAssertEqual(period?.asrProbability, 0.77)

        let hebrew = graph.tokens.first { $0.rawText == "שלום" }
        XCTAssertEqual(hebrew?.asrProbability, 0.62)
        XCTAssertEqual(hebrew?.audioStart, 0.9)

        // Whitespace carries no acoustic meaning; a gate must not be able to read a
        // confidence off the gap between two words.
        let gaps = graph.tokens.filter { $0.kind == .whitespace }
        XCTAssertFalse(gaps.isEmpty)
        XCTAssertTrue(gaps.allSatisfy { $0.asrProbability == nil })
    }

    /// The engine-parity property in miniature: the same transcript, built both ways, is the
    /// same sequence of tokens. Divergence here means evidence changed segmentation, which
    /// would make every downstream guarantee whisper.cpp-only.
    func testBothBuildersProduceIdenticalStructure() {
        let words = [
            WhisperStreamWord(text: "Update", tokens: [1], start: 0, end: 0.3, probability: 0.9),
            WhisperStreamWord(text: " postgress,", tokens: [2], start: 0.3, end: 0.8, probability: 0.5),
            WhisperStreamWord(text: " сегодня", tokens: [3], start: 0.8, end: 1.2, probability: 0.8),
        ]
        let fromWords = TokenGraph.from(words: words)
        let fromText = TokenGraph.from(text: words.map(\.text).joined())

        XCTAssertEqual(fromWords.render(), fromText.render())
        XCTAssertEqual(fromWords.tokens.map(\.rawText), fromText.tokens.map(\.rawText))
        XCTAssertEqual(fromWords.tokens.map(\.kind), fromText.tokens.map(\.kind))
        // Only the evidence differs, and only in the direction the tier allows.
        XCTAssertEqual(fromText.capabilities, [])
        XCTAssertTrue(fromText.tokens.allSatisfy { $0.asrProbability == nil })
    }

    // MARK: - Tokenization detail

    func testIdentifiersAndContractionsStayWhole() {
        let graph = TokenGraph.from(text: "don't call loadModel or mask_prompt")
        let words = graph.tokens.filter(\.isWord).map(\.rawText)
        XCTAssertEqual(words, ["don't", "call", "loadModel", "or", "mask_prompt"])
    }

    func testTrailingConnectorIsNotSwallowed() {
        // `don't.` must be word + period, not one word ending in a period — otherwise
        // terminal-punctuation detection can never see the period.
        let graph = TokenGraph.from(text: "don't.")
        XCTAssertEqual(graph.tokens.map(\.rawText), ["don't", "."])
        XCTAssertEqual(graph.render(), "don't.")
    }

    // MARK: - Editing

    func testEditsAddressTokensAcrossRTLBoundaries() {
        // Insertion after a Hebrew word, in a string where the Hebrew sits between two Latin
        // runs. A UTF-16 offset computed before the edit would land in the wrong place after
        // it; a token ID cannot.
        var graph = TokenGraph.from(text: "restart the service כאילו now")
        guard let target = graph.tokens.first(where: { $0.rawText == "כאילו" })?.id else {
            return XCTFail("Hebrew token not found")
        }

        XCTAssertTrue(graph.apply(TranscriptEdit(
            target: target, operation: .delete, source: .filler,
            confidence: 1.0, reason: "Hebrew filler")))
        XCTAssertEqual(graph.render(), "restart the service  now")

        // The raw transcript is never touched, so the original is always reconstructible.
        XCTAssertEqual(graph.rawTranscript, "restart the service כאילו now")
        XCTAssertEqual(graph.appliedEdits.count, 1)
        XCTAssertEqual(graph.appliedEdits.first?.previousText, "כאילו")
    }

    func testHardProtectionRejectsEditsStructurally() {
        var graph = TokenGraph.from(text: "deploy loadModel now")
        let ident = graph.tokens.first { $0.rawText == "loadModel" }!.id
        graph.protect([ident], as: .hard)

        // A maximally confident edit from any source still loses to a hard span.
        XCTAssertFalse(graph.apply(TranscriptEdit(
            target: ident, operation: .replace("load model"), source: .editorModel,
            confidence: 1.0, reason: "spell split")))
        XCTAssertEqual(graph.render(), "deploy loadModel now")
        XCTAssertTrue(graph.appliedEdits.isEmpty)
    }

    func testUserFinalTokensAreImmutable() {
        var graph = TokenGraph.from(text: "keep this word")
        let word = graph.tokens.first { $0.rawText == "this" }!.id
        graph.promote([word], to: .userFinal)
        XCTAssertFalse(graph.apply(TranscriptEdit(
            target: word, operation: .replace("that"), source: .alias,
            confidence: 1.0, reason: "alias")))
        XCTAssertEqual(graph.render(), "keep this word")
    }

    func testProtectionAndLifecycleRaiseOnly() {
        var graph = TokenGraph.from(text: "one two")
        let first = graph.tokens[0].id
        graph.protect([first], as: .hard)
        graph.protect([first], as: .soft)          // must not demote
        XCTAssertEqual(graph.token(first)?.protection, .hard)

        graph.promote([first], to: .utteranceFinal)
        graph.promote([first], to: .provisional)   // must not demote
        XCTAssertEqual(graph.token(first)?.lifecycle, .utteranceFinal)
    }

    func testInsertAfterPlacesPunctuationAndKeepsRawText() {
        var graph = TokenGraph.from(text: "hello world")
        let last = graph.tokens.last { $0.isWord }!.id
        XCTAssertTrue(graph.apply(TranscriptEdit(
            target: last, operation: .insertAfter("."), source: .editorModel,
            confidence: 0.99, reason: "terminal punctuation")))
        XCTAssertEqual(graph.render(), "hello world.")
        XCTAssertEqual(graph.rawTranscript, "hello world")
    }

    // MARK: - Text→token mapping

    func testRegexMatchesMapOntoTokens() {
        // The bridge the protection detector needs: the 13 patterns are regexes over text,
        // and a match has to become a set of token IDs to mask.
        let text = "see https://example.com/docs for details"
        let graph = TokenGraph.from(text: text)
        let match = text.range(of: "https://example.com/docs")!
        let ids = graph.tokenIDs(overlappingRawRange: match)

        let covered = ids.compactMap { graph.token($0)?.rawText }.joined()
        XCTAssertEqual(covered, "https://example.com/docs")
        // And the span is contiguous — a masked URL with a hole in it is not masked.
        XCTAssertEqual(ids, ids.sorted())
    }

    // MARK: - Fixtures

    private static let samples = [
        "",
        " ",
        "Hello.",
        "hello world",
        "Multiple   spaces   collapse?  Not here — the graph is inert.",
        "Line one\nLine two\r\nLine three",
        "שלום עולם, מה נשמע?",
        "Привет, мир! Как дела?",
        "Mixed שלום and привет and English in one line.",
        "Numbers 3.14, 1,000 and v2.31.3.",
        "docker run --rm -it ubuntu:22.04",
        "Email me at a.b@example.co.il or see /src/utils.",
        "Emoji 🎉 and combining é and ﬁ ligature.",
        "  leading and trailing  ",
        "רק עברית",
        "don't shouldn't it's",
        "camelCase snake_case kebab-case-name",
    ]

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }
}

//
//  ProtectionDetectorTests.swift
//  WhispererTests
//
//  Verification item 4: hard spans survive a round trip, a mangling edit is refused, and a
//  Hebrew or Russian input containing a Latin identifier is protected — which it is not today.
//

import XCTest
@testable import whisperer

final class ProtectionDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func annotated(_ text: String, dictionary: Set<String> = []) -> TokenGraph {
        var graph = TokenGraph.from(text: text)
        ProtectionDetector.annotate(&graph, dictionaryTerms: dictionary)
        return graph
    }

    private func protection(of word: String, in graph: TokenGraph) -> TokenProtection? {
        graph.tokens.first { $0.rawText == word }?.protection
    }

    /// Asserts every token overlapping `span` is hard-protected.
    private func assertHard(_ span: String, in text: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let graph = annotated(text)
        guard let range = text.range(of: span) else {
            return XCTFail("span not present in input", file: file, line: line)
        }
        let ids = graph.tokenIDs(overlappingRawRange: range)
        XCTAssertFalse(ids.isEmpty, "span mapped to no tokens: \(span)", file: file, line: line)
        for id in ids {
            XCTAssertEqual(graph.token(id)?.protection, .hard,
                           "unprotected token \(graph.token(id)?.rawText ?? "?") in \(span)",
                           file: file, line: line)
        }
    }

    // MARK: - The 13 patterns still fire

    func testClassicHardSpansAreProtected() {
        assertHard("https://example.com/docs", in: "see https://example.com/docs now")
        assertHard("me@example.co.il", in: "mail me@example.co.il please")
        assertHard("/src/utils", in: "open /src/utils and edit")
        assertHard("--no-verify", in: "commit with --no-verify flag")
        assertHard("v2.31.3", in: "we shipped v2.31.3 today")
        assertHard("loadModel", in: "call loadModel first")
        assertHard("mask_prompt", in: "set mask_prompt to true")
        assertHard("192.168.1.1", in: "ping 192.168.1.1 twice")
        assertHard("`git rebase`", in: "run `git rebase` now")
    }

    // MARK: - The gap this closes

    /// The defect named in the plan: today a Hebrew transcript gets no protection at all.
    func testLatinIdentifierInsideHebrewIsProtected() {
        let graph = annotated("צריך להריץ את loadModel לפני ה deployment")
        XCTAssertEqual(protection(of: "loadModel", in: graph), .hard)
        // `deployment` is a lone Latin word in a Hebrew sentence — a code switch, not an error
        // the spell checker should be allowed to resolve on its own.
        XCTAssertEqual(protection(of: "deployment", in: graph), .soft)
        // Ordinary Hebrew words stay editable; over-protecting everything would be no protection.
        XCTAssertEqual(protection(of: "צריך", in: graph), .ordinary)
    }

    func testLatinIdentifierInsideRussianIsProtected() {
        let graph = annotated("надо запустить loadModel сегодня")
        XCTAssertEqual(protection(of: "loadModel", in: graph), .hard)
        XCTAssertEqual(protection(of: "сегодня", in: graph), .ordinary)
    }

    /// The worked example's own requirement: `сегодня` sits in an English sentence, so it is a
    /// foreign token, and the gate must see it as one rather than as a misspelling.
    func testForeignTokenInEnglishSentenceIsSoft() {
        let graph = annotated("restart the service сегодня")
        XCTAssertEqual(protection(of: "сегодня", in: graph), .soft)
        XCTAssertEqual(protection(of: "restart", in: graph), .ordinary)
    }

    func testNumbersAndAcronymsAreHardInEveryScript() {
        let english = annotated("the API returned 42 rows")
        XCTAssertEqual(protection(of: "API", in: english), .hard)
        XCTAssertEqual(protection(of: "42", in: english), .hard)

        let hebrew = annotated("קיבלנו 42 שורות")
        XCTAssertEqual(protection(of: "42", in: hebrew), .hard)
    }

    func testDictionaryTermsAreHard() {
        let graph = annotated("we use Kubernetes here", dictionary: ["kubernetes"])
        XCTAssertEqual(protection(of: "Kubernetes", in: graph), .hard)
        XCTAssertEqual(protection(of: "here", in: graph), .ordinary)
    }

    // MARK: - Round trip and refusal

    func testAnnotationChangesNoText() {
        // The whole point of a mask: the transcript after annotation is the transcript before.
        for text in ["see https://example.com now",
                     "צריך להריץ את loadModel",
                     "run `docker run --rm -it ubuntu` please"] {
            XCTAssertEqual(annotated(text).render(), text)
        }
    }

    func testManglingEditAgainstHardSpanIsRefused() {
        var graph = annotated("call loadModel now")
        let target = graph.tokens.first { $0.rawText == "loadModel" }!.id
        XCTAssertFalse(graph.apply(TranscriptEdit(
            target: target, operation: .replace("load model"), source: .editorModel,
            confidence: 1.0, reason: "synthetic mangle")))
        XCTAssertEqual(graph.render(), "call loadModel now")
    }

    // MARK: - Corpus sanity

    /// Over-protection is the safe direction, but protecting *everything* would silently make
    /// the whole plan a no-op. Measure the rate on the real corpus so a future change that
    /// blows it up is visible rather than merely safe.
    func testProtectionRateOnRealCorpusIsReasonable() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")

        var words = 0, hard = 0, soft = 0
        for fixture in fixtures {
            let graph = annotated(fixture.transcript)
            for token in graph.tokens where token.isWord {
                words += 1
                if token.protection == .hard { hard += 1 }
                if token.protection == .soft { soft += 1 }
            }
        }
        try XCTSkipIf(words == 0, "corpus contained no words")

        let hardRate = Double(hard) / Double(words)
        let softRate = Double(soft) / Double(words)
        print(String(format: "Protection over %d words: hard %.1f%%, soft %.1f%%",
                     words, hardRate * 100, softRate * 100))
        XCTAssertLessThan(hardRate, 0.25, "hard protection is swallowing the corpus")
        XCTAssertLessThan(softRate, 0.25, "soft protection is swallowing the corpus")
    }
}

//
//  AliasEngineTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class AliasEngineTests: XCTestCase {

    private func entry(_ incorrect: String, _ correct: String,
                       builtIn: Bool = false, enabled: Bool = true) -> DictionaryEntry {
        DictionaryEntry(incorrectForm: incorrect, correctForm: correct,
                        isBuiltIn: builtIn, isEnabled: enabled)
    }

    private func polished(_ text: String, engine: AliasEngine) -> String {
        var graph = TokenGraph.from(text: text)
        engine.apply(to: &graph)
        return graph.render()
    }

    // MARK: - Substitution

    func testShippedLexiconCanonicalizesMultiWordPhrases() {
        let engine = AliasEngine()
        XCTAssertEqual(polished("send it to chat gpt now", engine: engine),
                       "send it to ChatGPT now")
        XCTAssertEqual(polished("update postgress today", engine: engine),
                       "update PostgreSQL today")
        XCTAssertEqual(polished("push to git hub", engine: engine), "push to GitHub")
    }

    /// The worked example's alias half, on the text-only builder.
    func testWorkedExampleAliases() {
        let engine = AliasEngine()
        let input = "send the deployment to chat gpt second update postgress"
        XCTAssertEqual(polished(input, engine: engine),
                       "send the deployment to ChatGPT second update PostgreSQL")
    }

    func testMatchingIsCaseInsensitiveAndBoundaryAware() {
        let engine = AliasEngine()
        XCTAssertEqual(polished("ask Chat GPT", engine: engine), "ask ChatGPT")
        // Punctuation ends the phrase — `chat, gpt` is two things.
        XCTAssertEqual(polished("chat, gpt", engine: engine), "chat, gpt")
        // And a longer word is not a prefix match.
        XCTAssertEqual(polished("chatting about gpt", engine: engine), "chatting about gpt")
    }

    func testLongestMatchWins() {
        let engine = AliasEngine(entries: [entry("cloud", "Cloud"),
                                           entry("cloud code", "Claude Code")],
                                 includeShippedLexicon: false)
        XCTAssertEqual(polished("open cloud code please", engine: engine),
                       "open Claude Code please")
        XCTAssertEqual(polished("open cloud please", engine: engine), "open Cloud please")
    }

    // MARK: - Precedence

    func testUserEntryBeatsShippedLexicon() {
        // A user who has decided `postgress` means their internal service must not be overruled
        // by the table we shipped.
        let engine = AliasEngine(entries: [entry("postgress", "PostGress")])
        XCTAssertEqual(polished("deploy postgress", engine: engine), "deploy PostGress")
    }

    func testPrecedenceIsIndependentOfInsertionOrder() {
        let forward = AliasEngine(entries: [entry("foo", "BuiltIn", builtIn: true),
                                            entry("foo", "UserValue")],
                                  includeShippedLexicon: false)
        let backward = AliasEngine(entries: [entry("foo", "UserValue"),
                                             entry("foo", "BuiltIn", builtIn: true)],
                                   includeShippedLexicon: false)
        XCTAssertEqual(polished("foo", engine: forward), "UserValue")
        XCTAssertEqual(polished("foo", engine: backward), "UserValue")
    }

    func testDisabledEntriesAreIgnored() {
        let engine = AliasEngine(entries: [entry("foo", "Bar", enabled: false)],
                                 includeShippedLexicon: false)
        XCTAssertEqual(polished("foo", engine: engine), "foo")
    }

    // MARK: - Protection interaction

    func testAppliedAliasesBecomeHardProtected() {
        var graph = TokenGraph.from(text: "ask chat gpt")
        AliasEngine().apply(to: &graph)
        let canonical = graph.tokens.first { $0.effectiveText == "ChatGPT" }
        XCTAssertEqual(canonical?.protection, .hard)
    }

    func testPhraseIsSkippedEntirelyWhenAnyTokenIsProtected() {
        // Half-applying a multi-word alias — replacement lands, delete refused — would corrupt
        // the text in a way no single edit can. The whole phrase must be skipped instead.
        var graph = TokenGraph.from(text: "ask chat gpt")
        let gpt = graph.tokens.first { $0.rawText == "gpt" }!.id
        graph.protect([gpt], as: .hard)

        AliasEngine().apply(to: &graph)
        XCTAssertEqual(graph.render(), "ask chat gpt")
    }

    func testUserFinalTextIsNeverAliased() {
        var graph = TokenGraph.from(text: "ask chat gpt")
        graph.promote(graph.tokens.map(\.id), to: .userFinal)
        AliasEngine().apply(to: &graph)
        XCTAssertEqual(graph.render(), "ask chat gpt")
    }

    // MARK: - Engine independence

    /// Same input, both builders, same output. Nothing in aliasing reads audio, so any
    /// divergence here would mean evidence had leaked into a text-only path.
    func testIdenticalOnBothBuilders() {
        let words = [
            WhisperStreamWord(text: "ask", tokens: [1], start: 0, end: 0.2, probability: 0.9),
            WhisperStreamWord(text: " chat", tokens: [2], start: 0.2, end: 0.5, probability: 0.4),
            WhisperStreamWord(text: " gpt", tokens: [3], start: 0.5, end: 0.8, probability: 0.3),
        ]
        var fromWords = TokenGraph.from(words: words)
        var fromText = TokenGraph.from(text: "ask chat gpt")
        let engine = AliasEngine()
        engine.apply(to: &fromWords)
        engine.apply(to: &fromText)
        XCTAssertEqual(fromWords.render(), fromText.render())
        XCTAssertEqual(fromWords.render(), "ask ChatGPT")
    }

    // MARK: - Non-Latin

    func testHebrewSentenceWithLatinAliasIsCorrected() {
        let engine = AliasEngine()
        XCTAssertEqual(polished("צריך לשאול את chat gpt", engine: engine),
                       "צריך לשאול את ChatGPT")
    }

    func testHebrewAliasEntriesWork() {
        // The trie keys on words, not on ASCII, so a Hebrew alias is not a special case.
        let engine = AliasEngine(entries: [entry("קוברנטיס", "Kubernetes")],
                                 includeShippedLexicon: false)
        XCTAssertEqual(polished("מריצים קוברנטיס בענן", engine: engine),
                       "מריצים Kubernetes בענן")
    }

    // MARK: - Corpus safety

    /// Aliasing must not run wild on real text. A high hit rate here would mean the shipped
    /// lexicon is matching ordinary speech, which is the failure mode that costs precision.
    func testAliasRateOnRealCorpus() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")

        let engine = AliasEngine()
        var words = 0, hits = 0, changed = 0
        for fixture in fixtures {
            var graph = TokenGraph.from(text: fixture.transcript)
            words += graph.tokens.filter(\.isWord).count
            let applied = engine.apply(to: &graph)
            hits += applied
            if applied > 0 { changed += 1 }
        }
        print(String(format: "Alias: %d edits over %d words in %d/%d fixtures",
                     hits, words, changed, fixtures.count))
        XCTAssertLessThan(Double(hits) / Double(words), 0.02,
                          "shipped lexicon is matching ordinary speech")
    }
}

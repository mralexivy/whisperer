//
//  CorrectionNegativeCorpusTests.swift
//  WhispererTests
//
//  Asserts that ordinary English sentences pass through applyCorrections
//  BYTE-FOR-BYTE UNCHANGED when loaded against the real bundled packs.
//
//  If any sentence is mutated, a correction engine rule is mangling normal
//  dictation — add the rule to the audit DROP list or the engine guard must
//  catch it.
//
//  Strategy: build a CorrectionEngine from the real bundled pack entries loaded
//  via DictionaryManager (mirroring the production path) and assert each
//  sentence is untouched. Because DictionaryManager loads asynchronously, we
//  use HistoryDatabase directly to fetch whatever built-in entries are present.
//
//  NOTE: These tests read the real app bundle.  They run fast (no model loading)
//  and are safe to include in the default test run.

import XCTest
@testable import whisperer

final class CorrectionNegativeCorpusTests: XCTestCase {

    // Kept alive for the same @MainActor isolated-deinit reason as CorrectionEngineTests.
    private static var liveEngines: [CorrectionEngine] = []

    // MARK: - Corpus

    /// English sentences that must NEVER be altered by the correction engine.
    /// Each string is a realistic dictation that happens to contain words or
    /// phrases that appear (or used to appear) in the built-in dictionary.
    private static let negativeSentences: [String] = [
        // Words that map to programming languages but are real English
        "the closure of that method was tricky to reason about",
        "he is a Rhodes scholar who transferred to Stanford",
        "that refactor was such a hassle",
        "the cotton fabric felt soft against my skin",
        "pearl necklaces are classic jewelry",
        "the dart flew past the target",
        "that was quick — well done",
        "the viper snake is venomous",
        "cobalt blue is a beautiful color",
        "the prologue set the stage for the story",
        "elixir of life is a mythical concept",
        "scale a mountain before sunset",
        "rusk is a twice-baked bread snack",
        "she caught the plane in London",

        // Phrases that map to abbreviations but are real English
        "I have to do this before the standup",
        "not a bug, just a feature request",
        "in my humble opinion, we should iterate",
        "as far as I know, the server is up",
        "for what its worth, that was a good call",
        "today I learned something new about async",
        "your mileage may vary on this approach",
        "if I remember correctly, she said Tuesday",
        "as far as I can tell, the migration is done",

        // Words that share phonetics with tool names
        "go long on this investment strategy",
        "the go laying of the foundation took weeks",
        "we need to re mix the audio tracks",
        "the closure pattern is useful in JavaScript",  // closure is NOT a phonetic of Clojure here
        "he set a record, breaking it quickly",

        // Normal standup language
        "yesterday I worked on the review",
        "today I will finish the pull request",
        "no blockers, moving forward",
        "I am done with the design document",
        "the sprint is going well",
        "we need to prioritize the backlog",

        // Misc tech-adjacent English that should not be mangled
        "the proxy is working fine now",
        "the server responded with a 200 status",
        "I will push the branch after lunch",
        "the build passed on the first try",
        "the review comment was addressed",
        "the meeting went over by ten minutes",
        "the service is back online",
        "we are on track for the deadline",
        "the team velocity is improving",
        "the product roadmap is ready to share",
    ]

    // MARK: - Engine setup from real bundle entries

    private static var builtInEngine: CorrectionEngine?
    /// True once all packs report version "2.0.0" (post-audit). Tests that depend on
    /// clean pack data skip themselves until then.
    private static var packsAreAudited = false

    override class func setUp() {
        super.setUp()

        // Build entries from the real bundled pack JSONs.
        // This mirrors what DictionaryManager does without the async CoreData path.
        guard let resourcePath = Bundle.main.resourcePath else {
            XCTFail("No resource path in bundle")
            return
        }

        let fileManager = FileManager.default
        let dictionariesPath = (resourcePath as NSString).appendingPathComponent("dictionaries")
        let searchPath = fileManager.fileExists(atPath: dictionariesPath) ? dictionariesPath : resourcePath

        var entries: [DictionaryEntry] = []
        var allAtV2 = true

        do {
            let files = try fileManager.contentsOfDirectory(atPath: searchPath)
            for filename in files.filter({ $0.hasPrefix("pack_") && $0.hasSuffix(".json") }).sorted() {
                let url = URL(fileURLWithPath: (searchPath as NSString).appendingPathComponent(filename))
                guard let data = try? Data(contentsOf: url),
                      let packFile = try? JSONDecoder().decode(DictionaryPackFile.self, from: data) else {
                    continue
                }
                if packFile.metadata.version != "2.0.0" { allAtV2 = false }
                for correction in packFile.corrections {
                    for alias in correction.aliases {
                        entries.append(DictionaryEntry(
                            incorrectForm: alias,
                            correctForm: correction.term,
                            category: packFile.metadata.category,
                            isBuiltIn: true,
                            notes: "test"
                        ))
                    }
                }
            }
        } catch {
            XCTFail("Failed to load pack files: \(error)")
            return
        }

        packsAreAudited = allAtV2
        let engine = CorrectionEngine(entries: entries)
        liveEngines.append(engine)
        builtInEngine = engine
    }

    // MARK: - Tests

    func testNegativeCorpusIsUnchangedByRealBundledPacks() throws {
        guard let engine = Self.builtInEngine else {
            throw XCTSkip("Bundle pack entries not loaded")
        }
        guard Self.packsAreAudited else {
            throw XCTSkip(
                "Packs are not yet at version 2.0.0 (pre-audit). " +
                "Run the LLM audit and apply_verdicts.py before expecting this test to pass."
            )
        }

        var failures: [(sentence: String, corrected: String)] = []

        for sentence in Self.negativeSentences {
            let result = engine.applyCorrections(sentence, maxEditDistance: 0, usePhonetic: false)
            if result.text != sentence {
                failures.append((sentence, result.text))
            }
        }

        if !failures.isEmpty {
            let details = failures.map { "  INPUT:    \($0.sentence)\n  OUTPUT:   \($0.corrected)" }
                .joined(separator: "\n\n")
            XCTFail("Correction engine mangled \(failures.count) ordinary sentence(s):\n\n\(details)\n")
        }
    }

    /// Individual named tests for key regressions (easier to spot in the test report).
    /// All skip on pre-audit packs (version < 2.0.0).

    func testClosureNotCorrectedToClojure() throws {
        guard Self.packsAreAudited else { throw XCTSkip("Requires audited packs (2.0.0)") }
        assertUnchanged("the closure of that method was tricky to reason about")
    }

    func testScholarNotCorrectedToScala() throws {
        guard Self.packsAreAudited else { throw XCTSkip("Requires audited packs (2.0.0)") }
        assertUnchanged("he is a Rhodes scholar who transferred to Stanford")
    }

    func testHassleNotCorrectedToHaskell() throws {
        guard Self.packsAreAudited else { throw XCTSkip("Requires audited packs (2.0.0)") }
        assertUnchanged("that refactor was such a hassle")
    }

    func testCottonNotCorrectedToKotlin() throws {
        guard Self.packsAreAudited else { throw XCTSkip("Requires audited packs (2.0.0)") }
        assertUnchanged("the cotton fabric felt soft")
    }

    func testToDoNotCorrectedToTODO() throws {
        guard Self.packsAreAudited else { throw XCTSkip("Requires audited packs (2.0.0)") }
        assertUnchanged("I have to do this before the standup")
    }

    func testInMyHumbleOpinionNotCorrectedToIMHO() throws {
        guard Self.packsAreAudited else { throw XCTSkip("Requires audited packs (2.0.0)") }
        assertUnchanged("in my humble opinion we should iterate")
    }

    // MARK: - Helper

    private func assertUnchanged(_ sentence: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard let engine = Self.builtInEngine else { return }
        let result = engine.applyCorrections(sentence, maxEditDistance: 0, usePhonetic: false)
        XCTAssertEqual(result.text, sentence,
                       "Sentence was mangled by correction engine",
                       file: file, line: line)
    }
}

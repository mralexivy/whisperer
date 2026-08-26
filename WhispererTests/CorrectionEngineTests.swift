//
//  CorrectionEngineTests.swift
//  WhispererTests
//
//  Regression coverage for the dictionary text-correction layer.
//
//  The crash these tests lock out: `applyCorrections` searched a `result.lowercased()`
//  snapshot but applied the resulting `String.Index` ranges to the live, repeatedly-mutated
//  `result`. Two independent defects in one line —
//
//    1. `lowercased()` can change a string's length (`İ` → `i` + U+0307, `ẞ` → `ß`), so the
//       snapshot's indices never described the original string to begin with.
//    2. Every `replaceSubrange` resized `result`, so any index computed before it went stale.
//
//  On the SECOND occurrence of a term whose replacement had a different length, the stale
//  index ran past the end and the app died with `Fatal error: String index range is out of
//  bounds` mid-way through a meeting retranscribe. The real dictionary entries involved were
//  `traffic → Traefik`, `Sefi → Ceph` and `Genesis → Amazon Kinesis`.
//
//  The fix routes both `replaceWord` and the multi-word phrase pass through
//  `replaceAllOccurrences(in:of:with:entry:corrections:)`, which searches the live string
//  case-insensitively and carries positions as integer offsets.
//
//  Fuzzy matching (SymSpell + phonetic) is off by default in these tests: it consults the
//  system spell checker and would make the assertions depend on machine state. The passes
//  under test — the phrase pass and the exact-match word pass — run regardless.
//

import XCTest
@testable import whisperer

final class CorrectionEngineTests: XCTestCase {

    // MARK: - Helpers

    /// Every engine ever built by this suite, kept alive for the lifetime of the test process.
    ///
    /// Not an optimization — a workaround. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes
    /// `CorrectionEngine` (and `SymSpell`, `PhoneticMatcher`) `@MainActor`, which gives them a
    /// compiler-synthesized *isolated* deinit. Deallocating any such class from inside a
    /// synchronous XCTest method aborts the test host in the concurrency runtime:
    ///
    ///     malloc: *** error for object 0x…: pointer being freed was not allocated
    ///     libswift_Concurrency  swift::TaskLocal::StopLookupScope::~StopLookupScope()
    ///     libswift_Concurrency  swift_task_deinitOnExecutorImpl(…)
    ///
    /// Reproducible on Xcode 26.6 / Swift 6.3.3 with a three-line test against an empty
    /// `@MainActor final class` — nothing to do with this file's subject. A `nonisolated`
    /// class deallocates fine. Never releasing the engines sidesteps it.
    private static var liveEngines: [CorrectionEngine] = []

    private func makeEngine(_ entries: [DictionaryEntry]) -> CorrectionEngine {
        let engine = CorrectionEngine(entries: entries)
        Self.liveEngines.append(engine)
        return engine
    }

    private func makeEngine(_ pairs: [(String, String)]) -> CorrectionEngine {
        makeEngine(pairs.map {
            DictionaryEntry(incorrectForm: $0.0, correctForm: $0.1, category: "Test", notes: "test entry")
        })
    }

    /// Exact-match only. `maxEditDistance: 0` disables SymSpell and the compound pass;
    /// `usePhonetic: false` disables the phonetic fallback.
    private func correct(_ text: String, _ pairs: [(String, String)]) -> CorrectionResult {
        makeEngine(pairs).applyCorrections(text, maxEditDistance: 0, usePhonetic: false)
    }

    private func corrected(_ text: String, _ pairs: [(String, String)]) -> String {
        correct(text, pairs).text
    }

    // MARK: - Repeated single words, all three length relationships

    /// The exact crash: a repeated term whose replacement is SHORTER than the original.
    func testRepeatedWordWithShorterReplacement() {
        XCTAssertEqual(
            corrected("We run kubernetes here and kubernetes there.", [("kubernetes", "k8s")]),
            "We run k8s here and k8s there."
        )
    }

    func testRepeatedWordWithLongerReplacement() {
        XCTAssertEqual(
            corrected("k8s is still k8s.", [("k8s", "Kubernetes")]),
            "Kubernetes is still Kubernetes."
        )
    }

    func testRepeatedWordWithSameLengthReplacement() {
        XCTAssertEqual(
            corrected("traffic and traffic", [("traffic", "Traefik")]),
            "Traefik and Traefik"
        )
    }

    // MARK: - Repeated multi-word phrases, all three length relationships

    func testRepeatedPhraseWithShorterReplacement() {
        XCTAssertEqual(
            corrected("amazon web services and amazon web services",
                      [("amazon web services", "AWS")]),
            "AWS and AWS"
        )
    }

    func testRepeatedPhraseWithLongerReplacement() {
        XCTAssertEqual(
            corrected("post gres plus post gres", [("post gres", "PostgreSQL")]),
            "PostgreSQL plus PostgreSQL"
        )
    }

    func testRepeatedPhraseWithSameLengthReplacement() {
        // "foo bar baz" and "Foo-Bar-Baz" are both 11 characters.
        XCTAssertEqual(
            corrected("foo bar baz then foo bar baz", [("foo bar baz", "Foo-Bar-Baz")]),
            "Foo-Bar-Baz then Foo-Bar-Baz"
        )
    }

    // MARK: - Many occurrences

    func testTermRepeatedManyTimesInALongParagraph() {
        let input = """
        The traffic layer went down at noon, which meant traffic could not reach the \
        staging cluster. We restarted the traffic proxy twice before anyone noticed that \
        traffic was still being dropped, and only after the third restart did traffic \
        settle. By the evening traffic looked normal again.
        """
        let expected = """
        The Traefik layer went down at noon, which meant Traefik could not reach the \
        staging cluster. We restarted the Traefik proxy twice before anyone noticed that \
        Traefik was still being dropped, and only after the third restart did Traefik \
        settle. By the evening Traefik looked normal again.
        """
        let result = correct(input, [("traffic", "Traefik")])
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.corrections.count, 6)
    }

    // MARK: - Replacement that contains the search term

    /// `gpt → GPT model`: the replacement contains the needle, so a naive re-scan can either
    /// spin forever or apply the entry twice. Runs off the test thread so a hang fails the
    /// test on the wait timeout instead of wedging the whole run.
    ///
    /// KNOWN BUG, still live as of this file's creation — the assertion below is the correct
    /// expectation and is deliberately left unweakened.
    ///
    /// `applyCorrections`' third pass builds `words` from the text as it stood *before* the
    /// pass, then calls `replaceWord` once per word — and `replaceWord` replaces *every*
    /// occurrence. For an ordinary entry the 2nd…Nth calls are harmless no-ops because the
    /// needle is gone. When the replacement contains the needle, it is not gone, so each
    /// duplicate word re-expands every occurrence:
    ///
    ///     "gpt and gpt"        →  "GPT model model and GPT model model"
    ///     "gpt gpt gpt"        →  "GPT model model model" ×3
    ///
    /// It terminates (the outer loop is bounded by the word count), so it is corruption rather
    /// than a hang, and it is independent of the index-invalidation crash this file was written
    /// for. The fix belongs in the third pass — deduplicate `words` and, more importantly, stop
    /// re-scanning the whole string once per occurrence.
    func testReplacementContainingSearchTermIsAppliedExactlyOnce() {
        let engine = makeEngine([("gpt", "GPT model")])
        let finished = expectation(description: "applyCorrections returned")
        let box = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            box.value = engine.applyCorrections("gpt and gpt", maxEditDistance: 0, usePhonetic: false).text
            finished.fulfill()
        }

        wait(for: [finished], timeout: 10)
        // Regression: an entry whose replacement contains its own search term used to be
        // re-applied once per duplicate occurrence ("GPT model model and GPT model model"),
        // because the third pass called a replace-all helper once per word in the text.
        XCTAssertEqual(box.value, "GPT model and GPT model")
    }

    /// A single occurrence must also not re-expand.
    func testSingleOccurrenceOfSelfContainingReplacement() {
        XCTAssertEqual(corrected("gpt", [("gpt", "GPT model")]), "GPT model")
    }

    // MARK: - Word boundaries

    func testWordBoundariesAreRespected() {
        let input = "cat is in the catalog, cat; concatenate cat.\ncat"
        XCTAssertEqual(
            corrected(input, [("cat", "feline")]),
            "feline is in the catalog, feline; concatenate feline.\nfeline"
        )
    }

    func testMatchAtStartAndEndOfString() {
        XCTAssertEqual(corrected("cat", [("cat", "feline")]), "feline")
        XCTAssertEqual(corrected("a cat", [("cat", "feline")]), "a feline")
        XCTAssertEqual(corrected("cat a", [("cat", "feline")]), "feline a")
    }

    func testSubstringMatchesAreNeverReplaced() {
        for text in ["catalog", "concat", "scatter", "cats", "bobcat"] {
            XCTAssertEqual(corrected(text, [("cat", "feline")]), text,
                           "'cat' must not match inside '\(text)'")
        }
    }

    // MARK: - Case

    func testMatchingIsCaseInsensitiveAndReplacementCasingIsPreserved() {
        XCTAssertEqual(
            corrected("Traffic TRAFFIC traffic TrAfFiC", [("traffic", "Traefik")]),
            "Traefik Traefik Traefik Traefik"
        )
    }

    // MARK: - Non-ASCII

    /// `İ`.lowercased() is `i` + U+0307 and `ẞ`.lowercased() is `ß` — both change the UTF-16
    /// length of the string. Searching a `lowercased()` snapshot and indexing the original
    /// with the result was the second half of the original defect.
    func testCharactersThatChangeLengthWhenLowercasedDoNotShiftMatches() {
        XCTAssertEqual(
            corrected("İstanbul ß ẞ traffic İ traffic Straße", [("traffic", "Traefik")]),
            "İstanbul ß ẞ Traefik İ Traefik Straße"
        )
    }

    func testTurkishAndGermanTextIsNotMangled() {
        let input = "İzmir ẞ ß Grüße"
        XCTAssertEqual(corrected(input, [("traffic", "Traefik")]), input)
    }

    /// Non-Latin scripts deliberately skip fuzzy matching, so they must survive the full
    /// pipeline — fuzzy and phonetic enabled — byte-for-byte.
    func testHebrewAndRussianPassThroughUnmangled() {
        let engine = makeEngine([
            ("traffic", "Traefik"),
            ("sefi", "Ceph"),
            ("genesis", "Amazon Kinesis")
        ])
        let hebrew = "אנחנו צריכים להריץ את זה שוב כי השרת נפל"
        let russian = "нам нужно перезапустить сервис сегодня вечером"

        XCTAssertEqual(engine.applyCorrections(hebrew).text, hebrew)
        XCTAssertEqual(engine.applyCorrections(russian).text, russian)
    }

    // MARK: - Grapheme clusters

    /// Positions are carried as Character offsets, so emoji and combining marks — which occupy
    /// several UTF-16 code units per Character — must not shift a match.
    func testEmojiAndCombiningMarksAroundAMatch() {
        XCTAssertEqual(
            corrected("🎉 traffic 🎉 and 👨‍👩‍👧‍👦 traffic e\u{301}", [("traffic", "Traefik")]),
            "🎉 Traefik 🎉 and 👨‍👩‍👧‍👦 Traefik e\u{301}"
        )
    }

    func testCorrectionRangesSurviveEmojiInTheInput() {
        let result = correct("🇮🇱 traffic 🇮🇱 traffic", [("traffic", "Traefik")])
        XCTAssertEqual(result.text, "🇮🇱 Traefik 🇮🇱 Traefik")
        assertRangesAreValid(in: result)
    }

    // MARK: - Degenerate inputs

    func testEmptyInput() {
        let result = correct("", [("traffic", "Traefik")])
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.corrections.isEmpty)
    }

    func testWhitespaceOnlyInput() {
        for text in ["   ", "\n", "\t \n  "] {
            let result = correct(text, [("traffic", "Traefik")])
            XCTAssertEqual(result.text, text)
            XCTAssertTrue(result.corrections.isEmpty)
        }
    }

    func testSingleCharacterInput() {
        XCTAssertEqual(corrected("a", [("a", "A")]), "A")
        XCTAssertEqual(corrected("a", [("traffic", "Traefik")]), "a")
        XCTAssertEqual(corrected(".", [("traffic", "Traefik")]), ".")
    }

    func testEmptyDictionary() {
        let engine = makeEngine([DictionaryEntry]())
        let input = "traffic went through Sefi and Genesis"
        let result = engine.applyCorrections(input, maxEditDistance: 0, usePhonetic: false)
        XCTAssertEqual(result.text, input)
        XCTAssertTrue(result.corrections.isEmpty)
    }

    func testDisabledEntriesAreIgnored() {
        let engine = makeEngine([
            DictionaryEntry(incorrectForm: "traffic", correctForm: "Traefik", isEnabled: false)
        ])
        XCTAssertEqual(engine.applyCorrections("traffic and traffic",
                                               maxEditDistance: 0,
                                               usePhonetic: false).text,
                       "traffic and traffic")
    }

    // MARK: - The reported corrections array

    /// The pre-fix code recorded ranges taken from a stale, pre-mutation string. Every reported
    /// range must now be in bounds of the returned text AND slice to the replacement.
    func testReportedCorrectionsAreAccurate() {
        let result = correct("traffic here and traffic there", [("traffic", "Traefik")])

        XCTAssertEqual(result.text, "Traefik here and Traefik there")
        XCTAssertEqual(result.corrections.count, 2)
        for correction in result.corrections {
            XCTAssertEqual(correction.original, "traffic")
            XCTAssertEqual(correction.replacement, "Traefik")
            XCTAssertEqual(correction.category, "Test")
            XCTAssertEqual(correction.notes, "test entry")
        }
        assertRangesAreValid(in: result)
    }

    func testReportedCorrectionsWithLengthChangingReplacement() {
        let result = correct("kubernetes, kubernetes, kubernetes", [("kubernetes", "k8s")])

        XCTAssertEqual(result.text, "k8s, k8s, k8s")
        XCTAssertEqual(result.corrections.count, 3)
        assertRangesAreValid(in: result)
    }

    func testReportedCorrectionsPreserveTheMatchedCasingAsOriginal() {
        let result = correct("Traffic then TRAFFIC", [("traffic", "Traefik")])
        XCTAssertEqual(result.corrections.map(\.original), ["Traffic", "TRAFFIC"])
        XCTAssertEqual(result.corrections.map(\.replacement), ["Traefik", "Traefik"])
        assertRangesAreValid(in: result)
    }

    /// A replacement identical to the matched text is not a correction.
    func testNoOpReplacementIsNotReported() {
        let result = correct("Traefik and Traefik", [("traefik", "Traefik")])
        XCTAssertEqual(result.text, "Traefik and Traefik")
        XCTAssertTrue(result.corrections.isEmpty)
    }

    // MARK: - The production crash, reproduced

    /// The three real dictionary entries from the crashing meeting retranscribe, each term
    /// appearing more than once in one paragraph.
    func testProductionCrashEntriesOnARepeatingParagraph() {
        let entries = [
            ("traffic", "Traefik"),          // same length
            ("Sefi", "Ceph"),                // same length
            ("Genesis", "Amazon Kinesis")    // longer
        ]
        let input = """
        The traffic router died, so traffic went nowhere. Sefi rebalanced, then Sefi paged \
        me. Genesis dropped events and Genesis retried, while traffic recovered.
        """
        let expected = """
        The Traefik router died, so Traefik went nowhere. Ceph rebalanced, then Ceph paged \
        me. Amazon Kinesis dropped events and Amazon Kinesis retried, while Traefik recovered.
        """

        let result = correct(input, entries)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.corrections.count, 7)
        XCTAssertEqual(result.corrections.filter { $0.replacement == "Traefik" }.count, 3)
        XCTAssertEqual(result.corrections.filter { $0.replacement == "Ceph" }.count, 2)
        XCTAssertEqual(result.corrections.filter { $0.replacement == "Amazon Kinesis" }.count, 2)
        // Ranges from earlier entries shift when a later, longer entry is applied, so only
        // in-bounds-ness is guaranteed across a multi-entry dictionary.
        for correction in result.corrections {
            XCTAssertTrue(correction.range.lowerBound >= result.text.startIndex)
            XCTAssertTrue(correction.range.upperBound <= result.text.endIndex)
        }
    }

    /// Same paragraph through the default pipeline (SymSpell + phonetic on), which is what
    /// the retranscribe path actually calls.
    func testProductionCrashEntriesThroughTheDefaultPipeline() {
        let engine = makeEngine([
            ("traffic", "Traefik"),
            ("Sefi", "Ceph"),
            ("Genesis", "Amazon Kinesis")
        ])
        let input = """
        The traffic router died, so traffic went nowhere. Sefi rebalanced, then Sefi paged \
        me. Genesis dropped events and Genesis retried, while traffic recovered.
        """

        let output = engine.applyCorrections(input).text

        XCTAssertTrue(output.contains("Traefik"), output)
        XCTAssertTrue(output.contains("Ceph"), output)
        XCTAssertTrue(output.contains("Amazon Kinesis"), output)
        XCTAssertFalse(output.contains("traffic"), output)
    }

    // MARK: - Assertions

    private func assertRangesAreValid(in result: CorrectionResult,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        for correction in result.corrections {
            XCTAssertTrue(correction.range.lowerBound >= result.text.startIndex,
                          "range starts before the text", file: file, line: line)
            XCTAssertTrue(correction.range.upperBound <= result.text.endIndex,
                          "range runs past the end of the text", file: file, line: line)
            XCTAssertEqual(String(result.text[correction.range]), correction.replacement,
                           "range does not slice to the replacement", file: file, line: line)
        }
    }
}

/// Carries a value out of a background dispatch without a captured `var`.
private nonisolated final class ResultBox: @unchecked Sendable {
    var value = ""
}

//
//  TranscriptSearchTests.swift
//  WhispererTests
//
//  Unit tests for TranscriptSearch (pure scan / match logic).
//  All tests are synchronous and allocation-free — no model loading, no AppKit layout.
//

import XCTest
@testable import whisperer

final class TranscriptSearchTests: XCTestCase {

    // MARK: - Helpers

    private func ranges(in text: String, query: String) -> [NSRange] {
        TranscriptSearch.findMatches(in: text, query: query).map(\.range)
    }

    // MARK: - Minimum length guard

    func testEmptyQueryReturnsNoMatches() {
        XCTAssertTrue(ranges(in: "hello world", query: "").isEmpty)
    }

    func testSingleCharQueryReturnsNoMatches() {
        XCTAssertTrue(ranges(in: "hello world", query: "a").isEmpty)
    }

    func testTwoCharQueryIsMinimum() {
        let r = ranges(in: "hello world", query: "wo")
        XCTAssertEqual(r.count, 1)
    }

    // MARK: - Basic matching

    func testSingleMatch() {
        let r = ranges(in: "The quick brown fox", query: "quick")
        XCTAssertEqual(r.count, 1)
    }

    func testMultipleMatches() {
        let r = ranges(in: "aababc", query: "ab")
        XCTAssertEqual(r.count, 2)
    }

    func testDocumentOrder() {
        let text = "cat bat sat"
        let r = ranges(in: text, query: "at")
        XCTAssertEqual(r.count, 3)
        // Verify ascending location
        for i in 1..<r.count {
            XCTAssertGreaterThan(r[i].location, r[i-1].location)
        }
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(ranges(in: "hello world", query: "xyz").isEmpty)
    }

    // MARK: - Non-overlapping guarantee

    func testNonOverlappingMatchesInRepeatedSequence() {
        // "aa" in "aaaa" must return 2, not 3
        let r = ranges(in: "aaaa", query: "aa")
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].location, 0)
        XCTAssertEqual(r[1].location, 2)
    }

    // MARK: - Case insensitivity

    func testCaseInsensitiveMatch() {
        let r = ranges(in: "Hello HELLO hello", query: "hello")
        XCTAssertEqual(r.count, 3)
    }

    func testMixedCaseQuery() {
        let r = ranges(in: "inference", query: "INFERENCE")
        XCTAssertEqual(r.count, 1)
    }

    // MARK: - Diacritic insensitivity

    func testAccentedLatinMatches() {
        // é and e should match
        let r = ranges(in: "café resume", query: "cafe")
        XCTAssertEqual(r.count, 1)
    }

    func testHebrewWithNiqqudMatchesWithout() {
        // שָׁלוֹם (shalom with niqqud) should match שלום (without niqqud)
        let text = "שָׁלוֹם עוֹלָם"
        let query = "שלום"
        let r = ranges(in: text, query: query)
        XCTAssertEqual(r.count, 1, "Niqqud-bearing text should match plain Hebrew query")
    }

    // MARK: - Ordinals

    func testMatchIDsAreSequential() {
        let matches = TranscriptSearch.findMatches(in: "abc abc abc", query: "ab")
        XCTAssertEqual(matches.map(\.id), [0, 1, 2])
    }

    // MARK: - Large document performance

    func testLargeDocumentScanSpeed() {
        // 200 k characters: must complete in under 500 ms (generous; real scans are ~20 ms)
        let word = "whisper "
        let text = String(repeating: word, count: 25_000)  // 200 k chars
        let start = Date()
        let r = TranscriptSearch.findMatches(in: text, query: "wh")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(r.count, 0)
        XCTAssertLessThan(elapsed, 0.5, "Scan of 200 k chars exceeded 500 ms (was \(elapsed) s)")
    }

    // MARK: - maxDecorated cap

    func testMatchCountExceedsMaxDecorated() {
        // Build text with more than maxDecorated matches — count must be exact
        let n = TranscriptSearch.maxDecorated + 100
        let text = String(repeating: "ab ", count: n)
        let matches = TranscriptSearch.findMatches(in: text, query: "ab")
        XCTAssertEqual(matches.count, n, "Total match count must be exact regardless of cap")
    }

    // MARK: - TranscriptSearchModel navigation (must be kept alive for the process)

    // NOTE: TranscriptSearchModel has @MainActor deinit (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor).
    // Per CLAUDE.md, test-built @MainActor objects must be kept alive for the process to avoid
    // `pointer being freed was not allocated` aborts. We pin the model to a static slot.

    private nonisolated(unsafe) static var liveModel: TranscriptSearchModel?

    @MainActor
    func testNavigationWrapsAround() async throws {
        let model = TranscriptSearchModel()
        Self.liveModel = model  // keep alive

        // Inject matches directly without going through the scan path
        model.report(
            located: (0..<3).map { TranscriptMatch(id: $0, range: NSRange(location: $0 * 5, length: 2)) },
            contentHeight: 300)

        XCTAssertEqual(model.currentIndex, 0)

        model.next()
        XCTAssertEqual(model.currentIndex, 1)

        model.next()
        XCTAssertEqual(model.currentIndex, 2)

        // Wrap to 0
        model.next()
        XCTAssertEqual(model.currentIndex, 0)

        // Wrap from 0 to last
        model.previous()
        XCTAssertEqual(model.currentIndex, 2)
    }

    @MainActor
    func testClearResetsState() async throws {
        let model = TranscriptSearchModel()
        Self.liveModel = model

        model.report(
            located: [TranscriptMatch(id: 0, range: NSRange(location: 0, length: 3))],
            contentHeight: 100)

        model.clear()

        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertEqual(model.totalMatches, 0)
        XCTAssertNil(model.currentIndex)
        XCTAssertTrue(model.query.isEmpty)
    }

    @MainActor
    func testNoMatchesClearsCurrentIndex() async throws {
        let model = TranscriptSearchModel()
        Self.liveModel = model

        // Seed a match
        model.report(
            located: [TranscriptMatch(id: 0, range: NSRange(location: 0, length: 2))],
            contentHeight: 100)
        XCTAssertNotNil(model.currentIndex)

        // Push empty result
        model.report(located: [], contentHeight: 100)
        XCTAssertNil(model.currentIndex)
        XCTAssertEqual(model.totalMatches, 0)
    }
}

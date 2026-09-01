//
//  CorrectionLearningTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class CorrectionLearningCandidateExtractorTests: XCTestCase {
    func testExtractsIsolatedSubstitution() {
        XCTAssertEqual(
            CorrectionLearningCandidateExtractor.extract(
                from: "Open Glyn and show the dashboard",
                edited: "Open Glean and show the dashboard"
            ),
            [.init(observed: "Glyn", corrected: "Glean")]
        )
    }

    func testRejectsCasePunctuationInsertionDeletionPhraseAndScriptChanges() {
        XCTAssertTrue(CorrectionLearningCandidateExtractor.extract(from: "open glean", edited: "Open Glean.").isEmpty)
        XCTAssertTrue(CorrectionLearningCandidateExtractor.extract(from: "open dashboard", edited: "open the dashboard").isEmpty)
        XCTAssertTrue(CorrectionLearningCandidateExtractor.extract(from: "open the dashboard", edited: "open dashboard").isEmpty)
        XCTAssertTrue(CorrectionLearningCandidateExtractor.extract(from: "open old thing", edited: "open brand new thing").isEmpty)
        XCTAssertTrue(CorrectionLearningCandidateExtractor.extract(from: "open test now", edited: "open בדיקה now").isEmpty)
    }

    func testCapsCandidatesAtFour() {
        let result = CorrectionLearningCandidateExtractor.extract(
            from: "aa one bb two cc three dd four ee five",
            edited: "zz one yy two xx three ww four vv five"
        )
        XCTAssertEqual(result.count, 4)
    }

    func testRejectsUnboundedRegions() {
        let oversized = String(repeating: "word ", count: CorrectionLearningCandidateExtractor.maximumTokens + 1)
        XCTAssertTrue(CorrectionLearningCandidateExtractor.extract(from: oversized, edited: oversized + "edit").isEmpty)
    }
}

final class CorrectionLearningAnchorTests: XCTestCase {
    func testExtractsOnlyTheOriginalSelectionRegion() throws {
        let anchor = try XCTUnwrap(CorrectionLearningAnchor(
            fieldValue: "hello OLD world",
            selectedRange: NSRange(location: 6, length: 3)
        ))
        XCTAssertEqual(anchor.region(in: "hello Glean world"), "Glean")
    }

    func testRejectsAnyChangeOutsideTheRegion() throws {
        let anchor = try XCTUnwrap(CorrectionLearningAnchor(
            fieldValue: "hello OLD world",
            selectedRange: NSRange(location: 6, length: 3)
        ))
        XCTAssertNil(anchor.region(in: "Hello Glean world"))
        XCTAssertNil(anchor.region(in: "hello Glean worlds"))
    }
}

final class CorrectionSuggestionStoreTests: XCTestCase {
    /// Suggestions are offered on first sighting. There is no repeat threshold: replaying the
    /// miner over 1,779 real dictations found zero candidate pairs recurring even twice, so a
    /// "seen N times" gate would never have fired. `sightings` is context, not a gate.
    func testDedupesOnThePairAndSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("suggestions.json")
        let store = CorrectionSuggestionStore(fileURL: url)

        await store.record("Glyn", "Glean")
        var stored = await store.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.sightings, 1)

        await store.record("glyn", "glean")
        stored = await store.all()
        XCTAssertEqual(stored.count, 1, "the same pair in different casing is one suggestion")
        XCTAssertEqual(stored.first?.sightings, 2)

        let reloaded = CorrectionSuggestionStore(fileURL: url)
        stored = await reloaded.all()
        XCTAssertEqual(stored.first?.sightings, 2)

        if let id = stored.first?.id {
            await reloaded.remove(id: id)
        }
        stored = await reloaded.all()
        XCTAssertTrue(stored.isEmpty)

        await reloaded.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

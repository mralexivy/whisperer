//
//  SpeakerRenameTests.swift
//  WhispererTests
//
//  Tests for SpeakerNaming and Array<MeetingSegment>.renameSpeaker.
//  Pure value-type tests — no @MainActor class instances to avoid the
//  synthesized-isolated-deinit abort (see CLAUDE.md).
//

import XCTest
@testable import whisperer

final class SpeakerRenameTests: XCTestCase {

    // MARK: - SpeakerNaming.normalized

    func testNormalizedTrimming() {
        XCTAssertEqual(SpeakerNaming.normalized("  Adar  "), "adar")
    }

    func testNormalizedCaseFold() {
        XCTAssertEqual(SpeakerNaming.normalized("ADAR"), SpeakerNaming.normalized("adar"))
    }

    func testNormalizedDiacriticFold() {
        // é and e should fold to the same string
        XCTAssertEqual(SpeakerNaming.normalized("René"), SpeakerNaming.normalized("Rene"))
    }

    // MARK: - SpeakerNaming.conflictingName

    private let roster: [(index: Int, name: String)] = [
        (index: 0, name: "Adar"),
        (index: 1, name: "Speaker 2"),
    ]

    func testConflict_selfRenameAllowed() {
        // Renaming speaker 0 to its own name (any casing) must not be a conflict.
        XCTAssertNil(SpeakerNaming.conflictingName(for: "Adar",
                                                   in: roster,
                                                   excluding: 0))
        XCTAssertNil(SpeakerNaming.conflictingName(for: "adar",
                                                   in: roster,
                                                   excluding: 0))
        XCTAssertNil(SpeakerNaming.conflictingName(for: " ADAR ",
                                                   in: roster,
                                                   excluding: 0))
    }

    func testConflict_duplicateBlocked() {
        // Renaming speaker 1 to "Adar" (already held by speaker 0) is a conflict.
        let conflict = SpeakerNaming.conflictingName(for: "Adar",
                                                     in: roster,
                                                     excluding: 1)
        XCTAssertEqual(conflict, "Adar")
    }

    func testConflict_caseInsensitiveBlocked() {
        let conflict = SpeakerNaming.conflictingName(for: "adar",
                                                     in: roster,
                                                     excluding: 1)
        XCTAssertNotNil(conflict)
    }

    func testConflict_freeName() {
        XCTAssertNil(SpeakerNaming.conflictingName(for: "Alice",
                                                   in: roster,
                                                   excluding: 1))
    }

    func testConflict_emptyNameIsNil() {
        XCTAssertNil(SpeakerNaming.conflictingName(for: "",
                                                   in: roster,
                                                   excluding: 1))
        XCTAssertNil(SpeakerNaming.conflictingName(for: "   ",
                                                   in: roster,
                                                   excluding: 1))
    }

    // MARK: - SpeakerNaming.duplicateIndices

    func testDuplicateIndices_noDuplicates() {
        let clean: [(index: Int, name: String)] = [(0, "Alice"), (1, "Bob")]
        XCTAssertTrue(SpeakerNaming.duplicateIndices(in: clean).isEmpty)
    }

    func testDuplicateIndices_exactDuplicate() {
        let duped: [(index: Int, name: String)] = [(0, "Adar"), (1, "Adar"), (2, "Bob")]
        let result = SpeakerNaming.duplicateIndices(in: duped)
        XCTAssertEqual(result, [0, 1])
    }

    func testDuplicateIndices_caseInsensitiveDuplicate() {
        let duped: [(index: Int, name: String)] = [(0, "Adar"), (1, "adar")]
        let result = SpeakerNaming.duplicateIndices(in: duped)
        XCTAssertEqual(result, [0, 1])
    }

    // MARK: - Array<MeetingSegment>.renameSpeaker(index:to:)

    func testRenameSpeaker_renamesOnlyMatchingIndex() {
        var segments: [MeetingSegment] = [
            MeetingSegment(timestamp: 0, endTimestamp: 5, text: "Hello",
                           speakerName: "Adar", speakerIndex: 0),
            MeetingSegment(timestamp: 5, endTimestamp: 10, text: "World",
                           speakerName: "Adar", speakerIndex: 1),  // same name, different index
            MeetingSegment(timestamp: 10, endTimestamp: 15, text: "More",
                           speakerName: "Adar", speakerIndex: 0),
        ]

        // Rename only index 0.
        segments.renameSpeaker(index: 0, to: "Adar Levi")

        XCTAssertEqual(segments[0].speakerName, "Adar Levi")
        XCTAssertEqual(segments[1].speakerName, "Adar",      // index 1 unchanged
                       "renameSpeaker must not touch segments of a different speakerIndex")
        XCTAssertEqual(segments[2].speakerName, "Adar Levi")
    }

    func testRenameSpeaker_noMatchIsNoop() {
        var segments: [MeetingSegment] = [
            MeetingSegment(timestamp: 0, endTimestamp: 5, text: "Hi",
                           speakerName: "Adar", speakerIndex: 0),
        ]
        segments.renameSpeaker(index: 99, to: "Ghost")
        XCTAssertEqual(segments[0].speakerName, "Adar")
    }
}

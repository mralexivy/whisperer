//
//  MeetingAudioLocationTests.swift
//  WhispererTests
//
//  Old meeting rows keep whatever their build stored. The lookup must find each kind without
//  moving a file: a bare name in Meetings/ or Sessions/, an absolute path, a file:// URL, and a
//  pre-Opus extension.
//

import XCTest
@testable import whisperer

final class MeetingAudioLocationTests: XCTestCase {

    private var created: [URL] = []

    override func tearDown() {
        created.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func make(_ folder: String, _ name: String) throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data([0]).write(to: url)
        created.append(url)
        return url
    }

    func testBareNameInMeetings() throws {
        let name = "test-\(UUID().uuidString).opus"
        let url = try make("Meetings", name)
        XCTAssertEqual(MeetingManager.locateAudio(storedName: name)?.path, url.path)
    }

    func testBareNameStillInSessions() throws {
        let name = "test-\(UUID().uuidString).opus"
        let url = try make("Sessions", name)
        XCTAssertEqual(MeetingManager.locateAudio(storedName: name)?.path, url.path)
    }

    func testAbsolutePathAndFileURL() throws {
        let url = try make("Meetings", "test-\(UUID().uuidString).caf")
        XCTAssertEqual(MeetingManager.locateAudio(storedName: url.path)?.path, url.path)
        XCTAssertEqual(MeetingManager.locateAudio(storedName: url.absoluteString)?.path, url.path)
    }

    func testStaleAbsolutePathFallsBackToTheName() throws {
        let name = "test-\(UUID().uuidString).opus"
        let url = try make("Meetings", name)
        XCTAssertEqual(MeetingManager.locateAudio(storedName: "/Users/someone-else/Library/Whisperer/Meetings/\(name)")?.path, url.path)
    }

    func testPreOpusExtension() throws {
        let base = "test-\(UUID().uuidString)"
        let url = try make("Meetings", "\(base).caf")
        XCTAssertEqual(MeetingManager.locateAudio(storedName: "\(base).opus")?.path, url.path)
    }

    func testNewLayoutIsFoundFirst() throws {
        let name = "test-\(UUID().uuidString).opus"
        let old = try make("Meetings", name)
        let new = try make("Recordings/Meetings", name)
        XCTAssertEqual(MeetingManager.locateAudio(storedName: name)?.path, new.path)
        _ = old
    }

    /// A file an older build left in Sessions/ moves into Recordings/Meetings/ once; a second
    /// adopt is a no-op, and nothing at the destination is ever overwritten.
    func testAdoptMovesOnceAndNeverOverwrites() throws {
        let name = "test-\(UUID().uuidString).opus"
        let source = try make("Sessions", name)
        let dest = AudioLibraryPaths.meetingRecordings.appendingPathComponent(name)
        created.append(dest)
        XCTAssertTrue(MeetingManager.adoptSessionAudio(fileName: name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(MeetingManager.adoptSessionAudio(fileName: name), "idempotent")

        let other = "test-\(UUID().uuidString).opus"
        let inSessions = try make("Sessions", other)
        let occupied = try make("Recordings/Meetings", other)
        try Data([1, 2, 3]).write(to: occupied)
        XCTAssertTrue(MeetingManager.adoptSessionAudio(fileName: other))
        XCTAssertEqual(try Data(contentsOf: occupied), Data([1, 2, 3]), "the destination is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inSessions.path), "the source is not deleted")
    }

    func testMissingIsNil() {
        XCTAssertNil(MeetingManager.locateAudio(storedName: "nope-\(UUID().uuidString).opus"))
        XCTAssertNil(MeetingManager.locateAudio(storedName: ""))
    }
}

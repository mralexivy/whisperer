//
//  MeetingAudioDurabilityTests.swift
//  WhispererTests
//
//  A meeting's recording is never lost: the row names its file from the first second, the file
//  is found while it is still in Sessions/, and whatever ends the meeting moves it to Meetings/
//  (Sessions/ is swept after 7 days).
//

import XCTest
@testable import whisperer

final class MeetingAudioDurabilityTests: XCTestCase {

    private let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private var testFile = ""

    override func setUp() {
        testFile = "durability-test-\(UUID().uuidString).opus"
        let sessions = appSupport.appendingPathComponent("Whisperer/Sessions")
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sessions.appendingPathComponent(testFile).path, contents: Data([1, 2, 3]))
    }

    override func tearDown() {
        for dir in ["Sessions", "Meetings"] {
            try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("Whisperer/\(dir)/\(testFile)"))
        }
    }

    func testRecordingInProgressIsFoundInSessions() {
        let url = MeetingManager.audioURL(forFileName: testFile)
        XCTAssertTrue(url.path.contains("/Whisperer/Sessions/"), url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAdoptMovesTheRecordingToMeetings() {
        XCTAssertTrue(MeetingManager.adoptSessionAudio(fileName: testFile))
        let url = MeetingManager.audioURL(forFileName: testFile)
        XCTAssertTrue(url.path.contains("/Whisperer/Meetings/"), url.path)
        XCTAssertEqual(FileManager.default.contents(atPath: url.path), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("Whisperer/Sessions/\(testFile)").path))
        XCTAssertTrue(MeetingManager.adoptSessionAudio(fileName: testFile), "adopting twice is harmless")
    }
}

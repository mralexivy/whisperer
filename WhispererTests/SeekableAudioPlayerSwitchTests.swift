//
//  SeekableAudioPlayerSwitchTests.swift
//  WhispererTests
//
//  Opening another meeting must show that meeting's recording. The meeting screen loaded audio
//  only while nothing was loaded, and `stop()` keeps the file, so a 54-minute meeting showed the
//  previously opened meeting's 1:28 recording (2026-11-09).
//

import XCTest
@testable import whisperer

@MainActor
final class SeekableAudioPlayerSwitchTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private static let testData = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("TestData")

    private func waitLoaded(_ player: SeekableAudioPlayer, _ url: URL) {
        let until = Date().addingTimeInterval(5)
        while player.loadedURL != url, Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    func testSwitchingMeetingsShowsTheNewRecording() throws {
        let short = Self.testData.appendingPathComponent("hebrew_sample.wav")
        let long = Self.testData.appendingPathComponent("test-sentences-en.wav")
        let player = SeekableAudioPlayer()
        Self.keepAlive.append(player)

        player.show(url: short)
        waitLoaded(player, short)
        let shortDuration = player.duration
        XCTAssertGreaterThan(shortDuration, 0)

        // The meeting screen on a selection change: unload, then show the new meeting's file.
        player.unload()
        XCTAssertEqual(player.duration, 0)
        player.show(url: long)
        waitLoaded(player, long)
        XCTAssertEqual(player.loadedURL, long)
        XCTAssertNotEqual(player.duration, shortDuration, accuracy: 0.01)
    }

    /// A slow load that finishes after the user moved on must not replace the newer file.
    func testStaleLoadDoesNotLandOverTheNewerOne() throws {
        let first = Self.testData.appendingPathComponent("test-sentences-en.wav")
        let second = Self.testData.appendingPathComponent("hebrew_sample.wav")
        let player = SeekableAudioPlayer()
        Self.keepAlive.append(player)

        player.show(url: first)
        player.show(url: second)
        waitLoaded(player, second)
        let until = Date().addingTimeInterval(0.5)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(player.loadedURL, second)
    }
}

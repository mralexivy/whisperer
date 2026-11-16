//
//  RecordingPlaybackControllerTests.swift
//  WhispererTests
//
//  One playback session for the workspace: availability states, a single audio source, position that
//  survives re-selection of the same recording, and seek / reveal behaviour for timed and untimed text.
//

import AVFoundation
import XCTest
@testable import whisperer

@MainActor
final class RecordingPlaybackControllerTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func makeWAV(seconds: Double = 3) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    private func document(audio: URL?, audioName: String? = nil, timed: Bool = true, id: UUID = UUID()) -> TranscriptDocument {
        let stored = timed
            ? [StoredParagraph(text: "First paragraph of text here.", start: 0, end: 1),
               StoredParagraph(text: "Second paragraph of text here.", start: 1, end: 2),
               StoredParagraph(text: "Third paragraph of text here.", start: 2, end: 3)]
            : nil
        let text = "First paragraph of text here. Second paragraph of text here. Third paragraph of text here."
        var record = TranscriptionRecord(
            id: id, transcription: text, audioFileURL: audioName, duration: 3, language: "en", modelUsed: "m",
            targetAppName: "File Import", sourceKind: "file", sourceFileName: "a.wav",
            paragraphsJSON: stored.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) })
        var doc = TranscriptDocument(transcription: record)
        doc.audioURL = audio
        doc.audioIsMissing = audio == nil && audioName != nil
        record.notes = nil
        return doc
    }

    private func controller() -> RecordingPlaybackController {
        let c = RecordingPlaybackController()
        Self.keepAlive.append(c)
        return c
    }

    private func settle(_ c: RecordingPlaybackController, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while Date() < end, !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testAvailabilityStatesAreExplicitAndControlsDoNothingWithoutAudio() {
        let c = controller()
        XCTAssertEqual(c.availability, .none)
        c.select(document(audio: nil))
        XCTAssertEqual(c.availability, .noAudio)
        c.select(document(audio: nil, audioName: "gone.opus"))
        XCTAssertEqual(c.availability, .missing)
        c.togglePlay(); c.seek(to: 5)
        XCTAssertFalse(c.player.isPlaying)
        XCTAssertEqual(c.player.currentTime, 0)
    }

    func testSameRecordingKeepsItsPositionAcrossRebuildsAndAnotherRecordingResetsIt() throws {
        let url = try makeWAV()
        let c = controller()
        let id = UUID()
        let doc = document(audio: url, audioName: url.lastPathComponent, id: id)
        c.select(doc)
        settle(c) { c.player.loadedURL == url && !c.player.isLoading }
        XCTAssertEqual(c.availability, .ready)
        c.seek(to: 1.5)
        XCTAssertEqual(c.player.currentTime, 1.5, accuracy: 0.05)

        // The document is rebuilt (an edit, a title change, a layout change): same session, same position.
        var rebuilt = document(audio: url, audioName: url.lastPathComponent, id: id)
        rebuilt.title = "Renamed"
        c.select(rebuilt)
        XCTAssertEqual(c.player.currentTime, 1.5, accuracy: 0.05)

        // A different recording replaces it: nothing from the old one keeps playing and position restarts.
        let other = try makeWAV()
        c.select(document(audio: other, audioName: other.lastPathComponent))
        settle(c) { c.player.loadedURL == other }
        XCTAssertEqual(c.player.loadedURL, other)
        XCTAssertFalse(c.player.isPlaying)
        XCTAssertEqual(c.player.currentTime, 0, accuracy: 0.05)
    }

    func testSeekWhilePausedMovesThePlayheadParagraph() throws {
        let url = try makeWAV()
        let c = controller()
        c.select(document(audio: url, audioName: url.lastPathComponent))
        settle(c) { c.player.loadedURL == url && !c.player.isLoading }
        XCTAssertNil(c.playheadParagraphID)
        c.seek(to: 1.4)
        settle(c) { c.playheadParagraphID != nil }
        let doc = document(audio: url, audioName: url.lastPathComponent)
        XCTAssertFalse(c.player.isPlaying)
        XCTAssertNotNil(c.playheadParagraphID)
        XCTAssertTrue(c.playheadParagraphID?.hasSuffix("-p1") == true, "1.4 s is inside the second paragraph, got \(c.playheadParagraphID ?? "nil") of \(doc.paragraphs.map(\.id))")
    }

    func testCitationOpensUntimedParagraphWithoutInventingATime() throws {
        let url = try makeWAV()
        let c = controller()
        let doc = document(audio: url, audioName: url.lastPathComponent, timed: false)
        c.select(doc)
        settle(c) { c.player.loadedURL == url && !c.player.isLoading }
        let paragraph = try XCTUnwrap(doc.paragraphs.first)
        XCTAssertNil(paragraph.start)
        let before = c.revealed?.token ?? 0
        c.open(citation: paragraph)
        XCTAssertEqual(c.revealed?.paragraphID, paragraph.id)
        XCTAssertEqual(c.revealed?.token, before + 1)
        XCTAssertEqual(c.player.currentTime, 0, "an untimed passage is revealed, not seeked")
    }

    func testCitationOnTimedParagraphSeeks() throws {
        let url = try makeWAV()
        let c = controller()
        let doc = document(audio: url, audioName: url.lastPathComponent)
        c.select(doc)
        settle(c) { c.player.loadedURL == url && !c.player.isLoading }
        c.open(citation: doc.paragraphs[2])
        XCTAssertEqual(c.player.currentTime, 2, accuracy: 0.05)
        XCTAssertEqual(c.revealed?.paragraphID, doc.paragraphs[2].id)
    }

    func testClearingTheSelectionUnloadsTheAudio() throws {
        let url = try makeWAV()
        let c = controller()
        c.select(document(audio: url, audioName: url.lastPathComponent))
        settle(c) { c.player.loadedURL == url && !c.player.isLoading }
        c.select(nil)
        XCTAssertEqual(c.availability, .none)
        XCTAssertNil(c.player.loadedURL)
        XCTAssertFalse(c.player.isPlaying)
    }
}

final class RecordingSidebarPolicyTests: XCTestCase {
    func testTabsAndDefaultsPerKind() {
        XCTAssertEqual(RecordingSidebarPolicy.tabs(for: .dictation), [.details, .askAI])
        XCTAssertEqual(RecordingSidebarPolicy.defaultTab(for: .dictation), .details)
        XCTAssertEqual(RecordingSidebarPolicy.tabs(for: .meeting), [.askAI, .notes, .people])
        XCTAssertEqual(RecordingSidebarPolicy.tabs(for: .file), [.askAI, .notes])
    }

    func testDictationHasNoNotesTabAndOthersNeverGetDetails() {
        XCTAssertFalse(RecordingSidebarPolicy.tabs(for: .dictation).contains(.notes))
        XCTAssertFalse(RecordingSidebarPolicy.tabs(for: .meeting).contains(.details))
        XCTAssertFalse(RecordingSidebarPolicy.tabs(for: .file).contains(.people))
    }
}

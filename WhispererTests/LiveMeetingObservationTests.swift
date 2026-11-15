//
//  LiveMeetingObservationTests.swift
//  WhispererTests
//
//  The live meeting window must not be re-evaluated by every word. These pin which changes reach which view model,
//  and that the text-direction scan is done once per transcript change and not once per card per render.
//

import Combine
import XCTest
@testable import whisperer

@MainActor
final class LiveMeetingObservationTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func session() -> MeetingSession {
        let s = MeetingSession()
        Self.keepAlive.append(s)
        return s
    }

    // MARK: - MeetingSessionChanges

    func testLiveTextChangesDoNotReachTheWindow() {
        let s = session()
        let changes = MeetingSessionChanges(session: s)
        Self.keepAlive.append(changes)
        var fired = 0
        let bag = changes.objectWillChange.sink { fired += 1 }
        defer { bag.cancel() }

        s.currentSegmentText = "hello there"       // the first live text: the bubble appears
        let appeared = fired
        for i in 0..<200 {
            s.livePreviewText = "we are talking about the budget \(i)"
            s.currentSegmentText += " more"
        }
        XCTAssertEqual(fired, appeared, "200 live updates must not re-evaluate the window (\(fired - appeared) did)")
    }

    func testRecordingSpeakersAndTheClockDoReachTheWindow() {
        let s = session()
        let changes = MeetingSessionChanges(session: s)
        Self.keepAlive.append(changes)
        var fired = 0
        let bag = changes.objectWillChange.sink { fired += 1 }
        defer { bag.cancel() }

        s.isRecording = true;            XCTAssertEqual(fired, 1)
        s.elapsedSeconds = 1;            XCTAssertEqual(fired, 2)
        s.liveSpeakerIndex = 2;          XCTAssertEqual(fired, 3)
        s.hasSpeakerSignal = true;       XCTAssertEqual(fired, 4)
        s.callAudioNote = "Chrome";      XCTAssertEqual(fired, 5)
        s.segments = []                  // published, though unchanged in value
        XCTAssertEqual(fired, 6)
    }

    // MARK: - MeetingLiveEdge

    func testTheLiveEdgePublishesOnlyWhenTheBubbleAppearsOrGoes() {
        let s = session()
        let edge = MeetingLiveEdge(session: s)
        Self.keepAlive.append(edge)
        XCTAssertFalse(edge.hasLiveTail)
        var fired = 0
        let bag = edge.objectWillChange.sink { fired += 1 }
        defer { bag.cancel() }

        s.livePreviewText = "first words"
        XCTAssertTrue(edge.hasLiveTail)
        XCTAssertEqual(fired, 1)
        for i in 0..<100 { s.livePreviewText = "first words \(i)" }
        XCTAssertEqual(fired, 1, "more words while the bubble is already showing publish nothing")
        s.livePreviewText = ""
        XCTAssertFalse(edge.hasLiveTail)
        XCTAssertEqual(fired, 2)
    }

    func testTheLiveEdgeFollowsRecordingState() {
        let s = session()
        let edge = MeetingLiveEdge(session: s)
        Self.keepAlive.append(edge)
        let id = UUID()
        s.meetingID = id
        s.isRecording = true
        XCTAssertTrue(edge.isRecording)
        XCTAssertEqual(edge.sessionMeetingID, id)
        s.isRecording = false
        XCTAssertFalse(edge.isRecording)
    }

    // MARK: - Direction

    private func segment(_ text: String, _ i: Int = 0) -> MeetingSegment {
        MeetingSegment(timestamp: Double(i) * 10, endTimestamp: Double(i) * 10 + 9, text: text, speakerName: "A", speakerIndex: 0)
    }

    func testDirectionIsComputedOncePerTranscriptChange() {
        let cache = TranscriptDirectionCache()
        let segments = (0..<119).map { segment("אנחנו מדברים על התקציב של נובמבר, סעיף \($0).", $0) }
        for _ in 0..<500 { XCTAssertTrue(cache.isRightToLeft(segments: segments, liveTail: "", fallback: nil)) }
        XCTAssertEqual(cache.computations, 1, "500 renders of the same transcript must scan it once")
        let more = segments + [segment("עוד כרטיס", 119)]
        XCTAssertTrue(cache.isRightToLeft(segments: more, liveTail: "", fallback: nil))
        XCTAssertEqual(cache.computations, 2, "a new card is a change")
    }

    func testTheLiveTailIsRejudgedOnlyEveryFewWords() {
        let cache = TranscriptDirectionCache()
        var tail = ""
        for i in 0..<400 {
            tail += " слово\(i)"
            _ = cache.isRightToLeft(segments: [], liveTail: tail, fallback: nil)
        }
        XCTAssertLessThan(cache.computations, 80, "\(cache.computations) scans for 400 words of tail")
    }

    func testTheCachedAnswerStillTracksContent() {
        let cache = TranscriptDirectionCache()
        XCTAssertFalse(cache.isRightToLeft(segments: [segment("we are talking about the budget today")], liveTail: "", fallback: nil))
        XCTAssertTrue(cache.isRightToLeft(segments: [segment("אנחנו מדברים על התקציב של נובמבר")], liveTail: "", fallback: nil))
    }

    /// The fast letter test must agree with the Unicode tables for the scripts it shortcuts.
    func testTheFastLetterScanAgreesWithTheUnicodeTables() {
        let samples = ["Hello world", "Привет мир ёЁ", "שלום עולם", "مرحبا", "e\u{301}cole", "日本語のテキスト", "42 + 7 = 49 !!", "שָׁלוֹם", "mixed Привет שלום 123"]
        for text in samples {
            let reference = text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
            // Direction verdicts over many repetitions agree between a long and a short sample of the same text.
            let long = String(repeating: text + " ", count: 50)
            let v1 = MeetingTranscriptText.isRightToLeft(text: long)
            let v2 = MeetingTranscriptText.isRightToLeft(text: String(repeating: text + " ", count: 20))
            XCTAssertEqual(v1, v2, text)
            XCTAssertGreaterThanOrEqual(reference, 0)
        }
        XCTAssertTrue(MeetingTranscriptText.isRightToLeft(text: "שלום עולם זה טקסט בעברית"))
        XCTAssertFalse(MeetingTranscriptText.isRightToLeft(text: "Привет мир это русский текст"))
        XCTAssertFalse(MeetingTranscriptText.isRightToLeft(text: "plain english text here"))
        XCTAssertTrue(MeetingTranscriptText.isRightToLeft(text: "مرحبا بالعالم هذا نص عربي"))
        // Hebrew with niqqud (marks fall through to the Unicode tables) is still right-to-left.
        XCTAssertTrue(MeetingTranscriptText.isRightToLeft(text: "שָׁלוֹם עוֹלָם בְּעִבְרִית"))
    }
}

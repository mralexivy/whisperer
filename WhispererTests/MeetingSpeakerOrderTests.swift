//
//  MeetingSpeakerOrderTests.swift
//  WhispererTests
//
//  Speakers are numbered by first appearance — the user never sees "Speaker 2" before
//  "Speaker 1" — whatever slot order the diarizer uses internally. No models: the coordinator
//  is driven with injected finalized turns.
//

import XCTest
@testable import whisperer

#if canImport(FluidAudio)

final class MeetingSpeakerOrderTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        var attributed: [(text: String, speaker: Int)] = []
        var live: [Int] = []
    }

    private func makeCoordinator() async -> (MeetingSpeakerCoordinator, Box) {
        let coordinator = MeetingSpeakerCoordinator()
        let box = Box()
        await coordinator.setCallbacks(
            onAttributed: { text, speaker, _, _ in box.attributed.append((text, speaker)) },
            onPendingTail: { _ in },
            onLiveSpeaker: { box.live.append($0) }
        )
        return (coordinator, box)
    }

    private func feed(_ c: MeetingSpeakerCoordinator, seconds: Double) async {
        await c.feed([Float](repeating: 0, count: Int(seconds * 16_000)))
    }

    func testFirstVoiceIsSpeakerOneWhateverItsSlot() async {
        let (c, box) = await makeCoordinator()
        await feed(c, seconds: 2)
        await c.onPartial("hello there everyone")
        // The diarizer happens to put the first voice in slot 1.
        await c._integrateForTesting([(start: 0, end: 2, slot: 1)])
        XCTAssertEqual(box.attributed.first?.speaker, 0, "the first voice heard is Speaker 1")

        await feed(c, seconds: 2)
        await c.onPartial("hello there everyone how are you")
        await c._integrateForTesting([(start: 2, end: 4, slot: 0)])
        XCTAssertEqual(box.attributed.last?.speaker, 1, "the next new voice is Speaker 2")
        XCTAssertEqual(box.live.last, 1)
    }

    /// A cough or crosstalk flicker on a slot nobody has heard must not become a new speaker.
    func testBlipFromAnUnknownSlotDoesNotIntroduceASpeaker() async {
        let (c, box) = await makeCoordinator()
        await feed(c, seconds: 2)
        await c.onPartial("we should start")
        await c._integrateForTesting([(start: 0, end: 2, slot: 0)])
        XCTAssertEqual(box.attributed.last?.speaker, 0)

        await feed(c, seconds: 0.6)
        await c.onPartial("we should start now")
        await c._integrateForTesting([(start: 2.0, end: 2.6, slot: 3)])
        XCTAssertEqual(box.attributed.last?.speaker, 0,
                       "0.6 s from an unknown slot is not enough to be a new person")
        XCTAssertFalse(box.live.contains(where: { $0 > 0 }),
                       "the live label never announces a speaker the transcript does not know")
    }

    func testLiveLabelWaitsForTheFirstCommittedWords() async {
        let (c, box) = await makeCoordinator()
        await feed(c, seconds: 1)
        await c._integrateForTesting([(start: 0, end: 1, slot: 2)])   // no words yet
        XCTAssertTrue(box.live.isEmpty, "no 'Speaker N' before anyone's words are in")
    }

    /// A pause between word arrivals reaches the session as an audio-clock gap, so the
    /// paragraph can break there. Items used to abut and fold the pause inside.
    func testAPauseBetweenWordsBecomesAGap() async {
        let coordinator = MeetingSpeakerCoordinator()
        final class Spans: @unchecked Sendable { var list: [(start: Double, end: Double)] = [] }
        let spans = Spans()
        await coordinator.setCallbacks(
            onAttributed: { _, _, start, end in spans.list.append((start, end)) },
            onPendingTail: { _ in }, onLiveSpeaker: { _ in })
        await feed(coordinator, seconds: 2)
        await coordinator.onPartial("we start now")
        await feed(coordinator, seconds: 4)                 // drains the first item, then silence
        await coordinator.onPartial("we start now next topic")
        await feed(coordinator, seconds: 4)                 // drains the second
        XCTAssertEqual(spans.list.count, 2)
        guard spans.list.count == 2 else { return }
        XCTAssertGreaterThanOrEqual(spans.list[1].start - spans.list[0].end, 1.2,
                                    "the pause must be visible on the audio clock")
    }

    // MARK: - Saved meetings from before the fix

    private func segment(_ t: Double, _ index: Int, _ name: String? = nil) -> MeetingSegment {
        MeetingSegment(timestamp: t, endTimestamp: t + 2, text: "x",
                       speakerName: name ?? "Speaker \(index + 1)", speakerIndex: index)
    }

    func testStoredMeetingsAreRenumberedByFirstAppearance() {
        let stored = [segment(0, 1), segment(5, 0), segment(9, 1), segment(12, 4, "Dana")]
        let shown = stored.normalizedSpeakerOrder()
        XCTAssertEqual(shown.map(\.speakerIndex), [0, 1, 0, 2])
        XCTAssertEqual(shown.map(\.speakerName), ["Speaker 1", "Speaker 2", "Speaker 1", "Dana"],
                       "default names follow the new number; a typed name is kept")
        XCTAssertEqual(shown.normalizedSpeakerOrder().map(\.speakerIndex), [0, 1, 0, 2], "idempotent")
    }

    func testInOrderMeetingsAreUntouched() {
        let stored = [segment(0, 0), segment(3, 1, "Avi")]
        XCTAssertEqual(stored.normalizedSpeakerOrder().map(\.speakerName), ["Speaker 1", "Avi"])
    }
}
#endif

//
//  SpeakerSourceAttributionTests.swift
//  WhispererTests
//
//  Automatic speaker names from the invite: the voice at the microphone is the user, the call's
//  voice in a 1:1 is the other attendee, and nothing is guessed when the evidence is not there.
//

import XCTest
@testable import whisperer

final class SpeakerSourceAttributionTests: XCTestCase {

    private typealias Frame = SystemAudioMixer.SourceFrame
    private typealias Span = SpeakerSourceAttribution.Span

    /// 0.1 s buffers from `0..<seconds`; the call talks inside `callTalking`.
    private func activity(seconds: Double, callTalking: [ClosedRange<Double>], callLevel: Float = 0.05) -> [Frame] {
        let step = 1_600
        return stride(from: 0, to: Int(seconds * 16_000), by: step).map { start in
            let t = Double(start) / 16_000
            let talking = callTalking.contains { $0.contains(t) }
            return Frame(start: start, count: step, micRMS: 0.05, callRMS: talking ? callLevel : 0)
        }
    }

    private let me = MeetingParticipant(name: nil, email: "ialex.ivy@gmail.com", isSelf: true, isOrganizer: true, response: .accepted)
    private let keren = MeetingParticipant(name: "Keren Cohen", email: "keren@x.com", isSelf: false, isOrganizer: false, response: .accepted)
    private let dana = MeetingParticipant(name: "Dana Levi", email: "dana@x.com", isSelf: false, isOrganizer: false, response: .accepted)

    private func names(_ spans: [Span], _ frames: [Frame], _ people: [MeetingParticipant]) -> [Int: String] {
        let sources = SpeakerSourceAttribution.classify(spans, activity: frames)
        return SpeakerSourceAttribution.names(
            for: sources, participants: people,
            ownName: SpeakerSourceAttribution.ownName(participants: people, macAccountName: "Alex Ivy"))
    }

    /// Alex / Keren weekly: the user at the mic, Keren on the call.
    func testOneToOneNamesTheUserAndTheOtherAttendee() {
        let frames = activity(seconds: 60, callTalking: [10...20, 30...40, 50...60])
        let spans = [Span(speakerIndex: 0, start: 0, end: 10), Span(speakerIndex: 1, start: 10, end: 20),
                     Span(speakerIndex: 0, start: 20, end: 30), Span(speakerIndex: 1, start: 30, end: 40),
                     Span(speakerIndex: 0, start: 40, end: 50), Span(speakerIndex: 1, start: 50, end: 60)]
        XCTAssertEqual(names(spans, frames, [me, keren]), [0: "Alex Ivy", 1: "Keren Cohen"])
    }

    /// The call talking over the user for a moment does not make the user remote.
    func testCrosstalkDoesNotFlipTheUser() {
        let frames = activity(seconds: 60, callTalking: [8...20, 30...40])
        let spans = [Span(speakerIndex: 0, start: 0, end: 10), Span(speakerIndex: 1, start: 10, end: 20),
                     Span(speakerIndex: 0, start: 20, end: 30), Span(speakerIndex: 1, start: 30, end: 40),
                     Span(speakerIndex: 0, start: 40, end: 60)]
        XCTAssertEqual(names(spans, frames, [me, keren])[0], "Alex Ivy")
    }

    /// Capture denied: the tap delivers digital silence, every voice would look local. Nothing.
    func testSilentTapNamesNobody() {
        let frames = activity(seconds: 60, callTalking: [])
        let spans = [Span(speakerIndex: 0, start: 0, end: 30), Span(speakerIndex: 1, start: 30, end: 60)]
        XCTAssertEqual(names(spans, frames, [me, keren]), [:])
    }

    /// Group call: the user is named; the call's voices wait for the active-speaker match.
    func testGroupNamesOnlyTheUser() {
        let frames = activity(seconds: 60, callTalking: [10...20, 30...40])
        let spans = [Span(speakerIndex: 0, start: 0, end: 10), Span(speakerIndex: 1, start: 10, end: 20),
                     Span(speakerIndex: 2, start: 30, end: 40), Span(speakerIndex: 0, start: 40, end: 60)]
        XCTAssertEqual(names(spans, frames, [me, keren, dana]), [0: "Alex Ivy"])
    }

    /// A declined attendee is not in the meeting, so it is still a 1:1.
    func testDeclinedAttendeeDoesNotTurnAOneToOneIntoAGroup() {
        var declined = dana
        declined.response = .declined
        let frames = activity(seconds: 40, callTalking: [10...20, 30...40])
        let spans = [Span(speakerIndex: 0, start: 0, end: 10), Span(speakerIndex: 1, start: 10, end: 20),
                     Span(speakerIndex: 0, start: 20, end: 30), Span(speakerIndex: 1, start: 30, end: 40)]
        XCTAssertEqual(names(spans, frames, [me, keren, declined])[1], "Keren Cohen")
    }

    /// Two voices at the microphone (a guest beside the user, or the user split in two): only the
    /// one with the most speech is the user; the other is left alone.
    func testOnlyOneLocalVoiceTakesTheUsersName() {
        let frames = activity(seconds: 70, callTalking: [50...70])
        let spans = [Span(speakerIndex: 0, start: 0, end: 30), Span(speakerIndex: 2, start: 30, end: 40),
                     Span(speakerIndex: 1, start: 50, end: 70)]
        let result = names(spans, frames, [me, keren])
        XCTAssertEqual(result[0], "Alex Ivy")
        XCTAssertNil(result[2], "a second local voice must not be named as the user")
        XCTAssertEqual(result[1], "Keren Cohen")
    }

    /// Under four seconds of speech is too little to call.
    func testShortSpeakerIsNotClassified() {
        let frames = activity(seconds: 40, callTalking: [10...30])
        let spans = [Span(speakerIndex: 0, start: 0, end: 10), Span(speakerIndex: 1, start: 10, end: 30),
                     Span(speakerIndex: 2, start: 32, end: 34)]
        XCTAssertNil(names(spans, frames, [me, keren])[2])
    }

    /// No invite (an ad-hoc call): nobody to name the call after, so no names at all.
    func testNoInviteNamesNobody() {
        let frames = activity(seconds: 40, callTalking: [10...20, 30...40])
        let spans = [Span(speakerIndex: 0, start: 0, end: 10), Span(speakerIndex: 1, start: 10, end: 20)]
        XCTAssertEqual(names(spans, frames, []), [:])
    }

    /// Outlook names the user's own attendee entry; that wins over this Mac's account name.
    func testOwnNamePrefersTheInvite() {
        var named = me
        named.name = "Alex Ivanov"
        XCTAssertEqual(SpeakerSourceAttribution.ownName(participants: [named, keren], macAccountName: "Alex Ivy"), "Alex Ivanov")
        XCTAssertEqual(SpeakerSourceAttribution.ownName(participants: [me, keren], macAccountName: "Alex Ivy"), "Alex Ivy")
        XCTAssertEqual(SpeakerSourceAttribution.ownName(participants: [me, keren], macAccountName: " "), "Me")
    }

    /// The mixer records both sides' levels on the mic clock, before the speakers duck.
    func testMixerRecordsLevelsWithTheMixOff() {
        let mixer = SystemAudioMixer()
        mixer.mode = .duckMicWhileCallTalks
        mixer.append([Float](repeating: 0.1, count: 160))
        _ = mixer.mix(mic: [Float](repeating: 0.2, count: 160))
        _ = mixer.mix(mic: [Float](repeating: 0.2, count: 160))
        let frames = mixer.sourceActivity
        XCTAssertEqual(frames.map(\.start), [0, 160])
        XCTAssertEqual(frames[0].callRMS, 0.1, accuracy: 1e-5)
        XCTAssertEqual(frames[1].callRMS, 0, accuracy: 1e-6)
        XCTAssertEqual(frames[0].micRMS, 0.2, accuracy: 1e-5)
    }
}

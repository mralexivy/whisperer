//
//  LiveSpeakerRenameTests.swift
//  WhispererTests
//
//  Naming a voice while the meeting is still running: the rules `SpeakerRenamer` applies to a typed
//  name, the invite suggestions, and that a name the user typed is the one the meeting ends with.
//

import XCTest
@testable import whisperer

@MainActor
final class LiveSpeakerRenameTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private let roster: [(index: Int, name: String)] = [(0, "Speaker 1"), (1, "Dana Levi")]

    private func person(_ name: String, response: MeetingRSVP = .accepted) -> MeetingParticipant {
        MeetingParticipant(name: name, email: "\(name.lowercased().replacingOccurrences(of: " ", with: "."))@x.com",
                           isSelf: false, isOrganizer: false, response: response)
    }

    func testEmptyNameIsAProblem() {
        XCTAssertEqual(SpeakerRenamer.problem(for: "  ", speakerIndex: 0, roster: roster), .empty)
    }

    func testNameOfAnotherVoiceIsRefusedWhateverTheCase() {
        XCTAssertEqual(SpeakerRenamer.problem(for: "dana levi", speakerIndex: 0, roster: roster), .taken(by: "Dana Levi"))
    }

    func testKeepingYourOwnNameIsNotAConflict() {
        XCTAssertNil(SpeakerRenamer.problem(for: "Dana Levi", speakerIndex: 1, roster: roster))
        XCTAssertNil(SpeakerRenamer.problem(for: "Keren", speakerIndex: 0, roster: roster))
    }

    func testSuggestionsAreInviteNamesNobodyCarriesYet() {
        let names = SpeakerRenamer.suggestions(
            participants: [person("Dana Levi"), person("Keren Cohen"), person("Omri Bar", response: .declined)],
            roster: roster)
        XCTAssertEqual(names, ["Keren Cohen"])
    }

    func testTypedNameSurvivesTheStopTimeNamingAndLaterCards() {
        let s = MeetingSession()
        Self.keepAlive.append(s)
        s.segments = [
            MeetingSegment(timestamp: 0, endTimestamp: 2, text: "hello", speakerName: "Speaker 1", speakerIndex: 0),
            MeetingSegment(timestamp: 2, endTimestamp: 4, text: "hi", speakerName: "Speaker 2", speakerIndex: 1),
        ]
        s.updateSpeaker(speakerIndex: 1, newName: "  Keren  ")

        XCTAssertEqual(s.segments.map(\.speakerName), ["Speaker 1", "Keren"])
        // The naming from the invite runs at stop; it must not take the name back.
        s.participants = [person("Dana Levi"), person("Keren Cohen")]
        s.refreshAutomaticSpeakerNames(force: true)
        XCTAssertEqual(s.segments.map(\.speakerName), ["Speaker 1", "Keren"])
        XCTAssertEqual(s.speakerRoster.map(\.name), ["Speaker 1", "Keren"])
    }

    func testRosterIncludesTheVoiceSpeakingNow() {
        let s = MeetingSession()
        Self.keepAlive.append(s)
        s.segments = [MeetingSegment(timestamp: 0, endTimestamp: 2, text: "hello", speakerName: "Speaker 1", speakerIndex: 0)]
        s.noteLiveSpeaker(1)
        XCTAssertEqual(s.speakerRoster.map(\.index), [0, 1])
    }
}

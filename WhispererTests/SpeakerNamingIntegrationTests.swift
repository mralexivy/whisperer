//
//  SpeakerNamingIntegrationTests.swift
//  WhispererTests
//
//  A 1:1 call end to end through the app's own mixer and naming: the user's voice at the
//  microphone, the other attendee's on the call tap, taking turns. Real speech (FLEURS), real
//  `SystemAudioMixer` levels, the naming `MeetingSession` runs at stop. Covers headphones (the mic
//  hears only the user), speakers (the mic also hears the call through the room), the diarizer
//  splitting the user in two, sloppy turn boundaries, and a call played quietly.
//

import XCTest
@testable import whisperer

final class SpeakerNamingIntegrationTests: XCTestCase {

    private typealias Span = SpeakerSourceAttribution.Span
    private static let corpus = "/Users/alexivy/ai/whisperer/Tools/omni-eval/corpus/fleurs"

    private let me = MeetingParticipant(name: "Alex Ivy", email: "alex@example.com", isSelf: true, isOrganizer: true, response: .accepted)
    private let keren = MeetingParticipant(name: "Keren Cohen", email: "keren@example.com", isSelf: false, isOrganizer: false, response: .accepted)

    private func voices() throws -> (user: [[Float]], other: [[Float]]) {
        func load(_ lang: String) throws -> [[Float]] {
            let dir = URL(fileURLWithPath: "\(Self.corpus)/\(lang)/test")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted().prefix(12), !names.isEmpty
            else { throw XCTSkip("FLEURS corpus not on this Mac") }
            // FLEURS is recorded at about -45 dB; a voice at a microphone or out of a call app is
            // around -26 dB (RMS 0.05). Near-silent clips are left out.
            return try names.compactMap { name -> [Float]? in
                let clip = try loadAudioSamples(from: dir.appendingPathComponent(name))
                let rms = (clip.reduce(0) { $0 + $1 * $1 } / Float(max(clip.count, 1))).squareRoot()
                guard rms > 0.002 else { return nil }
                return clip.map { $0 * (0.05 / rms) }
            }.prefix(3).map { $0 }
        }
        return (try load("en_us"), try load("ru_ru"))
    }

    /// Plays alternating turns (user, other, user, …) through the mixer the way a meeting does:
    /// the user into the mic buffers, the other into the tap. Returns the frames and true spans.
    private func meeting(route: CallAudioOutputRoute, callGain: Float = 1, roomEcho: Float = 0.12) throws
        -> (frames: [SystemAudioMixer.SourceFrame], turns: [(speaker: Int, start: Double, end: Double)]) {
        let (user, other) = try voices()
        let mixer = SystemAudioMixer()
        mixer.mode = route.farEndMode
        var turns: [(Int, Double, Double)] = []
        var t = 0
        let step = 1_365
        let echoDelay = 1_600   // 100 ms through the room
        for i in 0..<6 {
            let userTurn = i % 2 == 0
            let clip = (userTurn ? user[i / 2] : other[i / 2])
            let start = Double(t) / 16_000
            var offset = 0
            while offset < clip.count {
                let end = min(offset + step, clip.count)
                var mic = userTurn ? Array(clip[offset..<end]) : [Float](repeating: 0, count: end - offset)
                if !userTurn {
                    let far = Array(clip[offset..<end]).map { $0 * callGain }
                    mixer.append(far)
                    if route == .speakers {
                        // The room carries the far end into the microphone, late and quiet.
                        for j in mic.indices {
                            let k = offset + j - echoDelay
                            if k >= 0 { mic[j] += clip[k] * callGain * roomEcho }
                        }
                    }
                }
                mic += []   // keep the mic the clock
                _ = mixer.mix(mic: mic)
                offset = end
                t += mic.count
            }
            turns.append((userTurn ? 0 : 1, start, Double(t) / 16_000))
            // A short pause between turns.
            _ = mixer.mix(mic: [Float](repeating: 0, count: 8_000))
            t += 8_000
        }
        return (mixer.sourceActivity, turns)
    }

    private func names(_ spans: [Span], _ frames: [SystemAudioMixer.SourceFrame]) -> [Int: String] {
        let sources = SpeakerSourceAttribution.classify(spans, activity: frames)
        let ev = SpeakerSourceAttribution.evidence(spans, activity: frames)
        print("[Naming] callActive \(SpeakerSourceAttribution.callActiveSeconds(frames)) " + ev.sorted { $0.key < $1.key }.map { "S\($0.key) call \($0.value.callSeconds) mic \($0.value.micSeconds)" }.joined(separator: ", ") + " → \(sources)")
        return SpeakerSourceAttribution.names(for: sources, participants: [me, keren],
                                              ownName: SpeakerSourceAttribution.ownName(participants: [me, keren]))
    }

    func testHeadphonesNameBothSides() throws {
        let (frames, turns) = try meeting(route: .headphones)
        let result = names(turns.map { Span(speakerIndex: $0.speaker, start: $0.start, end: $0.end) }, frames)
        XCTAssertEqual(result[0], "Alex Ivy")
        XCTAssertEqual(result[1], "Keren Cohen")
    }

    func testSpeakersWithRoomEchoNameBothSides() throws {
        let (frames, turns) = try meeting(route: .speakers)
        let result = names(turns.map { Span(speakerIndex: $0.speaker, start: $0.start, end: $0.end) }, frames)
        XCTAssertEqual(result[0], "Alex Ivy")
        XCTAssertEqual(result[1], "Keren Cohen")
    }

    /// The diarizer calls the user's later turns a new speaker.
    func testUserSplitInTwoIsNamedTwice() throws {
        let (frames, turns) = try meeting(route: .headphones)
        let spans = turns.enumerated().map { i, turn in
            Span(speakerIndex: turn.speaker == 0 ? (i >= 4 ? 2 : 0) : 1, start: turn.start, end: turn.end)
        }
        let result = names(spans, frames)
        XCTAssertEqual(result[0], "Alex Ivy")
        XCTAssertEqual(result[2], "Alex Ivy")
        XCTAssertEqual(result[1], "Keren Cohen")
    }

    /// Cards whose edges are a second off, the way diarizer turns land.
    func testSloppyTurnEdgesStillName() throws {
        let (frames, turns) = try meeting(route: .speakers)
        let spans = turns.map { Span(speakerIndex: $0.speaker, start: max(0, $0.start - 1), end: $0.end + 1) }
        let result = names(spans, frames)
        XCTAssertEqual(result[0], "Alex Ivy")
        XCTAssertEqual(result[1], "Keren Cohen")
    }

    /// A call played at a tenth of full level (whole meetings peaking at 0.12 on 2026-11-10).
    func testQuietCallStillNamesBothSides() throws {
        let (frames, turns) = try meeting(route: .speakers, callGain: 0.1)
        let result = names(turns.map { Span(speakerIndex: $0.speaker, start: $0.start, end: $0.end) }, frames)
        XCTAssertEqual(result[0], "Alex Ivy")
        XCTAssertEqual(result[1], "Keren Cohen")
    }

    /// The 2026-11-10 failure: the tap delivered nothing, so no voice can be told apart.
    func testSilentTapNamesNobodyRatherThanGuessing() throws {
        let (frames, turns) = try meeting(route: .speakers, callGain: 0)
        let result = names(turns.map { Span(speakerIndex: $0.speaker, start: $0.start, end: $0.end) }, frames)
        XCTAssertTrue(result.isEmpty, "\(result)")
    }
}

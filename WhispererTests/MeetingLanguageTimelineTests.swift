//
//  MeetingLanguageTimelineTests.swift
//  WhispererTests
//
//  The maths behind the meeting language decision, with no audio and no model.
//
//  What these guard is the asymmetry that motivates the whole mechanism: Whisper handed a wrong
//  forced language code translates rather than fails, so a spurious span is catastrophic while a
//  missed one merely leaves today's per-window behaviour in place. Every case below is therefore
//  written from the direction of "can noise create a switch", not "can we detect every switch".
//

import XCTest
@testable import whisperer

final class MeetingLanguageTimelineTests: XCTestCase {

    // MARK: - Fixtures

    /// Probes laid end to end at `spacing`, each covering 30 s.
    private func probes(_ distributions: [[String: Float]], spacing: Double = 30) -> [MeetingLanguageProbe] {
        distributions.enumerated().map { index, probabilities in
            let start = Double(index) * spacing
            return MeetingLanguageProbe(start: start, end: start + 30, probabilities: probabilities)
        }
    }

    private func hebrew(_ strength: Float = 0.95) -> [String: Float] { ["he": strength, "en": 1 - strength] }
    private func english(_ strength: Float = 0.95) -> [String: Float] { ["en": strength, "he": 1 - strength] }

    private let hebrewText = "שלום לכולם, בואו נתחיל את הפגישה ונעבור על הנושאים"
    private let englishText = "Hello everyone, let us start the meeting and go over the agenda"

    // MARK: - Basics

    func testEmptyProbesProduceEmptyTimeline() {
        let timeline = MeetingLanguageTimelineBuilder.build(probes: [])
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertEqual(timeline.dominant, .auto)
    }

    func testUnanimousProbesGiveOneSpan() {
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes(Array(repeating: hebrew(), count: 10)),
            transcript: hebrewText, duration: 300
        )
        XCTAssertEqual(timeline.spans.count, 1)
        XCTAssertEqual(timeline.dominant, .hebrew)
        XCTAssertGreaterThan(timeline.dominantConfidence, 0.9)
        XCTAssertFalse(timeline.isMultilingual)
        XCTAssertEqual(timeline.spans.first?.start, 0)
        XCTAssertEqual(timeline.spans.first?.end, 300)
    }

    /// Summed log-probability, not per-window argmax: one emphatic probe has to be able to
    /// outvote several weak ones going the other way.
    func testOneConfidentProbeOutweighsSeveralWeakOnesOfTheOtherLanguage() {
        let distributions = [hebrew(0.99), english(0.34), english(0.34), english(0.34)]
        let timeline = MeetingLanguageTimelineBuilder.build(probes: probes(distributions), duration: 120)
        XCTAssertEqual(timeline.dominant, .hebrew)
        XCTAssertEqual(timeline.spans.count, 1)
    }

    // MARK: - The borrowing defence

    /// A single mis-detected window — an English brand name in a Hebrew sentence — must not
    /// produce a span. This is the bug the user reported, in its smallest form.
    func testSingleMisdetectedProbeProducesNoSwitch() {
        var distributions = Array(repeating: hebrew(), count: 11)
        distributions[5] = english(0.9)
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes(distributions), transcript: hebrewText, duration: 330
        )
        XCTAssertEqual(timeline.spans.count, 1, "one probe must not be able to pay for a switch")
        XCTAssertEqual(timeline.dominant, .hebrew)
    }

    /// Two scattered mis-detections, not adjacent, still must not move anything.
    func testScatteredMisdetectionsProduceNoSwitch() {
        var distributions = Array(repeating: hebrew(), count: 14)
        distributions[3] = english(0.9)
        distributions[9] = english(0.9)
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes(distributions), transcript: hebrewText, duration: 420
        )
        XCTAssertEqual(timeline.spans.count, 1)
        XCTAssertEqual(timeline.dominant, .hebrew)
    }

    /// …but a sustained stretch must survive, or code-switching support is theatre.
    func testSustainedStretchProducesThreeSpans() {
        var distributions = Array(repeating: hebrew(), count: 12)
        for index in 4...7 { distributions[index] = english() }
        let timeline = MeetingLanguageTimelineBuilder.build(probes: probes(distributions), duration: 360)

        XCTAssertEqual(timeline.spans.count, 3)
        XCTAssertEqual(timeline.spans.map(\.language), [.hebrew, .english, .hebrew])
        XCTAssertTrue(timeline.isMultilingual)
        XCTAssertEqual(timeline.dominant, .hebrew, "Hebrew still covers the most seconds")
        // Boundary lands in the gap between the disagreeing probes.
        XCTAssertEqual(timeline.spans[1].start, 120, accuracy: 15)
        XCTAssertEqual(timeline.spans[1].end, 240, accuracy: 15)
    }

    /// The case the real-history corpus found, in miniature: a run that is long enough and
    /// consistent enough to survive both the switch cost and the dwell rule, but only half-held.
    /// On a 48-minute Hebrew meeting this was 73 seconds of Polish at 0.48. Whole-meeting evidence
    /// has to override it, or every such blip re-decodes a stretch of audio in a language nobody
    /// spoke.
    func testWeaklyHeldMinorityRunIsOverriddenByTheMeeting() {
        var distributions = Array(repeating: hebrew(), count: 14)
        // Four consecutive probes — two minutes, well past the dwell bar — where the detector
        // half-favours Polish and never commits.
        for index in 6...9 { distributions[index] = ["pl": 0.48, "he": 0.24, "en": 0.12] }

        let timeline = MeetingLanguageTimelineBuilder.build(probes: probes(distributions), duration: 420)

        XCTAssertEqual(timeline.spans.count, 1, "Expected one Hebrew span, got \(timeline.logDescription)")
        XCTAssertEqual(timeline.dominant, .hebrew)
        XCTAssertFalse(timeline.isMultilingual)
    }

    /// The other side of that rule: a *confidently* held minority run is a real code-switch and
    /// must survive. Without this the override would silently delete every genuine switch.
    func testConfidentlyHeldMinorityRunSurvivesTheOverride() {
        var distributions = Array(repeating: hebrew(), count: 14)
        for index in 6...9 { distributions[index] = english(0.95) }

        let timeline = MeetingLanguageTimelineBuilder.build(probes: probes(distributions), duration: 420)

        XCTAssertEqual(timeline.spans.map(\.language), [.hebrew, .english, .hebrew])
    }

    /// The dwell rule, isolated: a decided span below the threshold is absorbed by its neighbour.
    func testShortSpansAreAbsorbedIntoTheLongerNeighbour() {
        let input = [
            MeetingLanguageSpan(start: 0, end: 100, language: .hebrew, confidence: 0.9),
            MeetingLanguageSpan(start: 100, end: 108, language: .english, confidence: 0.9),
            MeetingLanguageSpan(start: 108, end: 300, language: .hebrew, confidence: 0.9),
        ]
        let absorbed = MeetingLanguageTimelineBuilder.mergeAdjacent(
            MeetingLanguageTimelineBuilder.absorbShortSpans(input, minimum: 15)
        )
        XCTAssertEqual(absorbed.count, 1)
        XCTAssertEqual(absorbed.first?.language, .hebrew)
        XCTAssertEqual(absorbed.first?.start, 0)
        XCTAssertEqual(absorbed.first?.end, 300)
    }

    // MARK: - Script veto

    /// Hebrew text cannot have been spoken in a Latin-script language, however the audio detector
    /// leans. This is the signal that stops he→en translation outright.
    func testScriptVetoKillsALatinCandidateOnHebrewText() {
        let distributions = Array(repeating: ["en": Float(0.6), "he": Float(0.4)], count: 8)
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes(distributions), transcript: hebrewText, duration: 240
        )
        XCTAssertEqual(timeline.dominant, .hebrew)
    }

    /// The veto must stay off when the text is mixed — which is exactly what a transcript
    /// corrupted by the old behaviour looks like. Both scripts present means no candidate is
    /// vetoed and the audio decides.
    func testScriptVetoDoesNotFireOnMixedScriptText() {
        let distributions = Array(repeating: ["en": Float(0.9), "he": Float(0.1)], count: 8)
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes(distributions), transcript: hebrewText + " " + englishText, duration: 240
        )
        XCTAssertEqual(timeline.dominant, .english)
    }

    // MARK: - Abstention

    /// Too close to call means no opinion. A wrong pin translates a whole meeting; abstaining
    /// only leaves the decoder doing what it already did.
    func testBelowMarginInputAbstains() {
        let distributions = Array(repeating: ["en": Float(0.52), "de": Float(0.48)], count: 8)
        let timeline = MeetingLanguageTimelineBuilder.build(probes: probes(distributions), duration: 240)
        XCTAssertEqual(timeline.dominant, .auto)
        XCTAssertEqual(timeline.spans.first?.language, .auto)
        XCTAssertEqual(timeline.language(at: 100), .auto)
    }

    // MARK: - Shortlist

    func testShortlistFiltersOutLanguagesTheUserDisabled() {
        let distributions = Array(repeating: ["ru": Float(0.7), "he": Float(0.2), "en": Float(0.1)], count: 8)
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes(distributions),
            allowedLanguages: [.hebrew, .english], duration: 240
        )
        XCTAssertEqual(timeline.dominant, .hebrew, "Russian is not in the shortlist and must not win")
    }

    func testNormalizeRenormalizesAfterFiltering() {
        let normalized = MeetingLanguageTimelineBuilder.normalize(
            ["ru": 0.7, "he": 0.2, "en": 0.1], allowed: [.hebrew, .english]
        )
        XCTAssertEqual(normalized[.hebrew] ?? 0, 0.667, accuracy: 0.01)
        XCTAssertEqual(normalized[.english] ?? 0, 0.333, accuracy: 0.01)
    }

    // MARK: - Priors

    /// The Nemotron tally is free evidence, but the weakest signal here — it must be able to
    /// break a tie and nothing more.
    func testNemotronTallyBreaksATieWithoutOverridingAudio() {
        let even = Array(repeating: ["en": Float(0.5), "nl": Float(0.5)], count: 8)
        let tied = MeetingLanguageTimelineBuilder.build(probes: probes(even), nemotronTally: ["nl": 40], duration: 240)
        XCTAssertEqual(tied.spans.first?.language, .auto, "a prior must not manufacture confidence")

        let clear = Array(repeating: ["en": Float(0.95), "nl": Float(0.05)], count: 8)
        let overruled = MeetingLanguageTimelineBuilder.build(probes: probes(clear), nemotronTally: ["nl": 400], duration: 240)
        XCTAssertEqual(overruled.dominant, .english, "audio evidence outranks the live tally")
    }

    // MARK: - Lookup

    func testLanguageAtTimeCoversTheWholeMeeting() {
        var distributions = Array(repeating: hebrew(), count: 12)
        for index in 4...7 { distributions[index] = english() }
        let timeline = MeetingLanguageTimelineBuilder.build(probes: probes(distributions), duration: 400)

        XCTAssertEqual(timeline.language(at: 0), .hebrew)
        XCTAssertEqual(timeline.language(at: 180), .english)
        XCTAssertEqual(timeline.language(at: 399), .hebrew)
        XCTAssertEqual(timeline.language(at: 100_000), .hebrew, "past the end falls back to the last span")
    }

    // MARK: - Viterbi directly

    func testViterbiStaysPutWithoutEnoughEvidence() {
        let stay = log(Float(0.9)), leave = log(Float(0.1))
        let emissions = [[stay, leave], [leave, stay], [stay, leave], [stay, leave]]
        let path = MeetingLanguageTimelineBuilder.viterbi(emissions: emissions, prior: [0.5, 0.5], switchCost: 3)
        XCTAssertEqual(path, [0, 0, 0, 0])
    }

    func testViterbiMovesWhenEvidenceIsSustained() {
        let stay = log(Float(0.95)), leave = log(Float(0.05))
        let emissions = [[stay, leave], [stay, leave], [leave, stay], [leave, stay], [leave, stay]]
        let path = MeetingLanguageTimelineBuilder.viterbi(emissions: emissions, prior: [0.5, 0.5], switchCost: 3)
        XCTAssertEqual(path, [0, 0, 1, 1, 1])
    }
}

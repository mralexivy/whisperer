//
//  LanguagePinRegressionTests.swift
//  WhispererTests
//
//  The Hebrew meeting that came out as Italian phonetics, reduced to the four pure decisions
//  that produced it. No audio, no model, no CoreData — each case here is one function that
//  returned the wrong answer on 2026-08-23 and can be checked in microseconds.
//
//  The common cause of three of the four is the same: Nemotron reports BCP-47 (`"he-IL"`,
//  `"it-IT"`) and `TranscriptionLanguage`'s raw values are bare ISO-639-1 (`"he"`, `"it"`), so
//  every `init(rawValue:)` against a Nemotron code returned nil. Nothing threw and nothing logged
//  — a script veto, an RTL callback and a whole prior simply stopped running.
//

import XCTest
@testable import whisperer

final class LanguagePinRegressionTests: XCTestCase {

    // MARK: - A4: BCP-47 normalisation

    func testLanguageTagAcceptsRegionSubtag() {
        XCTAssertEqual(TranscriptionLanguage.from(languageTag: "he-IL"), .hebrew)
        XCTAssertEqual(TranscriptionLanguage.from(languageTag: "it-IT"), .italian)
        XCTAssertEqual(TranscriptionLanguage.from(languageTag: "zh_Hans"), .chinese)
        XCTAssertEqual(TranscriptionLanguage.from(languageTag: "he"), .hebrew)
    }

    func testLanguageTagRejectsNonLanguages() {
        XCTAssertNil(TranscriptionLanguage.from(languageTag: "auto"))
        XCTAssertNil(TranscriptionLanguage.from(languageTag: ""))
        XCTAssertNil(TranscriptionLanguage.from(languageTag: "   "))
        XCTAssertNil(TranscriptionLanguage.from(languageTag: "xx-YY"))
    }

    // MARK: - A1/A2: Nemotron prompt dictionary

    #if canImport(FluidAudio)
    /// The real shipping dictionary's shape: 47 of its languages exist only under a regional key,
    /// so a bare lookup is a silent fallback to the `auto` prompt — which is what ran the whole
    /// meeting unforced while every log line read like success.
    private var dictionary: NemotronPromptDictionary {
        NemotronPromptDictionary(promptIDs: ["auto": 101, "he-IL": 64, "it-IT": 15, "it": 15, "en": 1])
    }

    func testRegionalOnlyLanguageResolvesToItsRegionalKey() {
        XCTAssertEqual(dictionary.promptKey(for: .hebrew), "he-IL")
    }

    func testBareKeyPreferredWhenBothExist() {
        XCTAssertEqual(dictionary.promptKey(for: .italian), "it")
    }

    func testUnsupportedLanguageHasNoKey() {
        XCTAssertNil(dictionary.promptKey(for: .yiddish))
    }

    func testAutoMapsToAutoKey() {
        XCTAssertEqual(dictionary.promptKey(for: .auto), "auto")
    }

    func testTagLookupAcceptsEitherForm() {
        XCTAssertEqual(dictionary.promptKey(forTag: "he"), "he-IL")
        XCTAssertEqual(dictionary.promptKey(forTag: "he-IL"), "he-IL")
    }
    #endif

    // MARK: - A4: the pinner's script veto, re-armed

    func testScriptVetoRejectsItalianOverHebrewText() {
        let pinner = NemotronLanguagePinner(minChunksBeforePin: 2, agreementThreshold: 0.5)
        let hebrew = "לא יודע אנשים מצטרפים כתבתי להם ואני מוודא שהם מצטרפים"
        XCTAssertNil(pinner.observe(code: "it-IT", text: hebrew))
        XCTAssertNil(pinner.observe(code: "it-IT", text: hebrew))
        XCTAssertNil(pinner.pinnedCode, "Italian must not pin against overwhelmingly Hebrew text")
    }

    /// The veto is deliberately one-way: a Hebrew stretch mis-decoded into Latin transliteration
    /// is the failure being fixed, so Latin text must not be evidence against Hebrew.
    func testScriptVetoDoesNotBlockHebrewOverLatinText() {
        let pinner = NemotronLanguagePinner(minChunksBeforePin: 2, agreementThreshold: 0.5)
        let transliterated = "Fasta I ci recordinga Lze ho li Rod Sen"
        XCTAssertNil(pinner.observe(code: "he-IL", text: transliterated))
        XCTAssertNotNil(pinner.observe(code: "he-IL", text: transliterated))
        XCTAssertEqual(pinner.pinnedCode, "he-IL")
    }

    /// `"he"` from the fused verdict and `"he-IL"` from Nemotron are the same language. Comparing
    /// them as strings would start a challenger run against our own pin.
    func testAdoptedPinIsNotChallengedByItsOwnRegionalForm() {
        let pinner = NemotronLanguagePinner(minChunksBeforePin: 2, agreementThreshold: 0.5, chunksToRepin: 2)
        XCTAssertTrue(pinner.adopt(code: "he"))
        XCTAssertFalse(pinner.adopt(code: "he-IL"), "Same language — nothing to re-issue")
        for _ in 0..<4 { _ = pinner.observe(code: "he-IL", text: "שלום") }
        XCTAssertEqual(pinner.pinnedCode, "he")
    }

    // MARK: - B: the fused verdict

    private func probe(_ probabilities: [String: Float], from start: Double, to end: Double) -> MeetingLanguageProbe {
        MeetingLanguageProbe(start: start, end: end, probabilities: probabilities)
    }

    /// The evidence as it actually stood at ~40 s into the meeting: a tiny probe wavering around
    /// he 0.66, Nemotron insisting on Italian, one V3 confirmation at 0.98. The old code took the
    /// tiny probe alone, failed the 0.75 gate, and stayed unrouted.
    func testV3ConfirmationOutweighsNemotronsItalian() {
        let arbiter = LiveLanguageArbiter()
        for index in 0..<8 { _ = index; arbiter.recordNemotron(code: "it-IT") }
        arbiter.recordCoarse(probabilities: ["he": 0.66, "fr": 0.20, "en": 0.14], start: 0, end: 3)
        arbiter.recordCoarse(probabilities: ["he": 0.62, "fr": 0.25, "en": 0.13], start: 20, end: 23)
        arbiter.recordAccurate(probabilities: ["he": 0.98, "it": 0.01, "en": 0.01], start: 30, end: 33)

        let verdict = arbiter.fuse(transcript: "", allowedLanguages: [], duration: 40)
        XCTAssertEqual(verdict?.language, .hebrew)
        XCTAssertTrue(verdict?.usedAccurate == true)
    }

    /// Short dictation must never pay for an encoder pass: the budget clock gates the *first*
    /// confirmation as well as the interval between them. Only a long-form session gets the early
    /// first confirmation, which is why this arbiter is left unconfigured.
    func testNoEscalationBeforeThirtySecondsOfAudio() {
        let arbiter = LiveLanguageArbiter()
        arbiter.recordCoarse(probabilities: ["he": 0.40, "fr": 0.35], start: 0, end: 3)
        XCTAssertNil(arbiter.escalationReason(coarse: ["he": 0.40, "fr": 0.35], nemotronCode: nil,
                                              currentLock: nil, audioSeconds: 12))
    }

    func testLowConfidenceProbeEscalates() {
        let arbiter = LiveLanguageArbiter()
        let coarse: [String: Float] = ["he": 0.66, "fr": 0.20]
        arbiter.recordCoarse(probabilities: coarse, start: 30, end: 33)
        XCTAssertEqual(arbiter.escalationReason(coarse: coarse, nemotronCode: nil,
                                                currentLock: nil, audioSeconds: 33), .lowConfidence)
    }

    /// A confident probe that disagrees with Nemotron is the exact configuration of the failing
    /// meeting, and is worth one pass even though neither detector is hedging.
    func testDetectorDisagreementEscalates() {
        let arbiter = LiveLanguageArbiter()
        let coarse: [String: Float] = ["he": 0.93, "en": 0.04]
        arbiter.recordCoarse(probabilities: coarse, start: 30, end: 33)
        XCTAssertEqual(arbiter.escalationReason(coarse: coarse, nemotronCode: "it-IT",
                                                currentLock: nil, audioSeconds: 33), .detectorDisagreement)
    }

    func testBudgetStopsAtTheCap() {
        let arbiter = LiveLanguageArbiter(config: .init(maxAccurateProbes: 1))
        arbiter.recordAccurate(probabilities: ["he": 0.98], start: 30, end: 33)
        XCTAssertNil(arbiter.escalationReason(coarse: ["he": 0.5, "fr": 0.5], nemotronCode: "it-IT",
                                              currentLock: nil, audioSeconds: 200))
    }

    func testResetClearsEverything() {
        let arbiter = LiveLanguageArbiter()
        arbiter.recordNemotron(code: "it-IT")
        arbiter.recordAccurate(probabilities: ["he": 0.98], start: 0, end: 3)
        arbiter.reset()
        XCTAssertEqual(arbiter.probeCount, 0)
        XCTAssertTrue(arbiter.nemotronTally.isEmpty)
        XCTAssertEqual(arbiter.accurateProbeCount, 0)
        XCTAssertNil(arbiter.verdict)
    }

    // MARK: - B6: the Nemotron tally reaches the offline timeline

    /// `nemotronDistribution` used `init(rawValue:)` on tally keys, so a forty-minute tally of
    /// `"he-IL"` contributed nothing at all to the offline prior.
    func testNemotronTallyPriorSurvivesBCP47Keys() {
        let candidates: [TranscriptionLanguage] = [.hebrew, .english]
        let distribution = MeetingLanguageTimelineBuilder.nemotronDistribution(
            tally: ["he-IL": 300, "en": 20], candidates: candidates)
        XCTAssertNotNil(distribution, "A tally of only regional keys used to produce no prior at all")
        XCTAssertEqual(distribution?[0] ?? 0, 300.0 / 320.0, accuracy: 0.001)
    }

    // MARK: - The 2026-08-23 16:03 live session: locked English at 46 s and never came back

    /// The trapdoor. Once a wrong Latin lock is in force the eager decoder writes Latin text, and
    /// `applyScriptVeto` then removes Hebrew from the candidate set *entirely* — so the four
    /// subsequent V3 confirmations at he 0.97–0.99 could not win, because Hebrew was no longer
    /// something the fusion was allowed to consider.
    ///
    /// The veto is right to kill a spurious minority candidate with no textual presence. It must
    /// never kill the candidate the audio is loudest about, because that is precisely the
    /// configuration a wrong lock produces.
    func testScriptVetoCannotEraseTheAudioLeader() {
        let englishTranscript = "all the issues that we did that to them They were asking for "
            + "this. We talked about all things and it was They were helping to understand what"
        let probes = [
            probe(["en": 0.93, "he": 0.07], from: 0, to: 3),
            probe(["he": 0.99, "en": 0.01], from: 30, to: 33),
            probe(["he": 0.975, "en": 0.02], from: 60, to: 63),
            probe(["he": 0.974, "en": 0.02], from: 90, to: 93),
            probe(["he": 0.983, "en": 0.01], from: 120, to: 123),
        ]
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes, transcript: englishTranscript,
            allowedLanguages: [.hebrew, .english, .russian], duration: 150)
        XCTAssertEqual(timeline.dominant, .hebrew,
                       "Four V3 probes at 0.98 must outrank a transcript written by the lock under test")
    }

    /// The veto must still do its job: a candidate the audio is only lukewarm about, with no
    /// presence in the text, is exactly the spurious minority it exists to remove.
    func testScriptVetoStillDropsAWeakAbsentCandidate() {
        let hebrewTranscript = "שלום לכולם אני מקווה שאתם שומעים אותי טוב מאוד היום"
        let probes = [
            probe(["he": 0.80, "ru": 0.20], from: 0, to: 30),
            probe(["he": 0.75, "ru": 0.25], from: 30, to: 60),
        ]
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes, transcript: hebrewTranscript,
            allowedLanguages: [.hebrew, .russian], duration: 60)
        XCTAssertEqual(timeline.dominant, .hebrew)
    }

    /// `Detection: top=ar (p=0.319)` — the detector had no idea, and almost all of its mass sat
    /// outside the three-language shortlist. Renormalising over the shortlist turned that into
    /// `en 0.933`, and one probe locked a forty-minute meeting.
    func testProbeWhoseMassSitsOutsideTheShortlistIsNotEvidence() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english, .russian])
        arbiter.recordCoarse(probabilities: ["ar": 0.319, "fa": 0.21, "ur": 0.18, "tr": 0.09,
                                             "en": 0.05, "he": 0.004, "ru": 0.001],
                             start: 0, end: 3)
        XCTAssertEqual(arbiter.probeCount, 0, "A probe the shortlist barely covers says nothing about the shortlist")
    }

    func testProbeWithMostOfItsMassInTheShortlistIsKept() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english, .russian])
        arbiter.recordCoarse(probabilities: ["he": 0.748, "en": 0.11, "ar": 0.08, "ru": 0.02],
                             start: 0, end: 3)
        XCTAssertEqual(arbiter.probeCount, 1)
    }

    /// Even a clean probe must not lock a meeting on its own. The fused path replaced a 0.75
    /// threshold plus a short-window margin gate with, effectively, the argmax of the first probe.
    func testSingleProbeDoesNotProduceAVerdict() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english])
        arbiter.recordCoarse(probabilities: ["en": 0.93, "he": 0.07], start: 0, end: 3)
        XCTAssertNil(arbiter.fuse(transcript: "", allowedLanguages: [.hebrew, .english], duration: 3))
    }

    func testTwoAgreeingProbesDoProduceAVerdict() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english])
        arbiter.recordCoarse(probabilities: ["he": 0.93, "en": 0.07], start: 0, end: 3)
        arbiter.recordCoarse(probabilities: ["he": 0.90, "en": 0.10], start: 20, end: 23)
        XCTAssertEqual(arbiter.fuse(transcript: "", allowedLanguages: [.hebrew, .english], duration: 25)?.language,
                       .hebrew)
    }

    /// `Language confirmation (V3, low-confidence): top=ja p=0.261` — V3 itself had no opinion on
    /// that window. Recording it as an accurate probe both spends budget and adds noise.
    func testUnconfidentAccurateProbeIsNotRecorded() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english])
        arbiter.recordAccurate(probabilities: ["ja": 0.261, "he": 0.09, "en": 0.05], start: 0, end: 3)
        XCTAssertEqual(arbiter.probeCount, 0)
        XCTAssertEqual(arbiter.accurateProbeCount, 0, "A shrug is not a confirmation")
        XCTAssertEqual(arbiter.accurateSpend, 1, "…but the encoder pass was still paid for")
    }

    /// Being unrouted is itself expensive — every window before the first verdict is decoded
    /// unpinned — so the first confirmation must not wait the full inter-probe interval.
    func testFirstConfirmationComesEarlyWhileUnlocked() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english], longForm: true)
        let coarse: [String: Float] = ["he": 0.66, "en": 0.20]
        arbiter.recordCoarse(probabilities: coarse, start: 8, end: 11)
        XCTAssertEqual(arbiter.escalationReason(coarse: coarse, nemotronCode: nil,
                                                currentLock: nil, audioSeconds: 11), .lowConfidence)
        XCTAssertNil(arbiter.escalationReason(coarse: coarse, nemotronCode: nil,
                                              currentLock: .hebrew, audioSeconds: 11),
                     "A settled session keeps the full interval")
    }

    // MARK: - The live decoder's provisional language

    /// The eager stream used to decode every pre-route window with `.auto`, which whisper re-rolls
    /// per window: the 15:37 session came back `it`, `ru`, `he`, `fr` on four consecutive passes and
    /// each one was displayed. The arbiter already holds better evidence than any single window.
    func testLeadingCandidateIsAvailableBeforeAnyVerdict() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english, .russian], longForm: true)
        arbiter.recordCoarse(probabilities: ["he": 0.728, "ru": 0.12, "en": 0.10], start: 0, end: 3)

        XCTAssertNil(arbiter.fuse(transcript: "", allowedLanguages: [.hebrew, .english, .russian], duration: 3),
                     "One probe is still not a verdict")
        XCTAssertEqual(arbiter.leadingCandidate?.language, .hebrew,
                       "…but it is a far better argument to the decoder than .auto")
    }

    /// It must average the evidence rather than track the newest probe, so a single wandering window
    /// cannot flip the decoder mid-meeting.
    func testLeadingCandidateFollowsTheAccumulatedEvidenceNotTheLastProbe() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english, .french], longForm: true)
        arbiter.recordCoarse(probabilities: ["he": 0.86, "en": 0.10], start: 0, end: 3)
        arbiter.recordCoarse(probabilities: ["he": 0.73, "en": 0.20], start: 10, end: 13)
        arbiter.recordCoarse(probabilities: ["fr": 0.78, "he": 0.15], start: 20, end: 23)
        XCTAssertEqual(arbiter.leadingCandidate?.language, .hebrew)
    }

    func testLeadingCandidateIsNilWithNoEvidence() {
        let arbiter = LiveLanguageArbiter()
        arbiter.configure(allowedLanguages: [.hebrew, .english], longForm: true)
        XCTAssertNil(arbiter.leadingCandidate)
    }

    /// A hypothesis at absolute sample positions, 0.5 s per word.
    private func hypothesis(_ text: String, startSec: Double = 0) -> [EagerStreamWord] {
        text.split(separator: " ").enumerated().map { index, token in
            let start = startSec + Double(index) * 0.5
            return EagerStreamWord(text: " " + token, tokens: [],
                                   startIndex: Int(start * 16_000),
                                   endIndex: Int((start + 0.45) * 16_000),
                                   probability: 0.90)
        }
    }

    /// Unlocked means *provisional*: the engine still emits display text, but LocalAgreement-2
    /// never confirms, so nothing soft-commits and the ring is never pruned — the audio behind a
    /// wrong-language guess stays available to be re-decoded once the language is known.
    ///
    /// `StreamingTranscriber.applyEagerOutcome` used to pass `languageIsLocked: true`
    /// unconditionally, so the Italian, Russian and French windows decoded before the 15:37
    /// session routed were confirmed, committed and pruned — permanently.
    func testUnlockedEagerPassesDisplayTextButNeverCommit() {
        var engine = EagerStreamEngine()
        let words = hypothesis("questo è un test di verifica del sistema di trascrizione dal vivo")
        let end = words.last!.endIndex

        let first = engine.consume(hypothesis: words, audioBaseIndex: 0, languageIsLocked: false,
                                   lastCommittedIndex: 0, windowEndIndex: end)
        XCTAssertNotNil(first.displayText, "Preview must still show something")

        // The identical second pass is what LocalAgreement-2 confirms on.
        let second = engine.consume(hypothesis: words, audioBaseIndex: 0, languageIsLocked: false,
                                    lastCommittedIndex: 0, windowEndIndex: end)
        XCTAssertNotNil(second.displayText)
        XCTAssertTrue(engine.confirmedWords.isEmpty, "Nothing may be confirmed in an undecided language")
        XCTAssertNil(second.softCommit, "…and so nothing may be committed or pruned from the ring")
    }

    /// The same two passes with a decided language must behave exactly as before — the gate is the
    /// only thing that changed.
    func testLockedEagerPassesStillConfirm() {
        var engine = EagerStreamEngine()
        let words = hypothesis("שלום לכולם אני מקווה שאתם שומעים אותי טוב מאוד היום בבוקר")
        let end = words.last!.endIndex

        _ = engine.consume(hypothesis: words, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: end)
        _ = engine.consume(hypothesis: words, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: end)
        XCTAssertFalse(engine.confirmedWords.isEmpty)
    }

    // MARK: - C1: the refine validator

    func testValidatorAcceptsAMuchLongerCorrectDecode() {
        // The 15 → 328 char case: Nemotron dropped most of the speech, so the correct Hebrew is
        // legitimately 20× longer. The old length ratio rejected it for being right.
        let original = "Fasta I ci"
        let corrected = "לא יודע אנשים מצטרפים, כתבתי להם ואני מוודא שהם מצטרפים עכשיו. "
            + "בוא נתחיל מהחלק הראשון של הפגישה ואחר כך נעבור לשאלות שהעליתם אתמול במייל, "
            + "כי יש שם כמה דברים שצריך לסגור לפני סוף השבוע הזה."
        XCTAssertNil(MeetingTranscriptRefiner.rejectionReason(
            for: corrected, replacing: original, language: .hebrew))
    }

    func testValidatorRejectsWrongScript() {
        XCTAssertEqual(MeetingTranscriptRefiner.rejectionReason(
            for: "Fasta I ci recordinga Lze ho li Rod Sen Ti stekel A va",
            replacing: "שלום לכולם", language: .hebrew), .scriptMismatch)
    }

    func testValidatorRejectsTwoWordRepetitionLoop() {
        let loop = Array(repeating: "I'm okay.", count: 20).joined(separator: " ")
        XCTAssertEqual(MeetingTranscriptRefiner.rejectionReason(
            for: loop, replacing: "I think that's fine", language: .english), .repetitionLoop)
    }

    func testValidatorRejectsEmpty() {
        XCTAssertEqual(MeetingTranscriptRefiner.rejectionReason(
            for: "   ", replacing: "שלום לכולם", language: .hebrew), .empty)
    }

    /// The one length rule kept, and only against an original that itself passes the script check.
    func testValidatorRejectsCollapseOfGoodText() {
        let original = "שלום לכולם אני מקווה שאתם שומעים אותי טוב מאוד היום"
        XCTAssertEqual(MeetingTranscriptRefiner.rejectionReason(
            for: "שלום", replacing: original, language: .hebrew), .collapsed)
    }
}

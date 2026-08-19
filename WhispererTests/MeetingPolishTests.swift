//
//  MeetingPolishTests.swift
//  WhispererTests
//
//  Milestone 3: one editor, two callers.
//
//  The claim under test is not "meetings are polished" — it is that meetings are polished by the
//  *same* editor as dictation, invoked the same way, with no meeting-specific branch inside it.
//  That is what makes the end-of-meeting critical path the last utterance plus artifact synthesis
//  instead of a whole-transcript pass, and it is only sound because the editor reads no audio:
//  meetings run on Nemotron, which supplies `ASRCapabilities = []`.
//
//  The tests that touch the user's own meetings skip rather than fail when the local database is
//  absent — they are a check against real transcripts on this machine, not a CI gate. The parity
//  tests above them are synthetic and always run.
//

import XCTest
@testable import whisperer

final class MeetingPolishTests: XCTestCase {

    // MARK: - Arm selection

    /// These tests measure arm B, so the experimental switch has to be on for the duration.
    ///
    /// `MeetingSession` consults `PolishFeatureFlags` at each seam, and with the flag off — which
    /// is the shipped default and therefore what the test host starts with — meetings polish
    /// nothing at all, which is exactly the shipped behaviour and exactly what these tests are not
    /// about. Set here rather than inside the two tests that need it so the class describes which
    /// arm it measures in one place, and restored in `tearDown` so a run cannot leave the
    /// developer's own preferences flipped.
    private var savedFastPolish: Any?
    private var savedParagraphs: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedFastPolish = defaults.object(forKey: PolishFeatureFlags.fastPolishKey)
        savedParagraphs = defaults.object(forKey: PolishFeatureFlags.paragraphsKey)
        defaults.set(true, forKey: PolishFeatureFlags.fastPolishKey)
        defaults.set(true, forKey: PolishFeatureFlags.paragraphsKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.set(savedFastPolish, forKey: PolishFeatureFlags.fastPolishKey)
        defaults.set(savedParagraphs, forKey: PolishFeatureFlags.paragraphsKey)
        super.tearDown()
    }

    // MARK: - Editors

    /// Exactly what `AppState.applyLLMPostProcessing` builds for a dictation utterance: the user
    /// dictionary as the alias table, the same canonical spellings hard-protected, list reflow off
    /// because its call sites already ran `applyListFormatting`.
    ///
    /// Written out longhand rather than routed through `forTranscript` on purpose. If the two ever
    /// diverge, this literal is what notices — a test that called the factory twice would be
    /// asserting that a function equals itself.
    private func dictationEditor(entries: [DictionaryEntry] = []) -> DeterministicPolisher {
        DeterministicPolisher(
            aliases: AliasEngine(entries: entries),
            dictionaryTerms: Set(entries.map(\.correctForm)),
            formatsLists: false
        )
    }

    /// What `MeetingSession` runs per utterance as chunks arrive.
    ///
    /// `terminatesUtteranceEnd: false` mirrors `MeetingSession.rebuildEditors` exactly. A meeting
    /// utterance ends where the VAD cut, not where the speaker stopped, and the per-utterance text
    /// is accumulated into the card — so terminating here would stamp a period at every chunk
    /// boundary in the meeting whatever the speaker did. The card pass, which holds the pause map,
    /// is what closes the last sentence.
    private func meetingUtteranceEditor(entries: [DictionaryEntry] = []) -> DeterministicPolisher {
        DeterministicPolisher.forTranscript(dictionaryEntries: entries, formatsLists: false,
                                            terminatesUtteranceEnd: false,
                                            splitsParagraphs: true)
    }

    /// What `MeetingSession` runs once per card, at the endpoint.
    private func meetingCardEditor(entries: [DictionaryEntry] = []) -> DeterministicPolisher {
        DeterministicPolisher.forTranscript(dictionaryEntries: entries, formatsLists: true,
                                            splitsParagraphs: true)
    }

    /// The one intentional difference between the dictation utterance pass and the meeting one.
    ///
    /// It is a *configuration* difference, not a second editing policy: the same pipeline reads
    /// `terminatesUtteranceEnd` and declines to close the final sentence for meetings, for the
    /// reason spelled out on `meetingUtteranceEditor`. Everything before that final mark must still
    /// be character-identical, and that is the claim worth defending — asserting plain equality
    /// would now be asserting that meetings terminate utterances they have no evidence about.
    private func assertDiffersOnlyByTheFinalStop(meeting: String,
                                                 dictation: String,
                                                 _ message: String,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        guard dictation != meeting else { return }
        XCTAssertEqual(dictation, meeting + ".", message, file: file, line: line)
    }

    // MARK: - Corpus

    /// Utterance-shaped inputs covering what the two callers actually see: fillers, stutters,
    /// dictionary aliases, protected spans, a non-Latin script, a spoken enumeration.
    private let utterances = [
        "okay um so we should uh ship the the release on friday",
        "send the deployment to chat gpt and update postgress",
        "check https://example.com/a_b then call loadModel on the v2.1.0 build",
        "צריך להריץ את loadModel על ה-server",
        "first update the docs second run the migration third tell the team",
        "не не надо это делать",
        "let's revisit budget 3.5 million next quarter",
    ]

    private func meetingFixtures() throws -> [MeetingFixture] {
        let fixtures = HistoryTestLoader.loadMeetingFixtures(maxCount: 10)
        try XCTSkipIf(fixtures.isEmpty, "No meetings in the local history database")
        return fixtures
    }

    // MARK: - One editor, two callers

    func testMeetingUtteranceAndDictationUtteranceProduceIdenticalOutput() {
        let dictation = dictationEditor()
        let meeting = meetingUtteranceEditor()

        for utterance in utterances {
            let fromDictation = dictation.polish(text: utterance)
            let fromMeeting = meeting.polish(text: utterance)
            assertDiffersOnlyByTheFinalStop(meeting: fromMeeting.text,
                                            dictation: fromDictation.text, utterance)
            // Same slack on the edit log, and no more: the terminator is at most one edit.
            XCTAssertTrue((fromDictation.appliedEdits.count - fromMeeting.appliedEdits.count) == 0
                          || (fromDictation.appliedEdits.count - fromMeeting.appliedEdits.count) == 1,
                          "\(utterance): \(fromMeeting.appliedEdits.count) vs "
                          + "\(fromDictation.appliedEdits.count)")
            // The residual decision has to match too: a meeting that asked for a generative pass
            // where dictation did not would be a second policy wearing the first one's name. Asked
            // of the *terminating* configuration, because `needsGenerativePass` fires on a missing
            // terminal mark and the meeting utterance is unterminated by design — its own flag is
            // true by construction and says nothing. Nothing reads it on the meetings path; it is
            // diagnostic on the dictation path alone (`AppState.applyLLMPostProcessing`).
            let terminating = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                                  formatsLists: false,
                                                                  splitsParagraphs: true)
            XCTAssertEqual(terminating.polish(text: utterance).needsGenerativePass,
                           fromDictation.needsGenerativePass, utterance)
        }
    }

    /// The same claim against the user's own meetings, segment by segment — real transcripts carry
    /// disfluencies and spellings no synthetic string thinks to include.
    func testRealMeetingSegmentsPolishIdenticallyForBothCallers() throws {
        let fixtures = try meetingFixtures()
        let dictation = dictationEditor()
        let meeting = meetingUtteranceEditor()

        var segmentCount = 0
        for fixture in fixtures {
            for segment in fixture.segments {
                assertDiffersOnlyByTheFinalStop(
                    meeting: meeting.polish(text: segment.text).text,
                    dictation: dictation.polish(text: segment.text).text,
                    "\(fixture.id): \(segment.text.prefix(60))")
                segmentCount += 1
            }
        }
        XCTAssertGreaterThan(segmentCount, 0, "fixtures decoded but held no segments")
    }

    // MARK: - Streaming contract

    /// Live/mid-stream versus authoritative. The two configurations differ in exactly two things —
    /// enumeration reflow and whether the final sentence may be closed — and both are declared
    /// flags on the same pipeline rather than branches inside it. `ListFormatter` is a pure
    /// function of the rendered text, so with the terminator flag held equal the card pass must be
    /// the live pass with that function applied. Anything else means a second editing policy has
    /// grown on the endpoint path.
    func testLiveAndCardEditorsDifferOnlyInListReflowAndTheFinalStop() {
        let live = meetingUtteranceEditor()
        let card = meetingCardEditor()
        // The live editor with the card's answer to the one other question, so this test measures
        // reflow alone and the terminator is measured by the assertion below it.
        let liveTerminating = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                                  formatsLists: false,
                                                                  splitsParagraphs: true)

        for utterance in utterances {
            XCTAssertEqual(card.polish(text: utterance).text,
                           ListFormatter.format(liveTerminating.polish(text: utterance).text),
                           utterance)
            assertDiffersOnlyByTheFinalStop(meeting: live.polish(text: utterance).text,
                                            dictation: liveTerminating.polish(text: utterance).text,
                                            utterance)
        }
    }

    /// The mid-stream half of the contract stated as a property: nothing the live pass does can
    /// introduce a word. It deletes fillers, collapses whitespace and substitutes a spelling the
    /// user typed — it never punctuates, respells from context, or writes grammar.
    func testLivePassNeverInventsWords() {
        let live = meetingUtteranceEditor()
        for utterance in utterances {
            let before = utterance.split(whereSeparator: \.isWhitespace).count
            let after = live.polish(text: utterance).text.split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(after, before, utterance)
        }
    }

    // MARK: - The session actually calls it

    // Both tests below are `async` for a reason that has nothing to do with what they assert: they
    // are the only tests here that *allocate* a main-actor-isolated object, and this project builds
    // with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every class is main-actor isolated and
    // every `deinit` goes through `swift_task_deinitOnExecutorImpl`. On the current toolchain that
    // runtime entry point corrupts the heap when it runs with no current `AsyncTask` — the
    // `TaskLocal::StopLookupScope` it opens frees a pointer it never allocated, and the process
    // dies with `malloc: pointer being freed was not allocated` before any assertion is reached.
    // A synchronous `@MainActor` XCTest method is exactly that context: XCTest invokes it through
    // `NSInvocation` on the main thread, outside any task. An `async` test body runs inside a task,
    // the scope allocates and frees on the task allocator, and the release is clean. Verified with
    // a bare `final class { }` holding no state — nothing about `MeetingSession` or the editor is
    // involved, and every other `@MainActor` test in this suite is already `async` for the same
    // reason. Do not make these synchronous again.

    /// The wiring, not the editor: a chunk handed to `MeetingSession.onNewChunk` must land in the
    /// open card already polished. Without this the parity tests above would pass over an editor
    /// meetings never invoke.
    ///
    /// Driven without a CoreData meeting behind it: `meetingID` is what `accumulate` guards on, and
    /// with `isRecording` true and a four-second chunk nothing reaches the persistence path. The
    /// teardown drops `isRecording` so the 2.5s silence flush this schedules bails out instead of
    /// committing a card for a meeting row that does not exist.
    @MainActor
    func testMeetingChunkIsPolishedOnArrival() async {
        let session = MeetingSession()
        let id = UUID()
        session.meetingID = id
        session.isRecording = true
        defer {
            session.isRecording = false
            MeetingPendingStore.clear(meetingID: id)
        }

        let raw = "okay um so we should uh ship the the release on friday"
        session.onNewChunk(text: raw, start: 0, end: 4)

        // Snapshot taken here rather than before the chunk: `MeetingSession` builds its editors
        // from `DictionaryManager.shared.entries`, which loads asynchronously at first access.
        let expected = meetingUtteranceEditor(entries: DictionaryManager.shared.entries)
            .polish(text: raw).text
        XCTAssertEqual(session.currentSegmentText, expected)
        XCTAssertNotEqual(session.currentSegmentText, raw, "the chunk reached the card unpolished")
        XCTAssertFalse(session.currentSegmentText.contains(" um "), session.currentSegmentText)
    }

    /// The live tail takes the same route. `AppState`'s preview callbacks assign it directly, so
    /// the polish has to live in the property rather than at the call site.
    @MainActor
    func testLiveTailIsPolishedOnAssignment() async {
        let session = MeetingSession()
        let raw = "  and um then we  merge it  "
        session.livePreviewText = raw

        let expected = meetingUtteranceEditor(entries: DictionaryManager.shared.entries)
            .polish(text: raw.trimmingCharacters(in: .whitespacesAndNewlines)).text
        XCTAssertEqual(session.livePreviewText, expected)
        XCTAssertFalse(session.livePreviewText.contains("um "), session.livePreviewText)
        XCTAssertFalse(session.livePreviewText.contains("  "), "whitespace survived the live pass")

        session.livePreviewText = ""
        XCTAssertEqual(session.livePreviewText, "", "clearing the tail must not resurrect text")
    }

    // MARK: - ASRCapabilities = []

    /// Meetings are the `[]` column. The editor must treat the absence of every acoustic signal as
    /// nothing to consult — not as a missing input to fail on, and not as a reason to edit
    /// differently — or the whole plan is wrong for the one backend it was written to cover.
    func testEmptyCapabilitiesIsACleanNoOpNotAnError() {
        let polisher = DeterministicPolisher()

        for utterance in utterances {
            let blind = polisher.polish(TokenGraph.from(text: utterance, capabilities: []))
            let sighted = polisher.polish(TokenGraph.from(text: utterance, capabilities: .whisperCpp))

            XCTAssertEqual(blind.text, sighted.text, utterance)
            XCTAssertEqual(blind.appliedEdits.count, sighted.appliedEdits.count, utterance)
            XCTAssertEqual(blind.needsGenerativePass, sighted.needsGenerativePass, utterance)
            XCTAssertFalse(blind.text.isEmpty, "polishing produced nothing for: \(utterance)")
        }
    }

    func testEmptyCapabilitiesIsACleanNoOpOnRealMeetings() throws {
        let fixtures = try meetingFixtures()
        let polisher = DeterministicPolisher()

        for fixture in fixtures {
            for segment in fixture.segments where !segment.text.isEmpty {
                let blind = polisher.polish(TokenGraph.from(text: segment.text, capabilities: []))
                let sighted = polisher.polish(TokenGraph.from(text: segment.text, capabilities: .whisperCpp))
                XCTAssertEqual(blind.text, sighted.text, fixture.id)
                XCTAssertFalse(blind.text.isEmpty, "\(fixture.id): a segment polished to nothing")
            }
        }
    }

    // MARK: - Protection

    /// A meeting transcript is where protected spans are most likely to appear and least likely to
    /// be noticed: nobody rereads an hour of notes to check that a repo path survived.
    func testProtectedSpansSurviveAMeetingTranscript() {
        let card = meetingCardEditor()
        let transcript = "so the fix is in anthropics/whisperer we tag it v2.1.0 and deploy "
                       + "with docker run --rm -it after loadModel returns"

        // The sentence-initial capital is expected and is not a protection failure: `so` is an
        // ordinary token, and `SentenceCaser` capitalizing the opening word is the pass doing its
        // job. What must survive untouched is every protected span, so that is what is asserted —
        // an equality against the whole input would be asserting that the editor does nothing,
        // which is a different and much weaker claim than the one this test is named for.
        // The trailing period is `SentenceTerminator` closing a whole card at the endpoint, which
        // is the same category of expected edit as the opening capital: structure, not content.
        let polished = card.polish(text: transcript).text
        XCTAssertEqual(polished, "So the fix is in anthropics/whisperer we tag it v2.1.0 and "
                                 + "deploy with docker run --rm -it after loadModel returns.")
        for span in ["anthropics/whisperer", "v2.1.0", "docker run --rm -it", "loadModel"] {
            XCTAssertTrue(polished.contains(span), "protected span '\(span)' did not survive")
        }
    }

    /// Digits are hard-protected, so the strongest statement available over a real corpus is that
    /// no meeting segment loses one. A dropped digit is the failure a reader cannot recover from —
    /// a wrong date or a wrong number reads as fact.
    func testRealMeetingSegmentsKeepEveryDigit() throws {
        let fixtures = try meetingFixtures()
        let card = meetingCardEditor()

        for fixture in fixtures {
            for segment in fixture.segments {
                let before = segment.text.filter(\.isNumber)
                guard !before.isEmpty else { continue }
                let after = card.polish(text: segment.text).text.filter(\.isNumber)
                XCTAssertEqual(after, before, "\(fixture.id): \(segment.text.prefix(60))")
            }
        }
    }
}

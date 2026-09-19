//
//  MeetingOverviewParserTests.swift
//  WhispererTests
//
//  Unit tests for MeetingOverviewParser — the line-based parser for
//  LLM-generated meeting overviews.
//

import XCTest
@testable import whisperer

final class MeetingOverviewParserTests: XCTestCase {

    // MARK: - Basic parsing

    func testParsesMinimalOutput() {
        let raw = """
        OVERVIEW: The team reviewed the sprint backlog.
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.overview, "The team reviewed the sprint backlog.")
        XCTAssertTrue(result?.keyTopics.isEmpty ?? false)
        XCTAssertNil(result?.nextMeeting)
    }

    func testParsesFullOutput() {
        let raw = """
        OVERVIEW: The speaker demonstrated transcription issues and tested the system.
        TOPIC: Transcription experience | 9
        TOPIC: Voice capture quality | 28
        DECISION: Fix UX | Improve the transcription experience before release | 45
        OPEN: Why does the voice not change? | 28
        NEXT: Friday — continue testing
        ACTION: Review transcription code | Alex Ivy | 2026-08-15
        """
        guard let result = MeetingOverviewParser.parse(raw) else {
            XCTFail("parse returned nil"); return
        }
        XCTAssertFalse(result.overview.isEmpty)
        XCTAssertEqual(result.keyTopics.count, 2)
        XCTAssertEqual(result.keyTopics[0].text, "Transcription experience")
        XCTAssertEqual(result.keyTopics[0].timestampSeconds, 9)
        XCTAssertEqual(result.decisions.count, 1)
        XCTAssertEqual(result.decisions[0].label, "Fix UX")
        XCTAssertEqual(result.openQuestions.count, 1)
        XCTAssertEqual(result.nextMeeting, "Friday — continue testing")
        XCTAssertEqual(result.actionItems.count, 1)
        XCTAssertEqual(result.actionItems[0].ownerName, "Alex Ivy")
        XCTAssertEqual(result.actionItems[0].dueLabel, "2026-08-15")
    }

    func testNextMeetingNone() {
        let raw = """
        OVERVIEW: Short stand-up with no follow-up scheduled.
        NEXT: none
        """
        XCTAssertNil(MeetingOverviewParser.parse(raw)?.nextMeeting)
    }

    func testNextMeetingNoneVariant() {
        let raw = """
        OVERVIEW: Quick sync call.
        NEXT: None
        """
        XCTAssertNil(MeetingOverviewParser.parse(raw)?.nextMeeting)
    }

    func testNextMeetingPresent() {
        let raw = """
        OVERVIEW: Budget review meeting.
        NEXT: Next Tuesday 10am — review Q3 budget
        """
        XCTAssertEqual(MeetingOverviewParser.parse(raw)?.nextMeeting, "Next Tuesday 10am — review Q3 budget")
    }

    // MARK: - Robustness

    func testIgnoresUnknownPrefixes() {
        let raw = """
        OVERVIEW: The meeting covered design updates.
        NOTE: This is not a known prefix.
        TOPIC: Design system | 15
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertEqual(result?.keyTopics.count, 1)
    }

    func testHandlesEmptyLines() {
        let raw = """

        OVERVIEW: The meeting covered design updates.

        TOPIC: Design system | 15

        NEXT: none

        """
        XCTAssertNotNil(MeetingOverviewParser.parse(raw))
    }

    func testReturnsNilWhenNoOverview() {
        let raw = """
        TOPIC: Design system | 15
        NEXT: none
        """
        XCTAssertNil(MeetingOverviewParser.parse(raw), "overview is required — no OVERVIEW: line → nil")
    }

    func testActionWithNoDue() {
        let raw = """
        OVERVIEW: Planning meeting.
        NEXT: none
        ACTION: Send report | Bob Smith | none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertEqual(result?.actionItems.count, 1)
        XCTAssertNil(result?.actionItems.first?.dueLabel)
        XCTAssertEqual(result?.actionItems.first?.ownerName, "Bob Smith")
    }

    func testTopicWithNoTimestamp() {
        let raw = """
        OVERVIEW: Kickoff.
        TOPIC: Project scope | invalid
        NEXT: none
        """
        // Falls back to 0 seconds when timestamp can't be parsed
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertEqual(result?.keyTopics.first?.timestampSeconds, 0)
    }

    // MARK: - Partial output (LLM truncation)

    func testHandlesTruncatedOutput_overviewOnly() {
        let raw = """
        OVERVIEW: The speaker tested the transcription system for two minutes.
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result, "A lone OVERVIEW line should produce a valid summary")
        XCTAssertFalse(result!.overview.isEmpty)
        XCTAssertTrue(result!.keyTopics.isEmpty)
    }

    func testHandlesTruncatedOutput_overviewAndTopics() {
        // Simulates timeout after topics but before decisions
        let raw = """
        OVERVIEW: Budget meeting with three agenda items.
        TOPIC: Q3 budget | 10
        TOPIC: Headcount | 45
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyTopics.count, 2)
        XCTAssertTrue(result?.decisions.isEmpty ?? false)
    }

    // MARK: - Multi-language

    func testParsesHebrewOverview() {
        let raw = """
        OVERVIEW: הצוות דן בתקציב הרבעון הרביעי ובלוח הזמנים לשחרור.
        TOPIC: תקציב | 0
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.overview.isEmpty)
    }

    func testParsesRussianOverview() {
        let raw = """
        OVERVIEW: Команда обсудила дорожную карту продукта на следующий квартал.
        NEXT: нет
        """
        // "нет" is not "none" — will be kept as nextMeeting value (that's fine, language-agnostic)
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
    }

    // MARK: - Model formatting drift
    //
    // Both cases below are verbatim shapes measured in LLMModelComparisonTests, not
    // hypotheticals: Qwen2.5-1.5B emits `**OVERVIEW:**` on the full prompt, and both it and
    // Qwen3.5-4B drop the label entirely on a short note. Each used to return nil, which
    // shows the user an empty Overview card.

    func testParsesMarkdownDecoratedLabels() {
        let raw = """
        **OVERVIEW:**

        The speaker walks through how machine learning relates to AI.
        - It is a subfield, in the way thermodynamics is a subfield of physics.

        ## TOPIC: definitions | 12
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result, "A bolded label must not discard the whole summary")
        XCTAssertTrue(result!.overview.contains("machine learning"))
        XCTAssertEqual(result?.keyTopics.count, 1)
        XCTAssertEqual(result?.keyTopics.first?.timestampSeconds, 12)
    }

    func testUnlabeledProseBecomesTheOverview() {
        let raw = "Speaker 1 instructs to press Open to launch the meeting."
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result, "A note-length reply with no label is still the overview")
        XCTAssertEqual(result?.overview, raw)
        XCTAssertTrue(result?.keyTopics.isEmpty ?? false)
    }

    func testLabeledOverviewWinsOverPrecedingProse() {
        // The fallback must not fire when a real OVERVIEW exists — a preamble the model
        // emitted before the label is not the summary.
        let raw = """
        Sure, here is the summary you asked for:
        OVERVIEW: The team agreed to ship on Friday.
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertEqual(result?.overview, "The team agreed to ship on Friday.")
    }

    // MARK: - Degenerate output
    //
    // The structural gate — parses, timestamps in range, non-empty — passed a decode that had
    // collapsed into a loop, so `TOPIC: the speaker is the is the is the` logged "parsed
    // successfully" and was persisted as a summary. The decoder's own guard counts identical
    // *consecutive* tokens and a two-token cycle never trips it, so the content check lives here.

    /// The shape actually observed in the logs, verbatim.
    func testDropsLoopingTopicButKeepsCleanOverview() {
        let raw = """
        OVERVIEW: The speaker demonstrated the transcription bug and described how to reproduce it.
        TOPIC: the speaker is the is the is the is the | 12
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result, "A looping TOPIC must not take the whole summary down with it")
        XCTAssertTrue(result!.overview.contains("transcription bug"))
        XCTAssertTrue(result!.keyTopics.isEmpty, "the looping topic should be dropped, not shown")
    }

    func testTrimsLoopingOverviewBackToLastCompleteSentence() {
        let raw = """
        OVERVIEW: The team reviewed the release checklist and agreed on Friday. \
        to Michael to Michael to Michael to Michael
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.overview, "The team reviewed the release checklist and agreed on Friday.")
    }

    func testRejectsOverviewThatIsNothingButALoop() {
        // Nothing survives the trim, so there is no summary — an empty Overview card is
        // honest; a card reading "is the is the is the" is not.
        let raw = "OVERVIEW: is the is the is the is the is the"
        XCTAssertNil(MeetingOverviewParser.parse(raw))
    }

    func testDropsLoopingDecisionAndAction() {
        let raw = """
        OVERVIEW: Planning session covering scope and owners.
        DECISION: ship date | we ship we ship we ship we ship | 40
        ACTION: send the send the send the send the | Bob Smith | none
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.decisions.isEmpty)
        XCTAssertTrue(result!.actionItems.isEmpty)
    }

    // The gate has to be quiet on real prose, in every language the app summarizes in —
    // a false positive silently deletes a working summary, which is worse than the loop.

    func testKeepsHealthyEnglishProse() {
        let raw = """
        OVERVIEW: The team reviewed the Q3 budget and the hiring plan. The budget is up 12 percent \
        year over year, and the team agreed that the extra 3.5 million goes to infrastructure. \
        Hiring stays flat until the next review, and the team will revisit the plan in October.
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.overview.contains("October"), "healthy prose must survive intact")
    }

    func testKeepsHealthyRussianProse() {
        // Russian inflection repeats function words far more than English does — the reason the
        // gate matches consecutive n-grams rather than scoring a distinct-word ratio.
        let raw = """
        OVERVIEW: Команда обсудила бюджет на третий квартал и план найма. Бюджет вырос на \
        двенадцать процентов, и команда согласилась, что дополнительные средства пойдут на \
        инфраструктуру. План найма остаётся без изменений до следующего пересмотра в октябре.
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.overview.contains("октябре"))
    }

    func testKeepsHealthyHebrewProse() {
        let raw = """
        OVERVIEW: הצוות סקר את התקציב לרבעון השלישי ואת תוכנית הגיוס. התקציב גדל בשנים עשר אחוזים, \
        והצוות הסכים שהתוספת תופנה לתשתיות. תוכנית הגיוס נשארת ללא שינוי עד הפגישה הבאה באוקטובר.
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.overview.contains("באוקטובר"))
    }

    func testKeepsShortEmphaticRepetition() {
        // Three consecutive identical words is speech, not a decode failure. Only a run of
        // five trips the single-word rule.
        let raw = "OVERVIEW: The speaker said the experience is really, really, really off."
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.overview.contains("really, really, really"))
    }

    // MARK: - Numbered format (rung 0/1 ladder)

    func testNumberedTitleOnlyParsesToNil() {
        // The exact map-reduce failure mode: model writes only the title line and EOS.
        // parse() must return nil so the ladder can escalate.
        let raw = "1| פגישת טכנולוגיה על רגרסיות ופילטרים"
        XCTAssertNil(MeetingOverviewParser.parse(raw),
                     "A lone 1| title line without a 3| overview must parse to nil")
    }

    func testNumberedTitleAndOverviewParsesSuccessfully() {
        // Simulates the rung-1 assistant-prefill output: model receives "1| <title>\n3| "
        // and continues from there. The result must parse and include both title and overview.
        let raw = """
        1| Technology Meeting on Regressions and Filters
        3| The team discussed a series of regressions introduced in the last sprint \
        and evaluated the new filter pipeline. Two root causes were identified.
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result, "1| + 3| artifact should parse successfully")
        XCTAssertFalse(result?.overview.isEmpty ?? true, "overview must not be empty")
        let title = MeetingOverviewParser.title(in: raw)
        XCTAssertEqual(title, "Technology Meeting on Regressions and Filters",
                       "title(in:) must extract the 1| line")
    }

    // MARK: - sanitizedOverview

    func testSanitizedOverviewTrimsLoops() {
        // A long repetition spiral must be cut — same logic as truncatingLoop.
        let loopy = String(repeating: "word word word word word ", count: 80)
        let result = MeetingOverviewParser.sanitizedOverview(loopy)
        // Either nil (fully degenerate) or significantly shorter than the input.
        if let r = result {
            XCTAssertLessThan(r.count, loopy.count / 2, "loop must be truncated")
        }
    }

    func testSanitizedOverviewRejectsTimestampDense() {
        // Prose full of [Ns] markers is raw transcript echo, not a summary.
        let dense = "[0s] First thing. [5s] Second thing. [10s] Third thing. [15s] Fourth. " +
                    "[20s] Fifth. [25s] Sixth. [30s] Seventh. [35s] Eighth. [40s] Ninth. " +
                    "[45s] Tenth. [50s] Eleventh. [55s] Twelfth. [60s] Thirteenth item discussed."
        let result = MeetingOverviewParser.sanitizedOverview(dense)
        XCTAssertNil(result, "timestamp-dense prose must be rejected by sanitizedOverview")
    }

    func testSanitizedOverviewPassesHealthyProse() {
        let prose = "The team reviewed the Q3 budget and agreed that extra funds go to infrastructure."
        let result = MeetingOverviewParser.sanitizedOverview(prose)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("infrastructure") ?? false)
    }
}

// MARK: - Prompt variant tests

final class MeetingAIServicePromptTests: XCTestCase {

    func testCondensedKeyPointsPromptDoesNotMentionSpeechTranscript() {
        let req = MeetingAIService.overviewRequest(
            transcriptWords: 300,
            language: .auto,
            inputKind: .condensedKeyPoints
        )
        XCTAssertFalse(
            req.systemPrompt.contains("speech-to-text transcript"),
            "condensedKeyPoints prompt must not tell the model the input is a raw transcript"
        )
    }

    func testTranscriptPromptMentionsSpeechTranscript() {
        let req = MeetingAIService.overviewRequest(
            transcriptWords: 300,
            language: .auto,
            inputKind: .transcript
        )
        XCTAssertTrue(
            req.systemPrompt.contains("speech-to-text transcript"),
            "transcript prompt should describe the input as a speech-to-text transcript"
        )
    }

    func testBothVariantsContainNumberedFormat() {
        for kind in [MeetingAIService.OverviewInputKind.transcript, .condensedKeyPoints] {
            let req = MeetingAIService.overviewRequest(transcriptWords: 300, language: .auto, inputKind: kind)
            XCTAssertTrue(
                req.systemPrompt.contains("3|"),
                "Both prompt variants must contain the 3| overview format block — kind=\(kind)"
            )
        }
    }

    func testTierRecomputationFromCondensedWords() {
        // 900-word original triggers the `default` tier. After map step condenses to ~340
        // words, the request must drop to a smaller band — NOT remain at `default` (≥700).
        let originalReq = MeetingAIService.overviewRequest(transcriptWords: 900, language: .auto)
        let condensedReq = MeetingAIService.overviewRequest(
            transcriptWords: 340,
            language: .auto,
            inputKind: .condensedKeyPoints
        )
        XCTAssertGreaterThan(
            originalReq.outputTokensHint,
            condensedReq.outputTokensHint,
            "condensed input should request fewer output tokens than the full-tier original"
        )
        XCTAssertFalse(condensedReq.isNote,
                       "condensed request for a real meeting must never become isNote")
    }

    func testTinyMapOutputNeverBecomesNote() {
        // If map step produces only 20 words (severely underperformed), clamping to 60
        // should prevent isNote from being selected.
        let clampedWords = max(60, 20)
        let req = MeetingAIService.overviewRequest(
            transcriptWords: clampedWords,
            language: .auto,
            inputKind: .condensedKeyPoints
        )
        XCTAssertFalse(req.isNote,
                       "clamped condensed request must not select the isNote tier")
    }
}

//
//  MeetingArtifactTests.swift
//  WhispererTests
//
//  The merged meeting artifact: one generation emitting TITLE, TOPIC, OVERVIEW and the
//  DECISION / OPEN / NEXT / ACTION lines, over evidence selected from the transcript.
//
//  Two things here are regression gates rather than unit tests:
//    - the title must be readable from a *partial* stream, long before the summary lands,
//      because merging the two passes otherwise delays naming a recording by a minute;
//    - `EvidenceSelector` must stay inside its token budget and must carry segment IDs
//      through, because a DECISION with no resolvable source cannot be played back.
//

import XCTest
@testable import whisperer

final class MeetingArtifactTests: XCTestCase {

    // MARK: - Fixtures

    private static let fullArtifact = """
    TITLE: Events table database choice
    TOPIC: Comparing Postgres and DynamoDB | 30
    TOPIC: Migration ownership | 610
    OVERVIEW: Postgres and DynamoDB were compared for the events table. Postgres won on the ad-hoc queries the analytics team runs weekly.

    Cost was close enough at the current 40 GB that it decided nothing, and they agreed to look again past 500 GB.
    DECISION: Events store | Postgres for the events table | 240
    OPEN: Who owns the nightly export if the table grows past 500 GB? | 700
    NEXT: Thursday, same room
    ACTION: Write the migration plan | Sara | Friday
    """

    private static func segment(
        at seconds: Double, _ text: String, id: UUID = UUID()
    ) -> MeetingSegment {
        MeetingSegment(id: id, timestamp: seconds, endTimestamp: seconds + 5, text: text)
    }

    // MARK: - Parsing the merged output

    func testParsesFullMergedArtifact() {
        let raw = Self.fullArtifact
        XCTAssertEqual(MeetingOverviewParser.title(in: raw), "Events table database choice")

        guard let summary = MeetingOverviewParser.parse(raw) else {
            return XCTFail("merged artifact did not parse")
        }
        XCTAssertEqual(summary.keyTopics.count, 2)
        XCTAssertEqual(summary.keyTopics.first?.text, "Comparing Postgres and DynamoDB")
        XCTAssertEqual(summary.keyTopics.last?.timestampSeconds, 610)
        XCTAssertEqual(summary.decisions.count, 1)
        XCTAssertEqual(summary.decisions.first?.label, "Events store")
        XCTAssertEqual(summary.decisions.first?.timestampSeconds, 240)
        XCTAssertEqual(summary.openQuestions.count, 1)
        XCTAssertEqual(summary.nextMeeting, "Thursday, same room")
        XCTAssertEqual(summary.actionItems.first?.ownerName, "Sara")

        // The TITLE line must not be absorbed into the overview, and the overview must keep
        // its paragraph break — the two-paragraph shape is what the length rules ask for.
        XCTAssertFalse(summary.overview.contains("Events table database choice"))
        XCTAssertTrue(summary.overview.hasPrefix("Postgres and DynamoDB were compared"))
        XCTAssertTrue(summary.overview.contains("\n\n"))
        XCTAssertFalse(summary.overview.contains("DECISION"))
    }

    func testTolerantOfPluralAndSummaryLabels() {
        let raw = """
        TITLE: Weekly planning sync
        TOPICS: Roadmap review | 15
        SUMMARY: The team walked the roadmap and moved the billing work to next quarter.
        NEXT: none
        """
        guard let summary = MeetingOverviewParser.parse(raw) else {
            return XCTFail("aliased labels did not parse")
        }
        XCTAssertEqual(summary.keyTopics.first?.text, "Roadmap review")
        XCTAssertEqual(summary.overview, "The team walked the roadmap and moved the billing work to next quarter.")
        XCTAssertNil(summary.nextMeeting)
    }

    func testOverviewWinsOverSummaryWhenBothPresent() {
        let raw = """
        TITLE: Two summaries
        OVERVIEW: The real overview, written where it was asked for.
        SUMMARY: A duplicate the model added on its own.
        """
        XCTAssertEqual(
            MeetingOverviewParser.parse(raw)?.overview,
            "The real overview, written where it was asked for."
        )
    }

    // MARK: - Streaming the title

    func testTitleIsReadableBeforeTheRestOfTheArtifactArrives() {
        let raw = Self.fullArtifact
        var firstHit: Int? = nil
        for length in 1...raw.count where firstHit == nil {
            if MeetingOverviewParser.firstCompleteTitle(in: String(raw.prefix(length))) != nil {
                firstHit = length
            }
        }
        guard let firstHit else { return XCTFail("title never surfaced from the stream") }

        let seen = String(raw.prefix(firstHit))
        XCTAssertEqual(
            MeetingOverviewParser.firstCompleteTitle(in: seen), "Events table database choice"
        )
        // The whole point of the streamed title: nothing after the first line is needed.
        XCTAssertFalse(seen.contains("OVERVIEW:"))
        XCTAssertFalse(seen.contains("TOPIC:"))
        XCTAssertEqual(seen.filter { $0 == "\n" }.count, 1)
    }

    func testPartialTitleLineIsNotUsedUntilComplete() {
        // Every prefix that stops inside the title line must yield nothing — half a title is
        // a worse name than the placeholder it would replace.
        for partial in ["", "TI", "TITLE:", "TITLE: Events table datab"] {
            XCTAssertNil(
                MeetingOverviewParser.firstCompleteTitle(in: partial),
                "\"\(partial)\" should not have produced a title"
            )
        }
    }

    func testStreamWithoutTitleDegradesSafely() {
        let raw = """
        OVERVIEW: The speaker walked through the deployment checklist and flagged two gaps.
        NEXT: none
        """
        for length in 1...raw.count {
            XCTAssertNil(MeetingOverviewParser.firstCompleteTitle(in: String(raw.prefix(length))))
        }
        XCTAssertNil(MeetingOverviewParser.title(in: raw))
        // The summary itself still parses — a missing title costs the name, not the artifact.
        XCTAssertTrue(MeetingOverviewParser.parse(raw)?.overview.hasPrefix("The speaker walked") ?? false)
    }

    func testTitleEmittedLateInTheStreamIsIgnored() {
        // A TITLE line that shows up after the overview has started is the model losing the
        // format, not a name — taking it would rename the recording from its own summary.
        let raw = """
        OVERVIEW: Something was discussed at length.
        TITLE: Not a title we should trust
        """
        XCTAssertNil(MeetingOverviewParser.firstCompleteTitle(in: raw))
    }

    // MARK: - Multilingual artifacts

    func testHebrewArtifactParses() {
        let raw = """
        TITLE: בחירת מסד נתונים לטבלת האירועים
        TOPIC: השוואה בין פוסטגרס לדינמו | 30
        OVERVIEW: הצוות השווה בין פוסטגרס לדינמו עבור טבלת האירועים, והעדיף את פוסטגרס בגלל השאילתות השבועיות של צוות האנליטיקה.
        DECISION: מסד נתונים | נבחר פוסטגרס לטבלת האירועים | 240
        OPEN: מי אחראי על הייצוא הלילי? | 700
        ACTION: לכתוב מסמך הגירה | דניאל | יום שישי
        """
        XCTAssertEqual(MeetingOverviewParser.title(in: raw), "בחירת מסד נתונים לטבלת האירועים")

        guard let summary = MeetingOverviewParser.parse(raw) else {
            return XCTFail("Hebrew artifact did not parse")
        }
        XCTAssertTrue(summary.overview.hasPrefix("הצוות השווה"))
        XCTAssertEqual(summary.keyTopics.count, 1)
        XCTAssertEqual(summary.decisions.first?.timestampSeconds, 240)
        XCTAssertEqual(summary.openQuestions.count, 1)
        XCTAssertEqual(summary.actionItems.first?.ownerName, "דניאל")
    }

    func testRussianArtifactParses() {
        let raw = """
        TITLE: Выбор базы данных для таблицы событий
        TOPIC: Сравнение Postgres и DynamoDB | 30
        OVERVIEW: Команда сравнила Postgres и DynamoDB для таблицы событий и выбрала Postgres из-за еженедельных аналитических запросов.
        DECISION: База данных | Выбрали Postgres | 240
        OPEN: Кто отвечает за ночной экспорт? | 700
        NEXT: В четверг в той же переговорной
        ACTION: Написать план миграции | Сара | пятница
        """
        XCTAssertEqual(MeetingOverviewParser.title(in: raw), "Выбор базы данных для таблицы событий")

        guard let summary = MeetingOverviewParser.parse(raw) else {
            return XCTFail("Russian artifact did not parse")
        }
        XCTAssertTrue(summary.overview.hasPrefix("Команда сравнила"))
        XCTAssertEqual(summary.decisions.first?.label, "База данных")
        XCTAssertEqual(summary.nextMeeting, "В четверг в той же переговорной")
        XCTAssertEqual(summary.actionItems.first?.ownerName, "Сара")
    }

    // MARK: - Evidence selection

    /// A meeting long enough that the whole transcript cannot fit: mostly filler, with a
    /// handful of decisions, actions and questions planted at known offsets.
    private func longMeeting() -> (segments: [MeetingSegment], plantedIDs: [UUID]) {
        var segments = [MeetingSegment]()
        var planted = [UUID]()
        for i in 0..<400 {
            let t = Double(i) * 9
            switch i {
            case 120:
                let id = UUID()
                planted.append(id)
                segments.append(Self.segment(at: t, "So we decided to use Redis for caching the session lookups.", id: id))
            case 240:
                let id = UUID()
                planted.append(id)
                segments.append(Self.segment(at: t, "I'll write the migration plan and send it out before Friday.", id: id))
            case 300:
                let id = UUID()
                planted.append(id)
                segments.append(Self.segment(at: t, "Open question: how do we handle the nightly export at 500 GB?", id: id))
            default:
                segments.append(Self.segment(at: t, "yeah um right so like well anyway yeah"))
            }
        }
        return (segments, planted)
    }

    func testSelectionStaysInsideTheTokenBudget() {
        let (segments, _) = longMeeting()
        let budget = 1_500
        let evidence = EvidenceSelector.select(segments, tokenBudget: budget)

        XCTAssertLessThanOrEqual(evidence.estimatedTokens, budget)
        XCTAssertFalse(evidence.isEmpty)
        XCTAssertFalse(evidence.isComplete, "a 400-utterance meeting should not fit in 1500 tokens")
        XCTAssertLessThanOrEqual(
            EvidenceSelector.estimatedTokens(of: evidence.transcriptText()),
            budget + evidence.lines.count,   // rendering adds the newlines the per-line cost reserved
            "rendered evidence overran the budget"
        )
    }

    func testSelectionPreservesUtteranceIdentity() {
        let (segments, planted) = longMeeting()
        let evidence = EvidenceSelector.select(segments, tokenBudget: 1_500)

        let selected = evidence.lines.map { $0.segmentID }
        XCTAssertEqual(Set(selected).count, selected.count, "an utterance was selected twice")
        let source = Set(segments.map { $0.id })
        XCTAssertTrue(Set(selected).isSubset(of: source), "selection invented a segment ID")

        // Every decision / action / question that was planted must survive: they are what the
        // DECISION and ACTION lines are extracted from, and a dropped one cannot be recovered.
        for id in planted {
            XCTAssertTrue(selected.contains(id), "a cue-bearing utterance was dropped")
        }

        // Timestamp order, and the text that comes back is the text that went in.
        XCTAssertEqual(evidence.lines.map { $0.timestamp }, evidence.lines.map { $0.timestamp }.sorted())
        for line in evidence.lines {
            let source = segments.first { $0.id == line.segmentID }
            XCTAssertEqual(line.text, source?.text)
            XCTAssertEqual(line.timestamp, source?.timestamp)
        }
    }

    func testSelectionIsDeterministic() {
        let (segments, _) = longMeeting()
        let first  = EvidenceSelector.select(segments, tokenBudget: 1_500)
        let second = EvidenceSelector.select(segments, tokenBudget: 1_500)
        XCTAssertEqual(first.lines, second.lines)
        XCTAssertEqual(first.transcriptText(), second.transcriptText())
    }

    func testShortMeetingIsPassedThroughWhole() {
        let segments = (0..<12).map { i in
            Self.segment(at: Double(i) * 20, "This is utterance number \(i) about the release checklist.")
        }
        let evidence = EvidenceSelector.select(segments)
        XCTAssertTrue(evidence.isComplete)
        XCTAssertEqual(evidence.lines.map { $0.segmentID }, segments.map { $0.id })
        XCTAssertFalse(evidence.transcriptText().contains("…"), "nothing was dropped, so there is no gap to mark")
        XCTAssertTrue(evidence.transcriptText().hasPrefix("[0s] This is utterance number 0"))
    }

    func testDroppedStretchesAreMarked() {
        let (segments, _) = longMeeting()
        let evidence = EvidenceSelector.select(segments, tokenBudget: 1_500)
        XCTAssertTrue(
            evidence.transcriptText().contains("\n…\n"),
            "a gap between kept utterances must be marked so the model does not read them as consecutive"
        )
    }

    func testEmptyTranscriptSelectsNothing() {
        let evidence = EvidenceSelector.select([Self.segment(at: 0, "   ")])
        XCTAssertTrue(evidence.isEmpty)
        XCTAssertEqual(evidence.estimatedTokens, 0)
        XCTAssertEqual(evidence.transcriptText(), "")
    }

    func testBudgetSmallerThanOneUtteranceStillReturnsOne() {
        let (segments, _) = longMeeting()
        let evidence = EvidenceSelector.select(segments, tokenBudget: 1)
        XCTAssertEqual(evidence.lines.count, 1, "an empty selection would summarize an empty transcript")
    }

    // MARK: - Output budget

    func testTitleAllowanceIsAddedToEveryBand() {
        // One budget path: the title allowance rides on the same tiers as the summary, so a
        // tuning change to either cannot leave the merged artifact truncated mid-title.
        let allowance = MeetingAIService.titleTokenAllowance
        XCTAssertEqual(MeetingAIService.overviewRequest(transcriptWords: 20).outputTokensHint, 300 + allowance)
        XCTAssertEqual(MeetingAIService.overviewRequest(transcriptWords: 200).outputTokensHint, 700 + allowance)
        XCTAssertEqual(MeetingAIService.overviewRequest(transcriptWords: 500).outputTokensHint, 1100 + allowance)
        XCTAssertEqual(MeetingAIService.overviewRequest(transcriptWords: 5000).outputTokensHint, 1600 + allowance)
    }

    func testEveryBandAsksForATitle() {
        for words in [20, 200, 500, 5000] {
            let request = MeetingAIService.overviewRequest(transcriptWords: words)
            XCTAssertTrue(
                request.systemPrompt.contains("TITLE:"),
                "the \(words)-word band would produce an artifact with no name"
            )
        }
    }
}

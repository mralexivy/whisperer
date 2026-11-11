//
//  MeetingSeriesTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingSeriesTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Jerusalem")!; c.locale = Locale(identifier: "en_US"); return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func item(_ title: String, _ date: Date) -> MeetingListItem {
        MeetingListItem(id: UUID(), title: title, language: "en", createdAt: date, duration: 1800)
    }

    func testWeeklyOneOnOneIsASeriesAndOneOffsAreNot() {
        let items = [item("Alex / Keren - Weekly", at(2026, 11, 10)), item("Alex / Keren - Weekly", at(2026, 11, 3)),
                     item("Alex / Keren - Weekly", at(2026, 10, 27)), item("Interview: Staff Engineer", at(2026, 11, 9)),
                     item("Unscheduled Zoom meeting · 11:24", at(2026, 11, 8)), item("Unscheduled Zoom meeting · 11:24", at(2026, 11, 7))]
        let (series, oneOffs) = MeetingSeries.group(items, calendar: calendar)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].meetings.count, 3)
        XCTAssertEqual(series[0].meetings.first?.createdAt, at(2026, 11, 10), "newest first")
        XCTAssertEqual(series[0].cadence.label(calendar: calendar), "Weekly · Tue")
        XCTAssertEqual(oneOffs.count, 3, "the interview and the app's placeholder titles stay out of series")
    }

    func testDatesTimesAndCountersAreIgnored() {
        XCTAssertEqual(MeetingSeries.key(for: "Weekly sync · 11:24"), "weekly sync")
        XCTAssertEqual(MeetingSeries.key(for: "Weekly sync - Nov 10"), "weekly sync")
        XCTAssertEqual(MeetingSeries.key(for: "Weekly sync 2026-11-10"), "weekly sync")
        XCTAssertEqual(MeetingSeries.key(for: "Weekly  Sync (2)"), "weekly sync")
        XCTAssertEqual(MeetingSeries.key(for: "שיחת צוות שבועית"), "שיחת צוות שבועית")
        XCTAssertNil(MeetingSeries.key(for: "Meeting"))
        XCTAssertNil(MeetingSeries.key(for: "Unscheduled call in Chrome · 09:12"))
    }

    func testCadences() {
        XCTAssertEqual(MeetingSeries.cadence((0..<5).map { at(2026, 11, 2 + $0) }, calendar: calendar), .daily)
        XCTAssertEqual(MeetingSeries.cadence([at(2026, 10, 13), at(2026, 10, 27), at(2026, 11, 10)], calendar: calendar), .biweekly)
        XCTAssertEqual(MeetingSeries.cadence([at(2026, 9, 1), at(2026, 10, 1), at(2026, 11, 2)], calendar: calendar), .monthly)
        XCTAssertEqual(MeetingSeries.cadence([at(2026, 9, 1), at(2026, 11, 2)], calendar: calendar), .recurring)
    }

    /// A skipped week and a rescheduled day keep it weekly, on the usual weekday.
    func testWeeklyToleratesASkipAndAMove() {
        let dates = [at(2026, 10, 6), at(2026, 10, 13), at(2026, 10, 21), at(2026, 10, 27), at(2026, 11, 10)]
        XCTAssertEqual(MeetingSeries.cadence(dates, calendar: calendar).label(calendar: calendar), "Weekly · Tue")
    }
}

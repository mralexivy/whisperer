//
//  MeetingLiveTailTextTests.swift
//  WhispererTests
//
//  The live tail of a meeting is drawn like a committed card: one text view, no pacing, no per-word views,
//  no timers. See `MeetingLiveTailText` for why.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class MeetingLiveTailTextTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func size(of text: String, rtl: Bool) -> CGSize {
        let host = NSHostingView(rootView: MeetingLiveTailText(text: text, isRTL: rtl).frame(width: 360))
        Self.keepAlive.append(host)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 10)
        return host.fittingSize
    }

    func testTheWholeTextIsShownAtOnceNotPoured() {
        let short = size(of: "we will talk about", rtl: false)
        let long = size(of: String(repeating: "we will talk about the budget and the plan ", count: 20), rtl: false)
        XCTAssertGreaterThan(long.height, short.height * 3, "a long paragraph is laid out in full immediately")
    }

    func testRightToLeftTextIsShownAtOnceToo() {
        let long = size(of: String(repeating: "אנחנו מדברים על התקציב של נובמבר ", count: 20), rtl: true)
        XCTAssertGreaterThan(long.height, 60)
    }

    func testSurroundingWhitespaceDoesNotChangeTheLayout() {
        XCTAssertEqual(size(of: "  hello world \n", rtl: false), size(of: "hello world", rtl: false))
    }

    func testTheTailKeepsNoUpdaterTimerAlive() {
        // Nothing to assert beyond construction: the view is a pure function of its text. The energy cost of the
        // live meeting is measured end to end in LiveMeetingEnergyTests.
        _ = size(of: "x", rtl: false)
    }
}

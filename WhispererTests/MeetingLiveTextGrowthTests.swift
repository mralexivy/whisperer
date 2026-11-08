//
//  MeetingLiveTextGrowthTests.swift
//  WhispererTests
//
//  The live meeting bubble must grow with its text. In Hebrew it was sized once from its first
//  words: after one row every new word wrapped out of sight until the paragraph became a card.
//  Hosted in a real window at the meeting window's width.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class MeetingLiveTextGrowthTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    final class Source: ObservableObject { @Published var text = "" }

    private struct Host: View {
        @ObservedObject var source: Source
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                MeetingSegmentTextView(text: source.text, highlightQuery: "", isRTL: true)
                Spacer(minLength: 0)
            }
            .frame(width: 320, height: 600)
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func field(in view: NSView) -> NSTextField? {
        if let f = view as? NSTextField { return f }
        for sub in view.subviews { if let f = field(in: sub) { return f } }
        return nil
    }

    func testHebrewLiveTextGrowsAsWordsArrive() throws {
        let source = Source()
        let hosting = NSHostingView(rootView: Host(source: source))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 320, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [source, hosting, window]

        source.text = "מגיע לבית המשפט מולאן"
        pump(0.5)
        let oneLine = try XCTUnwrap(field(in: hosting)).frame.height

        source.text = "מגיע לבית המשפט מולאן באולם ההורים שהפקידו את הילדים, ואז אנחנו מדברים על התקציב של נובמבר ועל יחידת העסקים והצוות המסחרי"
        pump(0.5)
        let grown = try XCTUnwrap(field(in: hosting)).frame.height
        XCTAssertGreaterThan(grown, oneLine * 2.5,
                             "the live text stayed \(grown) pt tall (one line was \(oneLine) pt) — new words are clipped")
    }
}

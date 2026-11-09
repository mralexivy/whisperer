//
//  MeetingLiveTailSnapshotTests.swift
//  WhispererTests
//
//  Opt-in visual check of the meeting live bubble while its front words leave for a card:
//  writes frames mid-animation to TEST_RUNNER_LIVE_TAIL_SNAPSHOT. Words used to be drawn over
//  each other there ("feplconfident") with a ghost copy of the paragraph.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class MeetingLiveTailSnapshotTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    final class Source: ObservableObject { @Published var text = "" }

    private struct Host: View {
        @ObservedObject var source: Source
        var body: some View {
            VStack(alignment: .leading) {
                MeetingLiveTailText(text: source.text, isRTL: false).padding(16)
                Spacer(minLength: 0)
            }
            .frame(width: 380, height: 420)
            .background(Color(hex: "14142B"))
        }
    }

    func testFramesWhileTheFrontLeaves() throws {
        guard let dir = ProcessInfo.processInfo.environment["LIVE_TAIL_SNAPSHOT"] else {
            throw XCTSkip("set TEST_RUNNER_LIVE_TAIL_SNAPSHOT")
        }
        let source = Source()
        let hosting = NSHostingView(rootView: Host(source: source))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 380, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [source, hosting, window]

        func pump(_ s: TimeInterval) {
            let until = Date().addingTimeInterval(s)
            while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        }
        func shot(_ name: String) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }

        let words = ("we feel pretty confident that from like security and data handling requirement our perspective "
            + "those are met we feel pretty confident about that but if there's still anything open on your side "
            + "or any concerns of course we also want to address that and make sure you guys are comfortable").split(separator: " ").map(String.init)
        var shown = Array(words.prefix(20))
        source.text = shown.joined(separator: " ")
        pump(1.5)
        shot("1-before")
        // The first eight words became a card while two new ones arrived.
        shown = Array(words[8..<22])
        source.text = shown.joined(separator: " ")
        pump(0.03); shot("2-mid-30ms")
        pump(0.05); shot("3-mid-80ms")
        pump(1.0); shot("4-after")
    }
}

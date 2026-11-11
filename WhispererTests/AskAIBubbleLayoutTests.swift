//
//  AskAIBubbleLayoutTests.swift
//  WhispererTests
//
//  A long question shows in full and a long answer stays inside its bubble, above its sources.
//  Both were sized from their first line (2026-11-10). TEST_RUNNER_ASKAI_SNAPSHOT=<dir> writes a PNG.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class AskAIBubbleLayoutTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func fields(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let f = view as? NSTextField { out.append(f) }
        for sub in view.subviews { out += fields(in: sub) }
        return out
    }

    func testLongQuestionAndAnswerAreShownInFull() async throws {
        let id = UUID()
        let question = "Give me detailed interview summary as i giving feedback as interviewer background, summary of interview pros and cons and real feedback based on sr. engineer and background as staff"
        let answer = (1...8).map { "- Point \($0): the candidate discussed consumer failures and rebalancing, database choices, media storage and feed caching in reasonable depth." }.joined(separator: "\n\n")
        await MeetingChatStore.shared.append(MeetingChatMessage(role: "user", text: question), meetingID: id)
        await MeetingChatStore.shared.append(MeetingChatMessage(
            role: "assistant", text: answer,
            sources: [RAGChunk(text: "source", startTimestamp: 10, endTimestamp: 20, speakers: ["Alex"], score: 0)],
            answeredBy: "Codex"), meetingID: id)
        let record = MeetingRecord(id: id, title: "Interview", language: "en", modelUsed: "v3")
        let hosting = NSHostingView(rootView: AskAIPane(meeting: record).frame(width: 420, height: 1100)
            .background(Color(hex: "0E0E1F")))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 420, height: 1100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [hosting, window]
        // Yield the main actor (the pane loads its history in a main-actor task) and let layout run.
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(50)); hosting.layoutSubtreeIfNeeded() }

        if let dir = ProcessInfo.processInfo.environment["ASKAI_SNAPSHOT"],
           let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("askai.png"))
        }
        await MeetingChatStore.shared.clear(meetingID: id)

        let all = fields(in: hosting)
        let q = try XCTUnwrap(all.first { $0.stringValue == question })
        let a = try XCTUnwrap(all.first { $0.stringValue == answer })
        for field in [q, a] {
            let needed = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: .greatestFiniteMagnitude)).height ?? 0
            XCTAssertGreaterThanOrEqual(field.bounds.height + 1, needed, "text clipped: \(field.stringValue.prefix(30))")
        }
    }
}

//
//  MeetingTranscriptHandoffTests.swift
//  WhispererTests
//
//  The transcript pane must still show text after the end-of-meeting handoff: the live
//  transcript (every segment, auto-scrolled to the bottom) is replaced by the saved one (a first
//  page of fresh segments from the refine pass). On 2026-11-08 a 53-minute Hebrew meeting showed
//  a blank pane at that moment while the tab badge said 119 segments; switching meetings and
//  back brought the text back. Hosted in a real window so AppKit's scroll view and the
//  NSTextView-backed transcript lay out exactly as in the app.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class MeetingTranscriptHandoffTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    final class Source: ObservableObject {
        @Published var segments: [MeetingSegment] = []
    }

    private struct Host: View {
        @ObservedObject var source: Source
        let session: MeetingSession
        let search: TranscriptSearchModel
        var body: some View {
            MeetingTranscriptView(
                meeting: nil,
                session: session,
                segments: source.segments,
                isLoadingSegments: false,
                hasMoreSegments: false,
                onLoadMoreSegments: {},
                search: search,
                playheadSeconds: 0)
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private func segments(_ count: Int, text: (Int) -> String) -> [MeetingSegment] {
        (0..<count).map { i in
            MeetingSegment(timestamp: Double(i) * 20, endTimestamp: Double(i) * 20 + 18,
                           text: text(i), speakerName: i % 3 == 0 ? "Speaker 2" : "Speaker 1",
                           speakerIndex: i % 3 == 0 ? 1 : 0)
        }
    }

    // MARK: - The whole detail screen, through the end of a meeting

    private func runDetailHandoff(liveCount: Int, savedCount: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let id = UUID()
        var stored = MeetingRecord(id: id, title: "Alex / Keren - Weekly", language: "auto", modelUsed: "qwen3")
        let vm = MeetingDetailViewModel(fetcher: { _ in stored })
        let session = MeetingSession()
        let hosting = NSHostingView(rootView: MeetingDetailView(detailVM: vm, session: session, playheadSeconds: 0))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [vm, session, hosting, window]

        // The meeting is selected when it starts, so the view model loads it empty.
        let selected = expectation(description: "selected")
        Task { await vm.select(id); selected.fulfill() }
        wait(for: [selected], timeout: 5)

        // Live: the session streams its segments into the open meeting.
        session.meetingID = id
        session.isRecording = true
        session.segments = segments(liveCount) { i in "OK is Sasha and Keren, kilo engineering business unit \(i)." }
        pump(1.5)
        if let scrollView = find(NSScrollView.self, in: hosting), let doc = scrollView.documentView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - scrollView.contentView.bounds.height)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        pump(0.5)

        // Stop, then the saved transcript lands (end of recording / refine pass).
        session.isRecording = false
        pump(0.5)
        stored.segments = segments(savedCount) { i in "אנחנו מדברים על התקציב של נובמבר, סעיף \(i)." }
        stored.isInProgress = false
        NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: id)
        pump(2.0)

        XCTAssertEqual(vm.allSegments.count, savedCount, "precondition: the view model holds the saved transcript", file: file, line: line)
        let textView = try XCTUnwrap(find(NSTextView.self, in: hosting), "no transcript text view", file: file, line: line)
        XCTAssertFalse(textView.string.isEmpty, "transcript text view is empty", file: file, line: line)
        XCTAssertFalse(textView.visibleRect.isEmpty,
                       "transcript is not on screen (text frame=\(textView.frame), visible=\(textView.visibleRect))",
                       file: file, line: line)
    }

    /// The 2026-11-08 sequence from the log: stop with 119 segments, then the fine-tuning pass
    /// rewrites the same segments into Hebrew in place, saving every few windows, with its sweep
    /// animation running in the view the whole time.
    func testDetailStaysVisibleWhileFineTuningRewritesTheTranscript() throws {
        let id = UUID()
        var stored = MeetingRecord(id: id, title: "Alex / Keren - Weekly", language: "auto", modelUsed: "qwen3")
        let vm = MeetingDetailViewModel(fetcher: { _ in stored })
        let session = MeetingSession()
        let hosting = NSHostingView(rootView: MeetingDetailView(detailVM: vm, session: session, playheadSeconds: 0))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [vm, session, hosting, window]
        defer { MeetingTranscriptRefiner.shared.setRunStateForTesting(meetingID: nil) }

        let selected = expectation(description: "selected")
        Task { await vm.select(id); selected.fulfill() }
        wait(for: [selected], timeout: 5)

        let live = segments(119) { i in "OK is Sasha and Keren, kilo engineering business unit \(i)." }
        session.meetingID = id
        session.isRecording = true
        session.segments = live
        pump(1.0)
        session.isRecording = false
        stored.segments = live
        stored.isInProgress = false
        NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: id)
        pump(1.0)

        let textView = try XCTUnwrap(find(NSTextView.self, in: hosting), "no transcript text view")
        XCTAssertFalse(textView.visibleRect.isEmpty, "precondition: transcript visible after stop")

        // Fine-tuning: same segment IDs, text rewritten into Hebrew window by window.
        var working = live
        for batch in 0..<4 {
            let range = (batch * 30)..<min((batch + 1) * 30, working.count)
            MeetingTranscriptRefiner.shared.setRunStateForTesting(
                meetingID: id, active: [working[range.upperBound - 1].id],
                done: Set(working[..<range.lowerBound].map(\.id)))
            for i in range {
                working[i].rawText = working[i].text
                working[i].text = "אנחנו מדברים על התקציב של נובמבר ועל יחידת העסקים, סעיף \(i)."
            }
            stored.segments = working
            NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: id)
            pump(1.5)
            let current = try XCTUnwrap(find(NSTextView.self, in: hosting), "no transcript text view in batch \(batch)")
            XCTAssertFalse(current.string.isEmpty, "batch \(batch): text view emptied")
            XCTAssertFalse(current.visibleRect.isEmpty,
                           "batch \(batch): transcript off screen (frame=\(current.frame), visible=\(current.visibleRect))")
        }
    }

    func testDetailShowsSavedTranscriptWhenLiveHadMoreSegments() throws {
        try runDetailHandoff(liveCount: 150, savedCount: 119)
    }

    func testDetailShowsSavedTranscriptWhenLiveHadFewerSegments() throws {
        try runDetailHandoff(liveCount: 90, savedCount: 119)
    }

    func testRefinedTranscriptIsVisibleAfterTheLiveOneWasScrolledToTheBottom() throws {
        let source = Source()
        let session = MeetingSession()
        let search = TranscriptSearchModel()
        let hosting = NSHostingView(rootView: Host(source: source, session: session, search: search))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [source, session, search, hosting, window]

        // The live meeting: a long transcript, read at its end.
        source.segments = segments(150) { i in
            "Engineering business unit alignment and the product roadmap for November, item \(i), "
                + "with the commercial team and the budget review that follows it."
        }
        pump(1.5)
        let scrollView = try XCTUnwrap(find(NSScrollView.self, in: hosting), "no scroll view")
        let documentHeight = try XCTUnwrap(scrollView.documentView).frame.height
        let clip = scrollView.contentView
        XCTAssertGreaterThan(documentHeight, clip.bounds.height * 3, "live transcript should be several screens tall")
        clip.scroll(to: NSPoint(x: 0, y: documentHeight - clip.bounds.height))
        scrollView.reflectScrolledClipView(clip)
        pump(0.5)
        XCTAssertGreaterThan(clip.bounds.origin.y, documentHeight / 2, "precondition: scrolled to the end")

        // The handoff: the refine pass's first page of fresh Hebrew segments replaces it.
        source.segments = segments(20) { i in "אנחנו מדברים על התקציב של נובמבר ועל יחידת העסקים, סעיף \(i)." }
        pump(2.0)

        let textView = try XCTUnwrap(find(NSTextView.self, in: hosting), "no transcript text view")
        XCTAssertFalse(textView.string.isEmpty, "the new transcript must be in the text view")
        XCTAssertGreaterThan(textView.frame.height, 40, "the text view must be laid out, not collapsed")
        XCTAssertFalse(textView.visibleRect.isEmpty,
                       "the transcript must be on screen after the handoff, not scrolled out of view "
                       + "(clip y=\(clip.bounds.origin.y), document h=\(scrollView.documentView?.frame.height ?? -1), "
                       + "text frame=\(textView.frame))")
    }
}

//
//  MeetingTranscriptScrollPerformanceTests.swift
//  WhispererTests
//
//  Scrolling a meeting's transcript must be smooth. Hosted in a real window: a re-render, a
//  scroll step of the transcript alone and of the whole meeting screen must each cost well under
//  a frame. The full screen was 37 ms a step (2026-11-08) — an endless search-highlight loop.
//

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class MeetingTranscriptScrollPerformanceTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    final class Driver: ObservableObject { @Published var tick: Double = 0 }

    private struct Host: View {
        @ObservedObject var driver: Driver
        let session: MeetingSession
        let search: TranscriptSearchModel
        let segments: [MeetingSegment]
        var body: some View {
            MeetingTranscriptView(meeting: nil, session: session, segments: segments,
                                  isLoadingSegments: false, hasMoreSegments: false,
                                  onLoadMoreSegments: {}, search: search, playheadSeconds: driver.tick)
        }
    }

    /// What one re-render of the transcript costs. Hover, playhead and search all re-render it;
    /// during a scroll that happens continuously, so one re-render must be far below a frame.
    func testReRenderIsCheapAndDoesNotReLayout() throws {
        let session = MeetingSession()
        let search = TranscriptSearchModel()
        let driver = Driver()
        let segments = (0..<119).map { i in
            MeetingSegment(timestamp: Double(i) * 20, endTimestamp: Double(i) * 20 + 18,
                           text: "אנחנו מדברים על התקציב של נובמבר ועל יחידת העסקים, והצוות המסחרי ימשיך מכאן, סעיף \(i).",
                           speakerName: i % 2 == 0 ? "Alex" : "Keren", speakerIndex: i % 2)
        }
        let hosting = NSHostingView(rootView: Host(driver: driver, session: session, search: search, segments: segments))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [session, search, driver, hosting, window]
        pump(1.5)

        let before = SelectableTranscriptView.metricsRecomputeCount
        var worst = 0.0, total = 0.0
        for i in 1...80 {
            let started = CACurrentMediaTime()
            driver.tick = Double(i) * 0.25
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let ms = (CACurrentMediaTime() - started) * 1000
            worst = max(worst, ms); total += ms
            pump(0.005)
        }
        let recomputes = SelectableTranscriptView.metricsRecomputeCount - before
        print(String(format: "[ScrollPerf] 80 re-renders: mean %.2f ms, worst %.2f ms, %d full re-measures",
                     total / 80, worst, recomputes))
        XCTAssertEqual(recomputes, 0, "a re-render with unchanged text re-laid out the transcript \(recomputes) times")
        XCTAssertLessThan(total / 80, 8, "a re-render must cost well under a 60 fps frame (Debug build; Release is ~3x faster)")
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    /// What a scroll step costs: move the clip view 30 pt and draw what that exposes.
    func testScrollStepIsCheap() throws {
        let session = MeetingSession()
        let search = TranscriptSearchModel()
        let segments = (0..<119).map { i in
            MeetingSegment(timestamp: Double(i) * 20, endTimestamp: Double(i) * 20 + 18,
                           text: "אנחנו מדברים על התקציב של נובמבר ועל יחידת העסקים, והצוות המסחרי ימשיך מכאן, סעיף \(i). "
                               + "הדבר הבא ברשימה הוא התכנון של הרבעון הבא והחלוקה בין הצוותים.",
                           speakerName: i % 2 == 0 ? "Alex" : "Keren", speakerIndex: i % 2)
        }
        let view = MeetingTranscriptView(meeting: nil, session: session, segments: segments,
                                         isLoadingSegments: false, hasMoreSegments: false,
                                         onLoadMoreSegments: {}, search: search, playheadSeconds: 0)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [session, search, hosting, window]
        pump(1.5)

        let scrollView = try XCTUnwrap(find(NSScrollView.self, in: hosting))
        let clip = scrollView.contentView
        var worst = 0.0, total = 0.0, steps = 0
        var y: CGFloat = 0
        let maxY = (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height
        while y + 30 < maxY, steps < 200 {
            y += 30
            let started = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            let ms = (CACurrentMediaTime() - started) * 1000
            worst = max(worst, ms); total += ms; steps += 1
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        print(String(format: "[ScrollPerf] %d scroll steps: mean %.2f ms, worst %.2f ms", steps, total / Double(max(steps, 1)), worst))
        XCTAssertGreaterThan(steps, 50, "transcript should be long enough to scroll")
        XCTAssertLessThan(total / Double(max(steps, 1)), 4, "a scroll step must cost well under a frame")
    }

    /// The same scroll on the whole meeting screen, as the user sees it.
    func testScrollStepOnTheFullMeetingScreenIsCheap() throws {
        let id = UUID()
        var record = MeetingRecord(id: id, title: "Alex / Keren - Weekly", language: "he", modelUsed: "qwen3")
        record.isInProgress = false
        record.segments = (0..<119).map { i in
            MeetingSegment(timestamp: Double(i) * 20, endTimestamp: Double(i) * 20 + 18,
                           text: "אנחנו מדברים על התקציב של נובמבר ועל יחידת העסקים, והצוות המסחרי ימשיך מכאן, סעיף \(i). "
                               + "הדבר הבא ברשימה הוא התכנון של הרבעון הבא והחלוקה בין הצוותים.",
                           speakerName: i % 2 == 0 ? "Alex" : "Keren", speakerIndex: i % 2, language: "he")
        }
        let stored = record
        let vm = MeetingDetailViewModel(fetcher: { _ in stored })
        let session = MeetingSession()
        let hosting = NSHostingView(rootView: MeetingDetailView(detailVM: vm, session: session, playheadSeconds: 0))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1100, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [vm, session, hosting, window]
        let selected = expectation(description: "selected")
        Task { await vm.select(id); selected.fulfill() }
        wait(for: [selected], timeout: 5)
        // Load every page, as a long scroll does.
        while vm.hasMoreSegments { vm.loadMoreSegments() }
        pump(1.5)

        let scrollView = try XCTUnwrap(find(NSScrollView.self, in: hosting))
        let clip = scrollView.contentView
        var worst = 0.0, total = 0.0, steps = 0
        var y: CGFloat = 0
        let maxY = (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height
        while y + 30 < maxY, steps < 200 {
            y += 30
            let started = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            let ms = (CACurrentMediaTime() - started) * 1000
            worst = max(worst, ms); total += ms; steps += 1
        }
        print(String(format: "[ScrollPerf] full screen, %d steps: mean %.2f ms, worst %.2f ms", steps, total / Double(max(steps, 1)), worst))
        XCTAssertGreaterThan(steps, 50)
        XCTAssertLessThan(total / Double(max(steps, 1)), 4)
    }

    /// The loop behind the 37 ms scroll steps: `report` with nothing changed must not republish
    /// `currentIndex`, which the transcript's highlight pass listens to and answers with `report`.
    func testRepeatedReportDoesNotRepublishTheCursor() {
        let model = TranscriptSearchModel()
        var emissions = 0
        let token = model.$currentIndex.dropFirst().sink { _ in emissions += 1 }
        for _ in 0..<5 { model.report(located: [], contentHeight: 1200) }
        XCTAssertEqual(emissions, 0, "nil written over nil republished the cursor \(emissions) times")
        token.cancel()
    }
}

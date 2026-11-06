//
//  MeetingDetailLoadingTests.swift
//  WhispererTests
//
//  The workspace must always show the selected meeting's transcript — on first appear,
//  after fast switching, and when the transcript is saved after the meeting was opened.
//  Regression tests for "the transcript is empty until I click another meeting and back".
//

import XCTest
@testable import whisperer

/// Fetcher whose responses the test releases one by one, to reproduce out-of-order loads.
@MainActor
final class ControlledFetcher {
    var records: [UUID: MeetingRecord] = [:]
    private var waiting: [(UUID, CheckedContinuation<Void, Never>)] = []
    var calls: [UUID] = []
    var holdResponses = false

    func fetch(_ id: UUID) async -> MeetingRecord? {
        calls.append(id)
        if holdResponses {
            await withCheckedContinuation { waiting.append((id, $0)) }
        }
        return records[id]
    }

    /// Lets the pending fetch for `id` return.
    func release(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: i).1.resume()
    }

    var pending: Int { waiting.count }
}

@MainActor
final class MeetingDetailLoadingTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func record(_ title: String, lines: [String]) -> MeetingRecord {
        var r = MeetingRecord(title: title, language: "en", modelUsed: "test")
        r.segments = lines.enumerated().map { i, t in
            MeetingSegment(timestamp: Double(i * 5), endTimestamp: Double(i * 5 + 4), text: t)
        }
        return r
    }

    private func make() -> (MeetingDetailViewModel, ControlledFetcher) {
        let fetcher = ControlledFetcher()
        let vm = MeetingDetailViewModel(fetcher: { [fetcher] id in await fetcher.fetch(id) })
        Self.keepAlive += [vm, fetcher]
        return (vm, fetcher)
    }

    /// Lets queued main-actor work run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testFreshViewModelLoadsAnAlreadySelectedMeeting() async {
        // The selection survives tab switches; the view model does not.
        let (vm, fetcher) = make()
        let a = record("A", lines: ["hello from A"])
        fetcher.records[a.id] = a
        await vm.select(a.id)
        XCTAssertEqual(vm.meeting?.id, a.id)
        XCTAssertEqual(vm.displayedSegments.map(\.text), ["hello from A"])
        XCTAssertFalse(vm.isLoading)
    }

    func testSelectingTheShownMeetingAgainDoesNotRefetch() async {
        let (vm, fetcher) = make()
        let a = record("A", lines: ["x"])
        fetcher.records[a.id] = a
        await vm.select(a.id)
        await vm.select(a.id)
        XCTAssertEqual(fetcher.calls, [a.id])
        XCTAssertEqual(vm.displayedSegments.count, 1, "re-selecting keeps the transcript on screen")
    }

    func testLateOlderLoadNeitherWinsNorEndsTheSkeleton() async {
        let (vm, fetcher) = make()
        let a = record("A", lines: ["from A"]), b = record("B", lines: ["from B"])
        fetcher.records = [a.id: a, b.id: b]
        fetcher.holdResponses = true

        let loadA = Task { await vm.select(a.id) }
        await settle()
        let loadB = Task { await vm.select(b.id) }
        await settle()
        XCTAssertEqual(fetcher.pending, 2)

        fetcher.release(a.id)          // A answers after B was selected
        await loadA.value
        XCTAssertTrue(vm.isLoading, "B is still loading: the skeleton must stay, not 'no transcript'")
        XCTAssertNil(vm.meeting, "A's late answer must not be shown for B")

        fetcher.release(b.id)
        await loadB.value
        XCTAssertEqual(vm.meeting?.id, b.id)
        XCTAssertEqual(vm.displayedSegments.map(\.text), ["from B"])
        XCTAssertFalse(vm.isLoading)
    }

    func testABAQuicklyEndsOnA() async {
        let (vm, fetcher) = make()
        let a = record("A", lines: ["from A"]), b = record("B", lines: ["from B"])
        fetcher.records = [a.id: a, b.id: b]
        fetcher.holdResponses = true

        let t1 = Task { await vm.select(a.id) }; await settle()
        let t2 = Task { await vm.select(b.id) }; await settle()
        let t3 = Task { await vm.select(a.id) }; await settle()

        // Answers arrive in the worst order.
        fetcher.release(b.id); await t2.value
        XCTAssertNil(vm.meeting)
        fetcher.release(a.id); await settle()    // first A fetch
        fetcher.release(a.id)                    // second A fetch
        await t1.value; await t3.value
        XCTAssertEqual(vm.meeting?.id, a.id)
        XCTAssertEqual(vm.displayedSegments.map(\.text), ["from A"])
        XCTAssertFalse(vm.isLoading)
    }

    func testTranscriptSavedAfterOpeningAppears() async {
        let (vm, fetcher) = make()
        var a = record("A", lines: [])
        fetcher.records[a.id] = a
        await vm.select(a.id)
        XCTAssertTrue(vm.displayedSegments.isEmpty)

        // The recording's transcript is written after the meeting was opened.
        a.segments = record("A", lines: ["first words", "second words"]).segments
        fetcher.records[a.id] = a
        NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: a.id)
        for _ in 0..<20 { await settle(); if !vm.displayedSegments.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(vm.displayedSegments.map(\.text), ["first words", "second words"])
    }

    func testPersistNotificationForAnotherMeetingIsIgnored() async {
        let (vm, fetcher) = make()
        let a = record("A", lines: ["a"])
        fetcher.records[a.id] = a
        await vm.select(a.id)
        NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: UUID())
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fetcher.calls, [a.id])
    }

    func testStaleListRowTriggersRefresh() async {
        let (vm, fetcher) = make()
        var a = record("A", lines: [])
        fetcher.records[a.id] = a
        await vm.select(a.id)
        a.segments = record("A", lines: ["now there are words"]).segments
        fetcher.records[a.id] = a
        var row = MeetingListItem(id: a.id, title: "A", language: "en")
        row.wordCount = 4
        await vm.refreshIfStale(listItem: row)
        XCTAssertEqual(vm.displayedSegments.map(\.text), ["now there are words"])
        // In sync now: no further fetch.
        let calls = fetcher.calls.count
        await vm.refreshIfStale(listItem: row)
        XCTAssertEqual(fetcher.calls.count, calls)
    }

    func testDeselectClears() async {
        let (vm, fetcher) = make()
        let a = record("A", lines: ["x"])
        fetcher.records[a.id] = a
        await vm.select(a.id)
        await vm.select(nil)
        XCTAssertNil(vm.meeting)
        XCTAssertTrue(vm.displayedSegments.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    func testMissingMeetingStopsLoading() async {
        let (vm, _) = make()
        await vm.select(UUID())
        XCTAssertNil(vm.meeting)
        XCTAssertFalse(vm.isLoading, "a deleted meeting must not leave a skeleton spinning")
    }
}

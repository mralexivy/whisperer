//
//  ForegroundGateTests.swift
//  WhispererTests
//
//  The pause-in-place gate that lets a dictation pre-empt long background model work. Pure —
//  no models; a private gate instance per test so the app's shared one is never touched.
//

import XCTest
@testable import whisperer

final class ForegroundGateTests: XCTestCase {

    func testHoldersAreCountedSoOneCannotReleaseAnother() {
        let gate = ForegroundGate()
        gate.begin("dictation")
        gate.begin("meeting-pause")
        gate.end("dictation")
        XCTAssertTrue(gate.isRaised, "the meeting's hold must survive the dictation ending")
        gate.end("meeting-pause")
        XCTAssertFalse(gate.isRaised)
        gate.end("meeting-pause")
        XCTAssertFalse(gate.isRaised, "ending twice is harmless")
    }

    func testBackgroundWorkPausesInPlaceAndResumesWhenTheGateDrops() {
        let gate = ForegroundGate()
        gate.begin("dictation")
        let resumed = expectation(description: "background job resumes")
        var waited: TimeInterval = 0
        DispatchQueue.global().async {
            waited = gate.waitWhileRaised("test", priority: .background)
            resumed.fulfill()
        }
        // Still paused while the dictation runs.
        Thread.sleep(forTimeInterval: 0.3)
        gate.end("dictation")
        wait(for: [resumed], timeout: 2)
        XCTAssertGreaterThan(waited, 0.25, "the job really paused for the dictation")
    }

    func testInteractiveWorkNeverPauses() {
        let gate = ForegroundGate()
        gate.begin("dictation")
        let done = expectation(description: "interactive work runs straight through")
        DispatchQueue.global().async {
            XCTAssertEqual(gate.waitWhileRaised("dictation-cleanup", priority: .interactive), 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 0.5)
        gate.end("dictation")
    }

    func testNoPauseWhenNothingIsRunning() {
        let gate = ForegroundGate()
        XCTAssertEqual(gate.waitWhileRaised("test"), 0)
    }

    func testMainThreadIsNeverBlocked() {
        let gate = ForegroundGate()
        gate.begin("dictation")
        let started = Date()
        gate.waitWhileRaised("test")   // runs on the main thread here
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        gate.end("dictation")
    }

    func testClearAllReleasesStrandedHolders() {
        let gate = ForegroundGate()
        gate.begin("dictation")
        let resumed = expectation(description: "stranded pause is released")
        DispatchQueue.global().async {
            gate.waitWhileRaised("test")
            resumed.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        gate.clearAll(reason: "test")
        wait(for: [resumed], timeout: 1)
        XCTAssertFalse(gate.isRaised)
    }

    /// Timeouts count active time: a paused job's budget is not spent while it waits.
    func testActiveTimeExcludesTimeTheGateWasRaised() {
        let gate = ForegroundGate()
        let start = Date()
        let raisedAtStart = gate.raisedSecondsTotal
        gate.begin("dictation")
        Thread.sleep(forTimeInterval: 0.3)
        gate.end("dictation")
        Thread.sleep(forTimeInterval: 0.1)
        let active = gate.activeSeconds(since: start, raisedAtStart: raisedAtStart)
        XCTAssertEqual(active, 0.1, accuracy: 0.08, "0.4 s of wall time, 0.3 s of it paused")
    }

    func testAsyncPauseSuspendsUntilTheGateDrops() async {
        let gate = ForegroundGate()
        gate.begin("dictation")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { gate.end("dictation") }
        let waited = await gate.waitWhileRaisedAsync("test")
        XCTAssertGreaterThan(waited, 0.2)
        XCTAssertFalse(gate.isRaised)
    }

    /// `sleepActive` (the LLM timeout clock) runs longer by however long the shared gate was up.
    func testLLMTimeoutClockStopsWhileTheGateIsRaised() async throws {
        let shared = ForegroundGate.shared
        let started = Date()
        shared.begin("test-timeout")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { shared.end("test-timeout") }
        try await LLMPostProcessor.sleepActive(0.2, priority: .background)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.55,
                             "0.2 s of budget must not be spent during the 0.4 s pause")

        let interactiveStart = Date()
        shared.begin("test-timeout")
        defer { shared.end("test-timeout") }
        try await LLMPostProcessor.sleepActive(0.1, priority: .interactive)
        XCTAssertLessThan(Date().timeIntervalSince(interactiveStart), 0.3,
                          "dictation's own timeout is never extended")
    }
}

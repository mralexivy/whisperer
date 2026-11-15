//
//  CallAudioSilenceHealerTests.swift
//  WhispererTests
//
//  A tap that delivers exact zeros while the call is live must be rebuilt, must not be rebuilt while nobody is on
//  the call, must give up thrashing eventually, and must say when it healed. See CallAudioSilenceHealer.
//

import XCTest
@testable import whisperer

final class CallAudioSilenceHealerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testALiveCallThatStaysSilentIsRebuiltAfterTwentySeconds() {
        var h = CallAudioSilenceHealer(startedAt: t0)
        XCTAssertEqual(h.evaluate(now: at(3), peak: 0, callIsLive: true), .none)
        XCTAssertEqual(h.evaluate(now: at(19), peak: 0, callIsLive: true), .none)
        XCTAssertEqual(h.evaluate(now: at(21), peak: 0, callIsLive: true), .rebuild(attempt: 1))
    }

    func testNoRebuildWhileNobodyIsOnTheCall() {
        var h = CallAudioSilenceHealer(startedAt: t0)
        for s in stride(from: 3.0, through: 300.0, by: 3.0) {
            XCTAssertEqual(h.evaluate(now: at(s), peak: 0, callIsLive: false), .none, "t=\(s)")
        }
        // The call begins at five minutes: the silence before it is not charged to the tap.
        XCTAssertEqual(h.evaluate(now: at(303), peak: 0, callIsLive: true), .none)
    }

    func testRebuildsAreSpacedAndBounded() {
        var h = CallAudioSilenceHealer(startedAt: t0)
        var attempts: [Int] = []
        var times: [Double] = []
        for s in stride(from: 3.0, through: 1_200.0, by: 3.0) {
            if case .rebuild(let n) = h.evaluate(now: at(s), peak: 0, callIsLive: true) { attempts.append(n); times.append(s) }
        }
        XCTAssertEqual(attempts, Array(1...CallAudioSilenceHealer.maxRebuilds), "bounded, in order")
        for pair in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1 - pair.0, CallAudioSilenceHealer.laterRebuildEvery - 3) }
    }

    func testItDiagnosesOnceWhileStillSilent() {
        var h = CallAudioSilenceHealer(startedAt: t0)
        var diagnoses = 0
        for s in stride(from: 3.0, through: 400.0, by: 3.0) {
            if h.evaluate(now: at(s), peak: 0, callIsLive: true) == .diagnose { diagnoses += 1 }
        }
        XCTAssertEqual(diagnoses, 1)
    }

    func testSoundAfterARebuildIsReportedAsRecovered() {
        var h = CallAudioSilenceHealer(startedAt: t0)
        XCTAssertEqual(h.evaluate(now: at(21), peak: 0, callIsLive: true), .rebuild(attempt: 1))
        let action = h.evaluate(now: at(30), peak: 0.2, callIsLive: true)
        guard case .recovered(let silentFor, let rebuilds) = action else { return XCTFail("\(action)") }
        XCTAssertEqual(silentFor, 30, accuracy: 0.01)
        XCTAssertEqual(rebuilds, 1)
        // And it is armed again afterwards.
        XCTAssertEqual(h.evaluate(now: at(40), peak: 0.2, callIsLive: true), .none)
        XCTAssertEqual(h.evaluate(now: at(65), peak: 0.2, callIsLive: true), .rebuild(attempt: 1))
    }

    func testAHealthyCallIsNeverTouched() {
        var h = CallAudioSilenceHealer(startedAt: t0)
        var peak: Float = 0
        for s in stride(from: 3.0, through: 600.0, by: 3.0) {
            peak += 0.001 // sound keeps arriving
            XCTAssertEqual(h.evaluate(now: at(s), peak: peak, callIsLive: true), .none)
        }
    }

    // MARK: - Attribution

    @MainActor
    func testAProcessInsideTheAppBundleIsThePlayingHelper() {
        let slack = ["/Applications/Slack.app"]
        XCTAssertTrue(AudioProcessMonitor.belongs(executablePath: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", insideAppAt: slack))
        XCTAssertTrue(AudioProcessMonitor.belongs(executablePath: "/Applications/Slack.app/Contents/MacOS/Slack", insideAppAt: slack))
        XCTAssertFalse(AudioProcessMonitor.belongs(executablePath: "/Applications/Slack.app.backup/Contents/MacOS/Slack", insideAppAt: slack), "a sibling folder is not inside the bundle")
        XCTAssertFalse(AudioProcessMonitor.belongs(executablePath: "/System/Library/Frameworks/CoreAudio.framework/coreaudiod", insideAppAt: slack))
        XCTAssertFalse(AudioProcessMonitor.belongs(executablePath: nil, insideAppAt: slack))
        XCTAssertFalse(AudioProcessMonitor.belongs(executablePath: "/Applications/Slack.app/x", insideAppAt: []))
        XCTAssertNotNil(AudioProcessMonitor.executablePath(ofPID: getpid()), "proc_pidpath works for our own process")
    }

    @MainActor
    func testHelpersCountAsTheCallAppEvenWhenTheProcessTreeDoesNotResolve() {
        // The tree walk answers when it can…
        XCTAssertTrue(AudioProcessMonitor.belongs(rawBundleID: nil, owner: "com.tinyspeck.slackmacgap", to: "com.tinyspeck.slackmacgap"))
        // …and the helper's own bundle ID is the backstop.
        XCTAssertTrue(AudioProcessMonitor.belongs(rawBundleID: "com.tinyspeck.slackmacgap.helper", owner: nil, to: "com.tinyspeck.slackmacgap"))
        XCTAssertTrue(AudioProcessMonitor.belongs(rawBundleID: "com.google.Chrome.helper.Renderer", owner: nil, to: "com.google.Chrome"))
        XCTAssertTrue(AudioProcessMonitor.belongs(rawBundleID: "com.tinyspeck.slackmacgap", owner: nil, to: "com.tinyspeck.slackmacgap"))
        // Other apps that merely share a prefix are not the call app.
        XCTAssertFalse(AudioProcessMonitor.belongs(rawBundleID: "com.google.Chrome.canary", owner: nil, to: "com.google.Chrome"))
        XCTAssertFalse(AudioProcessMonitor.belongs(rawBundleID: "com.apple.Safari", owner: "com.apple.Safari", to: "com.google.Chrome"))
        XCTAssertFalse(AudioProcessMonitor.belongs(rawBundleID: nil, owner: nil, to: "com.tinyspeck.slackmacgap"))
    }
}

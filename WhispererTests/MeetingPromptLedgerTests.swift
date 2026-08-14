//
//  MeetingPromptLedgerTests.swift
//  WhispererTests
//
//  Regression tests for "meeting detection only works once".
//
//  The refire guard was a 30-minute wall-clock window keyed by provider display name, cleared
//  only on the dismissal path and only when the hardware happened to go idle. Accepting the
//  prompt — or letting it time out — left the entry in place, so the second meeting of a session
//  was rejected before any scoring ran, for Google Meet, Zoom, Teams and every other provider
//  alike. These tests pin the call-scoped behaviour that replaced it.
//

import XCTest
@testable import whisperer

final class MeetingPromptLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func ledger() -> MeetingPromptLedger {
        var l = MeetingPromptLedger()
        l.refireInterval = 30 * 60
        l.callEndedGrace = 20
        l.dismissalGrace = 120
        l.newCallGap = 5
        return l
    }

    /// The provider is on the microphone on a run that began `runStart` and followed a gap of
    /// `gap` seconds. Mirrors what `AudioProcessMonitor` reports once a call has restarted.
    private func capturing(since runStart: Date, after gap: TimeInterval?) -> MeetingCaptureStatus {
        .capturing(since: runStart, precededByGap: gap)
    }

    // MARK: - The bug

    /// Accept the prompt, meeting ends, a new one starts twenty minutes later. Under the old
    /// wall-clock guard this was silently dropped.
    func testSecondMeetingPromptsAfterFirstCallEnds() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)
        XCTAssertTrue(l.isSuppressed("Google Meet", now: t0.addingTimeInterval(60)))

        // Call ends at +30 min; poll runs 25s later.
        let callEnd = t0.addingTimeInterval(1800)
        l.releaseEndedCalls(now: callEnd.addingTimeInterval(25)) { _ in .ended(callEnd) }

        XCTAssertFalse(l.isSuppressed("Google Meet", now: callEnd.addingTimeInterval(25)),
                       "A provider whose call ended must be able to prompt for the next meeting")
    }

    /// Two Google Meet calls eight seconds apart, from the log that reopened this bug: the first
    /// meeting is recorded and stopped, Chrome drops the microphone at 13:34:48, and is back on it
    /// by 13:34:56 for the next call.
    ///
    /// Releasing only while the provider is *currently* quiet cannot see this. The poll that
    /// catches the gap open sees it as a few seconds old and declines against the 20s grace, and
    /// by the following poll Chrome is capturing again — after which no path but the 30-minute
    /// ceiling can release the entry. The gap has to be read after it closes.
    func testBackToBackCallsInTheSameBrowserPrompt() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)

        // First call ends 71s in. The poll 4s later is the only one that sees `.ended`.
        let firstCallEnded = t0.addingTimeInterval(71)
        l.releaseEndedCalls(now: firstCallEnded.addingTimeInterval(4)) { _ in .ended(firstCallEnded) }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: firstCallEnded.addingTimeInterval(4)),
                      "Four seconds off the mic is still a blip, not a hang-up")

        // Second call starts 8s after the first ended.
        let secondCallStarted = firstCallEnded.addingTimeInterval(8)
        let poll = secondCallStarted.addingTimeInterval(1)
        l.releaseEndedCalls(now: poll) { [self] _ in capturing(since: secondCallStarted, after: 8) }

        XCTAssertFalse(l.isSuppressed("Google Meet", now: poll),
                       "A new capture run after a real gap is a new meeting and must prompt")
    }

    /// The same shape for a native app — nothing here is browser-specific.
    func testBackToBackZoomCallsPrompt() {
        var l = ledger()
        l.recordPrompt(name: "Zoom", bundleID: "us.zoom.xos", at: t0)

        let next = t0.addingTimeInterval(900)
        l.releaseEndedCalls(now: next.addingTimeInterval(2)) { [self] _ in
            capturing(since: next, after: 12)
        }
        XCTAssertFalse(l.isSuppressed("Zoom", now: next.addingTimeInterval(2)))
    }

    /// Same guarantee for the native-app paths, which share the ledger.
    func testEveryProviderIsReleasedIndependently() {
        var l = ledger()
        l.recordPrompt(name: "Zoom", bundleID: "us.zoom.xos", at: t0)
        l.recordPrompt(name: "Microsoft Teams", bundleID: "com.microsoft.teams2", at: t0)

        let end = t0.addingTimeInterval(600)
        l.releaseEndedCalls(now: end.addingTimeInterval(30)) { [self] bundleID in
            bundleID == "us.zoom.xos" ? .ended(end) : capturing(since: t0.addingTimeInterval(-60), after: nil)
        }

        XCTAssertFalse(l.isSuppressed("Zoom", now: end.addingTimeInterval(30)))
        XCTAssertTrue(l.isSuppressed("Microsoft Teams", now: end.addingTimeInterval(30)),
                      "Teams is still on the microphone — its call has not ended")
    }

    // MARK: - What the guard still has to do

    func testOngoingCallStaysSuppressed() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)
        // Unbroken run that was already in progress when we prompted — this is the call itself.
        l.releaseEndedCalls(now: t0.addingTimeInterval(300)) { [self] _ in
            capturing(since: t0.addingTimeInterval(-3), after: nil)
        }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: t0.addingTimeInterval(300)),
                      "One call must never prompt twice")
    }

    /// A device switch or reconnect drops capture for a moment. That is not the end of the call —
    /// neither while the gap is open nor once it has closed.
    func testBriefCaptureGapDoesNotRelease() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)

        let blip = t0.addingTimeInterval(120)
        l.releaseEndedCalls(now: blip.addingTimeInterval(5)) { _ in .ended(blip) }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: blip.addingTimeInterval(5)))

        let resumed = blip.addingTimeInterval(2)
        l.releaseEndedCalls(now: resumed.addingTimeInterval(1)) { [self] _ in
            capturing(since: resumed, after: 2)
        }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: resumed.addingTimeInterval(1)),
                      "A two-second dropout is a device switch, not the next meeting")
    }

    /// The run in progress at prompt time is the call we prompted for, however long the provider
    /// happened to be quiet before it — a voice search an hour earlier must not release the guard
    /// the instant it is taken out.
    func testRunAlreadyUnderwayAtPromptTimeNeverReleases() {
        var l = ledger()
        let runStart = t0.addingTimeInterval(-4)
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)

        l.releaseEndedCalls(now: t0.addingTimeInterval(600)) { [self] _ in
            capturing(since: runStart, after: 3600)
        }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: t0.addingTimeInterval(600)))
    }

    /// Dismissing answers the call the toast was raised for. The next call is a different question,
    /// so a demonstrably new capture run releases the guard regardless.
    func testDismissalDoesNotOutliveItsCall() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)
        l.recordDismissal(name: "Google Meet")

        let next = t0.addingTimeInterval(400)
        l.releaseEndedCalls(now: next.addingTimeInterval(1)) { [self] _ in capturing(since: next, after: 30) }
        XCTAssertFalse(l.isSuppressed("Google Meet", now: next.addingTimeInterval(1)))
    }

    /// Muting yourself in a long call must not bring back a toast that was waved away.
    func testDismissalSurvivesAMinuteOfSilence() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)
        l.recordDismissal(name: "Google Meet")

        let muted = t0.addingTimeInterval(60)
        l.releaseEndedCalls(now: muted.addingTimeInterval(60)) { _ in .ended(muted) }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: muted.addingTimeInterval(60)),
                      "A one-minute mute is not a new meeting")

        l.releaseEndedCalls(now: muted.addingTimeInterval(130)) { _ in .ended(muted) }
        XCTAssertFalse(l.isSuppressed("Google Meet", now: muted.addingTimeInterval(130)),
                       "After the dismissal grace, the next call is a different call")
    }

    /// Hardware idle is the coarse signal: nobody on the mic, camera off. It frees the provider
    /// that was never attributed — nothing else will ever report the end of its call — and leaves
    /// the attributed one to `releaseEndedCalls`, which can tell a hang-up from a mute.
    func testHardwareIdleReleasesOnlyUnobservableProviders() {
        var l = ledger()
        l.recordPrompt(name: "Zoom", bundleID: "us.zoom.xos", at: t0)
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)

        l.releaseUnobservableCalls { bundleID in
            bundleID == "us.zoom.xos" ? .unobserved : .ended(t0.addingTimeInterval(25))
        }

        XCTAssertFalse(l.isSuppressed("Zoom", now: t0.addingTimeInterval(30)))
        XCTAssertTrue(l.isSuppressed("Google Meet", now: t0.addingTimeInterval(30)))
    }

    /// The case that made this signal too coarse to trust on its own: mute yourself mid-call with
    /// the camera off and the hardware reads exactly as it does when the meeting ends.
    func testHardwareIdleDoesNotRePromptAMutedCall() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)

        let muted = t0.addingTimeInterval(300)
        l.releaseUnobservableCalls { _ in .ended(muted) }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: muted.addingTimeInterval(1)),
                      "Muting is not hanging up — one call must still prompt only once")

        // Muting does not hand the microphone back — Zoom, Teams and Chrome all hold the device
        // open while muted, which is why the orange indicator stays lit. The capture run is
        // unbroken across the mute, so the guard is never lifted and no second toast appears.
        l.releaseEndedCalls(now: muted.addingTimeInterval(5)) { [self] _ in
            capturing(since: t0.addingTimeInterval(-2), after: nil)
        }
        XCTAssertTrue(l.isSuppressed("Google Meet", now: muted.addingTimeInterval(5)))
    }

    /// Dismissals survive hardware idle outright — wiping them here is what once turned "Dismiss"
    /// into a 40-second snooze.
    func testHardwareIdleKeepsDismissals() {
        var l = ledger()
        l.recordPrompt(name: "Zoom", bundleID: "us.zoom.xos", at: t0)
        l.recordDismissal(name: "Zoom")

        l.releaseUnobservableCalls { _ in .unobserved }

        XCTAssertTrue(l.isSuppressed("Zoom", now: t0.addingTimeInterval(30)))
        XCTAssertEqual(l.dismissedCount, 1)
    }

    /// A provider matched by virtual audio device or by being frontmost never appears in the
    /// capturing set, so its end cannot be seen — it falls back to the 30-minute ceiling.
    func testUnobservedProviderFallsBackToTheCeiling() {
        var l = ledger()
        l.recordPrompt(name: "Zoom", bundleID: "us.zoom.xos", at: t0)

        l.releaseEndedCalls(now: t0.addingTimeInterval(600)) { _ in .unobserved }
        XCTAssertTrue(l.isSuppressed("Zoom", now: t0.addingTimeInterval(600)))

        XCTAssertFalse(l.isSuppressed("Zoom", now: t0.addingTimeInterval(1801)))
    }

    /// The ceiling expiry must take the dismissal with it, or a dismissed name outlives the
    /// cooldown it is pinned to and blocks that provider for the rest of the session.
    func testCeilingExpiryClearsDismissal() {
        var l = ledger()
        l.recordPrompt(name: "Google Meet", bundleID: "com.google.Chrome", at: t0)
        l.recordDismissal(name: "Google Meet")

        XCTAssertFalse(l.isSuppressed("Google Meet", now: t0.addingTimeInterval(1801)))
        XCTAssertEqual(l.dismissedCount, 0)
    }

    func testProviderQuitReleasesImmediately() {
        var l = ledger()
        l.recordPrompt(name: "Zoom", bundleID: "us.zoom.xos", at: t0)
        l.release("Zoom")
        XCTAssertFalse(l.isSuppressed("Zoom", now: t0.addingTimeInterval(1)))
    }

    func testUnknownProviderIsNeverSuppressed() {
        var l = ledger()
        XCTAssertFalse(l.isSuppressed("Webex", now: t0))
    }
}

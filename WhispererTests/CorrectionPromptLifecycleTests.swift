//
//  CorrectionPromptLifecycleTests.swift
//  WhispererTests
//
//  When the correction card appears, how long it stays, and what makes it leave. These were the
//  hand-checked steps of the plan; they are assertions instead, because "the card fought the
//  recording HUD" is not something anyone will notice reliably by eye.
//

import XCTest
@testable import whisperer

@MainActor
final class CorrectionPromptLifecycleTests: XCTestCase {
    private var learningWasEnabled = false

    override func setUp() async throws {
        try await super.setUp()
        learningWasEnabled = DictionaryManager.shared.correctionLearningEnabled
        DictionaryManager.shared.correctionLearningEnabled = true
        AppState.shared.dismissCorrectionPrompt()
    }

    override func tearDown() async throws {
        AppState.shared.dismissCorrectionPrompt()
        DictionaryManager.shared.correctionLearningEnabled = learningWasEnabled
        try await super.tearDown()
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testTheCardAppearsForADictationAndFadesOnItsOwn() async {
        AppState.shared.showCorrectionPrompt("we can glyn a lot", lifetime: 0.1)
        XCTAssertNotNil(AppState.shared.correctionPrompt)

        await sleep(0.9)
        XCTAssertNil(AppState.shared.correctionPrompt,
                     "an ignored card must go away by itself — it is an offer, not a dialog")
    }

    /// Step 3 of the manual list: the card must not vanish out from under someone mid-correction.
    func testHoveringOrTypingHoldsTheCardOpenPastItsLifetime() async {
        AppState.shared.showCorrectionPrompt("we can glyn a lot", lifetime: 0.1)
        AppState.shared.correctionPromptHeld = true

        await sleep(0.9)
        XCTAssertNotNil(AppState.shared.correctionPrompt,
                        "the card expired while the user was still working in it")

        // Releasing grants a short grace rather than dismissing instantly, so a pointer that
        // slips off the edge does not destroy a half-typed correction.
        AppState.shared.correctionPromptHeld = false
        await sleep(0.6)
        XCTAssertNotNil(AppState.shared.correctionPrompt,
                        "leaving the card must grant a grace period, not close it under the pointer")
    }

    /// Step 2: starting the next dictation must clear the old card at once, not leave it arguing
    /// with the recording HUD for space in the same panel.
    func testTheNextRecordingClearsTheCardImmediately() async {
        AppState.shared.showCorrectionPrompt("we can glyn a lot", lifetime: 60)
        AppState.shared.correctionPromptHeld = true   // even while held
        XCTAssertNotNil(AppState.shared.correctionPrompt)

        AppState.shared.state = .recording(startTime: Date())
        XCTAssertNil(AppState.shared.correctionPrompt,
                     "the recording HUD and a stale correction card must never be on screen together")
        XCTAssertFalse(AppState.shared.correctionPromptHeld)

        AppState.shared.state = .idle
    }

    /// A second dictation's card must not be killed by the first card's timer.
    func testAnOlderTimerCannotDismissANewerCard() async {
        AppState.shared.showCorrectionPrompt("first dictation about glyn", lifetime: 0.1)
        AppState.shared.showCorrectionPrompt("second dictation about orcid", lifetime: 5)
        let newer = AppState.shared.correctionPrompt?.id

        await sleep(0.9)
        XCTAssertEqual(AppState.shared.correctionPrompt?.id, newer,
                       "the first card's expiry closed the second card")
    }

    func testNoCardWhenTheUserHasTurnedLearningOff() async {
        DictionaryManager.shared.correctionLearningEnabled = false
        AppState.shared.showCorrectionPrompt("we can glyn a lot", lifetime: 5)
        XCTAssertNil(AppState.shared.correctionPrompt)
    }
}

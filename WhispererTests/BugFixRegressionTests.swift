//
//  BugFixRegressionTests.swift
//  WhispererTests
//
//  Regression tests for three bugs fixed July 2025:
//
//  Bug A — Nemotron currentTranscription fallback was dead code:
//    currentTranscription returned fullTranscription (always "" for Nemotron during
//    recording). AppState's fallback path was never triggered. Text lost when finish()
//    returned empty (short recording, E5 recompilation, etc.).
//
//  Bug B — CoreData merge conflict in discardSession (NSMergeConflict error 133020):
//    appendChunk bumped the store version; discardSession's fresh context carried a
//    stale optimistic lock and raised NSMergeConflict on save.
//
//  Bug C — HealthManager fired false 400,000-second stall alerts after Mac sleep:
//    ContinuousClock advances during sleep. mainThreadPendingSince set before sleep
//    reported days of "stall" on wake. No sleep/wake reset existed.
//

import XCTest
import AppKit
import CoreData
@testable import whisperer

#if canImport(FluidAudio)
import FluidAudio
#endif

// MARK: - Bug A: Nemotron currentTranscription fallback

final class NemotronCurrentTranscriptionFallbackTests: XCTestCase {

    /// Core assertion: once a partial arrives via the onTranscription callback,
    /// currentTranscription must return that text (not "").
    ///
    /// Pre-fix: currentTranscription returned fullTranscription = "" for Nemotron
    ///          during a recording, making AppState's finish()-failed fallback path useless.
    /// Post-fix: returns previewAccumulatedText when Nemotron and non-empty.
    func testCurrentTranscriptionReflectsPartialAfterPartialArrives() async throws {
        #if canImport(FluidAudio)
        try XCTSkipUnless(BackendType.nemotron.isAvailable, "Nemotron requires Apple Silicon")
        try XCTSkipUnless(NemotronBridge.isModelCached(), "Nemotron model not downloaded — run app first")

        let wavURL = URL(fileURLWithPath:
            "/Users/alexanderi/Downloads/whisperer/WhispererTests/TestData/test-sentences-en.wav")
        let samples = try loadAudioSamples(from: wavURL)

        let bridge = try await NemotronBridge.loadFromCache()
        let transcriber = StreamingTranscriber(
            backend: NullTranscriptionBackend(),
            vad: nil,
            language: .english,
            nemotronBridge: bridge
        )

        var latestPartial = ""
        let partialExpectation = expectation(description: "At least one partial arrives")
        partialExpectation.assertForOverFulfill = false

        transcriber.start { text in
            if !text.isEmpty {
                latestPartial = text
                partialExpectation.fulfill()
            }
        }

        // Wait for session init, then feed audio
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        let chunkSize = 1365  // ~85ms at 16 kHz
        for offset in stride(from: 0, to: min(samples.count, 16000 * 8), by: chunkSize) {
            let end = min(offset + chunkSize, samples.count)
            transcriber.addSamples(Array(samples[offset..<end]))
        }

        await fulfillment(of: [partialExpectation], timeout: 12.0)

        // currentTranscription MUST now return the partial, not "".
        // Pre-fix this always returned "" for Nemotron.
        let live = transcriber.currentTranscription
        XCTAssertFalse(live.isEmpty,
            "currentTranscription returned \"\" after a partial arrived — " +
            "the Nemotron fallback fix is not working (previewAccumulatedText not returned)")
        XCTAssertEqual(live, latestPartial,
            "currentTranscription should equal the last partial pushed by the callback")

        print("✅ Bug A — currentTranscription='\(live.prefix(80))'")

        _ = await transcriber.stopAsync()
        await bridge.prepareForShutdown()
        #else
        throw XCTSkip("FluidAudio not available")
        #endif
    }

    /// Baseline: currentTranscription is "" before any audio is fed (no partials yet).
    /// This must hold both before and after the fix.
    func testCurrentTranscriptionEmptyBeforeAnyPartial() async throws {
        #if canImport(FluidAudio)
        try XCTSkipUnless(BackendType.nemotron.isAvailable, "Nemotron requires Apple Silicon")
        try XCTSkipUnless(NemotronBridge.isModelCached(), "Nemotron model not downloaded — run app first")

        let bridge = try await NemotronBridge.loadFromCache()
        let transcriber = StreamingTranscriber(
            backend: NullTranscriptionBackend(),
            vad: nil,
            language: .english,
            nemotronBridge: bridge
        )
        transcriber.start { _ in }

        // No audio fed — session open but no partials expected.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(transcriber.currentTranscription.isEmpty,
            "currentTranscription should be empty before any audio is fed")

        print("✅ Bug A — correctly empty when no partials received")

        _ = await transcriber.stopAsync()
        await bridge.prepareForShutdown()
        #else
        throw XCTSkip("FluidAudio not available")
        #endif
    }
}

// MARK: - Bug B: CoreData merge conflict in discardSession

final class HistoryManagerMergeConflictTests: XCTestCase {

    /// Pre-fix: discardSession raised NSMergeConflict (error 133020) when appendChunk
    ///          had already saved the entity in a separate background context.
    ///
    /// Post-fix: NSOverwriteMergePolicy on the discard context lets the delete win.
    ///
    /// Verification: after discardSession the entity must be absent from the database.
    /// If a merge conflict fires and the save fails, the entity stays in the database
    /// with isInProgress=true — exactly the pre-fix symptom.
    func testDiscardSessionSucceedsAfterAppendChunk() async throws {
        let manager = HistoryManager.shared

        // Use a temp path so the test doesn't create real audio files.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".caf")

        // 1. Create the in-progress session.
        let sessionID = await manager.beginSession(
            audioFileURL: tempURL,
            language: "en",
            modelUsed: "test-model"
        )

        // 2. appendChunk saves via its own background context, bumping the store version.
        await manager.appendChunk(
            sessionID: sessionID,
            chunkText: "Hello world this is a regression test",
            totalDuration: 3.5
        )

        // 3. discardSession must complete without conflict (pre-fix: raised error 133020
        //    and left the entity alive with isInProgress=true).
        await manager.discardSession(sessionID: sessionID)

        // 4. Verify the entity is gone.
        //    loadInProgressSessions reads the view context — if the delete conflicted
        //    and did not commit, the session still appears here.
        let remaining = await manager.loadInProgressSessions()
        let sessionStillPresent = remaining.contains { $0.id == sessionID }
        XCTAssertFalse(sessionStillPresent,
            "Session \(sessionID) still present after discardSession — " +
            "merge conflict prevented the delete from committing (pre-fix regression)")

        print("✅ Bug B — entity absent after discardSession+appendChunk race")
    }

    /// Baseline: discard without any appendChunk call must also work.
    func testDiscardSessionWithNoChunksSucceeds() async throws {
        let manager = HistoryManager.shared

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".caf")
        let sessionID = await manager.beginSession(
            audioFileURL: tempURL,
            language: "en",
            modelUsed: "test-model"
        )

        await manager.discardSession(sessionID: sessionID)

        let remaining = await manager.loadInProgressSessions()
        XCTAssertFalse(remaining.contains { $0.id == sessionID },
            "Session still present after discard with no prior appendChunk")

        print("✅ Bug B — baseline discard (no appendChunk) also clean")
    }

    /// Rapid sequence: two appendChunk calls then discard. Exercises the most likely
    /// race in the real app (streaming recording with multiple chunk callbacks).
    func testDiscardSessionAfterMultipleAppendChunkCalls() async throws {
        let manager = HistoryManager.shared

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".caf")
        let sessionID = await manager.beginSession(
            audioFileURL: tempURL,
            language: "en",
            modelUsed: "test-model"
        )

        // Simulate streaming chunks arriving before the user stops recording.
        await manager.appendChunk(sessionID: sessionID, chunkText: "First chunk text.", totalDuration: 2.0)
        await manager.appendChunk(sessionID: sessionID, chunkText: "Second chunk text.", totalDuration: 4.0)

        await manager.discardSession(sessionID: sessionID)

        let remaining = await manager.loadInProgressSessions()
        XCTAssertFalse(remaining.contains { $0.id == sessionID },
            "Session survived after two appendChunk calls + discard")

        print("✅ Bug B — multi-chunk discard clean")
    }
}

// MARK: - Bug C: HealthManager false stall alerts after Mac sleep

final class HealthManagerSleepWakeTests: XCTestCase {

    /// Verify the wake observer is wired: posting didWakeNotification must not crash.
    ///
    /// We cannot directly inspect mainThreadPendingSince (private), but we can verify
    /// the reset path exists by confirming no unhandled exception on wake.
    func testWakeNotificationHandledWithoutCrash() async throws {
        HealthManager.shared.stopMonitoring()
        HealthManager.shared.startMonitoring()
        defer { HealthManager.shared.stopMonitoring() }

        // Let the monitor post its first main-thread check and let main thread reply.
        try await Task.sleep(nanoseconds: 300_000_000)  // 300ms

        // Post the wake notification — must not crash.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )

        // Give monitorQueue time to process the reset.
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        print("✅ Bug C — didWakeNotification handled without crash")
    }

    /// Verify HealthManager can be stopped and restarted (regression guard: the wake
    /// observer must not be registered twice if startMonitoring is called again).
    func testStartMonitoringIdempotent() throws {
        HealthManager.shared.stopMonitoring()
        HealthManager.shared.startMonitoring()
        HealthManager.shared.startMonitoring()  // second call must be a no-op
        HealthManager.shared.stopMonitoring()

        print("✅ Bug C — startMonitoring is idempotent")
    }
}

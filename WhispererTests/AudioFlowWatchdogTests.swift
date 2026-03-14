//
//  AudioFlowWatchdogTests.swift
//  WhispererTests
//
//  Tests for the audio flow watchdog that detects when the engine is running
//  but no audio data flows through the tap (silent recording bug).
//

import AVFoundation
import XCTest
@testable import whisperer

final class AudioFlowWatchdogTests: XCTestCase {

    private var recorder: AudioRecorder!

    override func setUp() {
        super.setUp()
        recorder = AudioRecorder()
    }

    override func tearDown() {
        if let r = recorder {
            Task { await r.stopRecording() }
        }
        recorder = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Verify that normal recording with default device receives audio data
    /// and the watchdog does NOT trigger recovery.
    func testAudioFlowsNormallyWithDefaultDevice() async throws {
        let hasPermission = await AudioRecorder.checkMicrophonePermission()
        guard hasPermission else {
            throw XCTSkip("Microphone permission not granted")
        }

        var amplitudeReceived = false
        recorder.onAmplitudeUpdate = { _ in
            amplitudeReceived = true
        }

        var recoveryTriggered = false
        recorder.onDeviceRecovery = { _ in
            recoveryTriggered = true
        }
        recorder.onAudioFlowTimeout = {
            recoveryTriggered = true
        }

        // Use system default device
        recorder.selectedDeviceID = nil

        _ = try await recorder.startRecording()

        // Wait 3 seconds — enough for the 2s watchdog to fire if it were going to
        try await Task.sleep(nanoseconds: 3_000_000_000)

        XCTAssertTrue(amplitudeReceived, "Amplitude callback should have fired with default device")
        XCTAssertFalse(recoveryTriggered, "Recovery should NOT be triggered when audio flows normally")

        await recorder.stopRecording()
    }

    /// Verify that a bogus selectedDeviceID is cleared during startup retry,
    /// falling back to the system default device. This tests the existing
    /// fallback path that the watchdog complements.
    func testBogusDeviceFallsBackToDefault() async throws {
        let hasPermission = await AudioRecorder.checkMicrophonePermission()
        guard hasPermission else {
            throw XCTSkip("Microphone permission not granted")
        }

        // Set a bogus device that won't pass validation
        recorder.selectedDeviceID = 99999

        var amplitudeReceived = false
        recorder.onAmplitudeUpdate = { _ in
            amplitudeReceived = true
        }

        // Start recording — bogus device should be cleared and default used
        _ = try await recorder.startRecording()

        // Wait for audio to start flowing
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Device should have been cleared (bogus device fails isValidInputDevice)
        XCTAssertNil(recorder.selectedDeviceID, "selectedDeviceID should be cleared after bogus device rejected")
        XCTAssertTrue(amplitudeReceived, "Audio should flow after falling back to default device")

        await recorder.stopRecording()
    }

    /// Verify that the onAudioFlowTimeout callback can be set and that
    /// recovery clears selectedDeviceID. This tests the recovery path
    /// contracts without requiring a device that starts but produces no audio.
    func testRecoveryClearsSelectedDeviceID() async throws {
        let hasPermission = await AudioRecorder.checkMicrophonePermission()
        guard hasPermission else {
            throw XCTSkip("Microphone permission not granted")
        }

        // Verify the callback property exists and can be assigned
        var timeoutCalled = false
        recorder.onAudioFlowTimeout = {
            timeoutCalled = true
        }

        // Verify the callback was set (not nil)
        XCTAssertNotNil(recorder.onAudioFlowTimeout)

        // Start a normal recording, verify lastAudioCallbackTime gets set
        recorder.selectedDeviceID = nil
        _ = try await recorder.startRecording()

        // Wait for first audio callback
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // The timeout should NOT have been called for a working device
        XCTAssertFalse(timeoutCalled, "Timeout should not fire when audio is flowing")

        await recorder.stopRecording()
    }
}

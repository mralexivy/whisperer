import XCTest
import CoreML
@testable import whisperer

final class PrivacyShieldTests: XCTestCase {
    func testNonOffPhasesBlockTranscriptionIncludingFailureAndStop() {
        for phase in [PrivacyShieldSnapshot.Phase.starting, .armed, .active, .muted, .stopping] {
            var snapshot = PrivacyShieldSnapshot()
            snapshot.phase = phase
            XCTAssertTrue(snapshot.blocksTranscription, "\(phase) must not allow raw capture")
        }
        XCTAssertFalse(PrivacyShieldSnapshot().blocksTranscription)
    }

    func testExplicitPassthroughIsOffAndReleasesCapture() {
        var snapshot = PrivacyShieldSnapshot()
        snapshot.phase = .passthrough
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertFalse(snapshot.blocksTranscription)
        XCTAssertEqual(snapshot.menuActionTitle, "Enable Privacy Shield")
    }

    func testRouteVerificationRejectsUnknownMixedAndBypassingConsumers() {
        XCTAssertEqual(PrivacyRouteStatus.evaluate(devices: [], virtual: 42, hasSignal: true), .waiting)
        XCTAssertEqual(PrivacyRouteStatus.evaluate(devices: [[42]], virtual: 42, hasSignal: false), .waiting)
        XCTAssertEqual(PrivacyRouteStatus.evaluate(devices: [[42], [42]], virtual: 42, hasSignal: true), .verified)
        XCTAssertEqual(PrivacyRouteStatus.evaluate(devices: [[]], virtual: 42, hasSignal: true), .needsSelection)
        XCTAssertEqual(PrivacyRouteStatus.evaluate(devices: [[42, 7]], virtual: 42, hasSignal: true), .needsSelection)
        XCTAssertEqual(PrivacyRouteStatus.evaluate(devices: [[42], [7]], virtual: 42, hasSignal: true), .needsSelection)
    }

    func testMenuAlwaysOffersEscapeFromMutedAndStarting() {
        var snapshot = PrivacyShieldSnapshot()
        snapshot.phase = .muted
        XCTAssertEqual(snapshot.menuActionTitle, "Turn Off Privacy Shield (Muted)")
        snapshot.phase = .starting
        XCTAssertEqual(snapshot.menuActionTitle, "Cancel Privacy Shield")
        snapshot.phase = .off
        XCTAssertEqual(snapshot.menuActionTitle, "Enable Privacy Shield")
    }

    func testBaselineSilenceDoesNotGenerateAudio() throws {
        let processor = try PrivacyAudioProcessor(modelURL: nil, strength: 1)
        let input = [Float](repeating: 0, count: 480)
        var output = [Float](repeating: 1, count: 480)
        let valid = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                processor.process(source.baseAddress!, destination.baseAddress!, count: 480)
            }
        }
        XCTAssertTrue(valid)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    func testBaselineBoundsNonFiniteAndClippedInput() throws {
        let processor = try PrivacyAudioProcessor(modelURL: nil, strength: 0.5)
        var input = [Float](repeating: 3, count: 480)
        input[0] = .nan; input[1] = .infinity; input[2] = .greatestFiniteMagnitude
        var output = [Float](repeating: 0, count: 480)
        let valid = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                processor.process(source.baseAddress!, destination.baseAddress!, count: 480)
            }
        }
        XCTAssertTrue(valid)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
    }

    func testCompiledCoreMLProcessorCopiesFreshFloat32Blocks() throws {
        // Deterministic x * 0.5 fixture; regenerate with make-model-fixture.py.
        let encoded = "CAQSMAoUCgVhdWRpbxoLKgkKAwHgAxCggARSGAoJcHJvY2Vzc2VkGgsqCQoDAeADEKCABKIfKAoiCgRoYWxmEgVhdWRpbxoJcHJvY2Vzc2VkkggHKgUNAAAAPygBMAE="
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mlmodel")
        try XCTUnwrap(Data(base64Encoded: encoded)).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let compiledURL = try MLModel.compileModel(at: sourceURL)
        defer { try? FileManager.default.removeItem(at: compiledURL) }
        let processor = try PrivacyAudioProcessor(modelURL: compiledURL, strength: 0.5)
        for block in 0..<100 {
            let level: Float = block.isMultiple(of: 2) ? 0.5 : -0.8
            let input = [Float](repeating: level, count: 480)
            var output = [Float](repeating: 99, count: 480)
            let valid = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    processor.process(source.baseAddress!, destination.baseAddress!, count: 480)
                }
            }
            XCTAssertTrue(valid)
            XCTAssertTrue(output.allSatisfy { abs($0 - level * 0.5) < 0.001 }, "Fresh input must reach the Core ML output")
        }
    }

    func testMissingModelCannotSilentlyFallBackToBaseline() {
        XCTAssertThrowsError(try PrivacyAudioProcessor(modelURL: URL(fileURLWithPath: "/nonexistent/shield.mlmodelc"), strength: 0.5))
    }

    func testCaptureGateCanBeReleasedExplicitly() {
        let previous = shield_capture_blocked()
        defer { shield_set_capture_blocked(previous) }
        shield_set_capture_blocked(true)
        XCTAssertTrue(shield_capture_blocked())
        shield_set_capture_blocked(false)
        XCTAssertFalse(shield_capture_blocked())
    }
}

import XCTest
@testable import whisperer

final class PrivacyShieldTests: XCTestCase {
    func testNonOffPhasesBlockTranscriptionIncludingFailureAndStop() {
        for phase in [PrivacyShieldSnapshot.Phase.starting, .active, .muted, .stopping] {
            var snapshot = PrivacyShieldSnapshot()
            snapshot.phase = phase
            XCTAssertTrue(snapshot.blocksTranscription, "\(phase) must not allow raw capture")
        }
        XCTAssertFalse(PrivacyShieldSnapshot().blocksTranscription)
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
        input[0] = .nan; input[1] = .infinity
        var output = [Float](repeating: 0, count: 480)
        let valid = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                processor.process(source.baseAddress!, destination.baseAddress!, count: 480)
            }
        }
        XCTAssertTrue(valid)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
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

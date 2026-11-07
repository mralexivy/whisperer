import XCTest
@testable import whisperer

/// The shipped voice-protection network: bundled, loadable, bounded, follows the voice, fails closed.
/// Efficacy against speech recognition is measured offline by Tools/privacy-shield/eval/run_eval.py
/// on the same native code path; these tests guard the app integration.
final class PrivacyShieldNetworkTests: XCTestCase {
    /// Speech-like test signal: a 180 Hz voiced tone with syllable-rate amplitude modulation,
    /// with silence in the second half.
    private func voice(blocks: Int) -> [Float] {
        (0..<blocks * 480).map { i in
            let t = Float(i) / 48000
            guard i < blocks * 240 else { return 0 }
            return 0.3 * sinf(2 * .pi * 180 * t) * (0.6 + 0.4 * sinf(2 * .pi * 4 * t))
        }
    }

    private func run(_ processor: PrivacyAudioProcessor, _ input: [Float]) -> (output: [Float], valid: Bool) {
        var output = [Float](repeating: 0, count: input.count)
        var valid = true
        for start in stride(from: 0, to: input.count, by: 480) {
            let ok = input.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    processor.process(src.baseAddress! + start, dst.baseAddress! + start, count: 480)
                }
            }
            valid = valid && ok
        }
        return (output, valid)
    }

    func testBuildBundlesTheProtectionNetwork() throws {
        let url = try XCTUnwrap(PrivacyAudioProcessor.bundledNetworkURL, "ShieldPerturbation.wspn missing from the app bundle")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1_000_000, "weights file looks truncated")
    }

    func testNetworkPerturbsSpeechAndLeavesSilenceAlone() throws {
        let url = try XCTUnwrap(PrivacyAudioProcessor.bundledNetworkURL)
        let processor = try PrivacyAudioProcessor(networkURL: url, modelURL: nil, strength: 1)
        let input = voice(blocks: 200)
        let (output, valid) = run(processor, input)
        XCTAssertTrue(valid)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
        let half = input.count / 2
        let speechDelta = zip(input[..<half], output[..<half]).map { Double($1 - $0) }
        let speechRMS = sqrt(speechDelta.map { $0 * $0 }.reduce(0, +) / Double(half))
        // Skip the first 50 ms of silence: the network's analysis window still holds speech there.
        let tail = Array(zip(input[(half + 2400)...], output[(half + 2400)...]).map { Double($1 - $0) })
        let silenceRMS = sqrt(tail.map { $0 * $0 }.reduce(0, +) / Double(tail.count))
        XCTAssertGreaterThan(speechRMS, 1e-4, "no perturbation applied to speech")
        XCTAssertLessThan(silenceRMS, speechRMS * 0.05, "perturbation should follow the voice and stop in silence")
        let peak = speechDelta.map(abs).max() ?? 0
        XCTAssertLessThan(peak, 0.12, "perturbation exceeds its trained bound")
    }

    func testProcessingIsDeterministicAfterReset() throws {
        let url = try XCTUnwrap(PrivacyAudioProcessor.bundledNetworkURL)
        let input = voice(blocks: 40)
        let a = run(try PrivacyAudioProcessor(networkURL: url, modelURL: nil, strength: 1), input).output
        let b = run(try PrivacyAudioProcessor(networkURL: url, modelURL: nil, strength: 1), input).output
        XCTAssertEqual(a, b)
    }

    func testStrengthZeroIsPassthrough() throws {
        let url = try XCTUnwrap(PrivacyAudioProcessor.bundledNetworkURL)
        let input = voice(blocks: 20)
        let output = run(try PrivacyAudioProcessor(networkURL: url, modelURL: nil, strength: 0), input).output
        for (x, y) in zip(input, output) { XCTAssertEqual(y, min(0.98, max(-0.98, x)), accuracy: 1e-6) }
    }

    func testDamagedWeightsFailClosed() throws {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).wspn")
        try Data("WSPN not really".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        XCTAssertThrowsError(try PrivacyAudioProcessor(networkURL: bad, modelURL: nil, strength: 1))
    }
}

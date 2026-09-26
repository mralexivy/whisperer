//
//  Qwen3ASRDownloadPathTests.swift
//  WhispererTests
//
//  Qwen3-ASR (MLX) front-end parity, encoder length arithmetic and model location. The
//  end-to-end speed/accuracy check lives in `Qwen3ASREndToEndTests` and skips when the
//  model is not downloaded.
//

import XCTest
@testable import whisperer

final class Qwen3ASRDownloadPathTests: XCTestCase {

    // MARK: - Feature extractor parity with HF WhisperFeatureExtractor

    /// Reference values produced by `transformers.WhisperFeatureExtractor` (the checkpoint's
    /// `preprocessor_config.json`) for the same synthetic signal, zero-padded to a whole hop.
    func testFeaturesMatchHuggingFaceWhisperFeatureExtractor() {
        let n = 8_000 + 37
        let samples: [Float] = (0..<n).map { i in
            let t = Double(i) / 16_000
            return Float(0.5 * sin(2 * .pi * 440 * t)
                         + 0.25 * sin(2 * .pi * 1500 * t) * exp(-t * 3)
                         + 0.01 * sin(2 * .pi * 5000 * t))
        }
        let (features, frames) = Qwen3ASRFeatureExtractor.shared.extract(samples: samples)
        XCTAssertEqual(frames, 51, "ceil(8037 / 160) frames")
        XCTAssertEqual(features.count, 128 * frames)

        let expected: [(mel: Int, frame: Int, value: Float)] = [
            (10, 0, 1.006752), (10, 25, -0.514645), (11, 50, 0.978451),
            (30, 12, -0.514645), (90, 7, -0.514645), (60, 20, 0.941304),
        ]
        for e in expected {
            XCTAssertEqual(features[e.mel * frames + e.frame], e.value, accuracy: 2e-3,
                           "mel \(e.mel) frame \(e.frame)")
        }
        let mean = features.reduce(0, +) / Float(features.count)
        XCTAssertEqual(mean, -0.286346, accuracy: 1e-3)
        XCTAssertEqual(features.max() ?? 0, 1.485355, accuracy: 1e-3)
        XCTAssertEqual(features.min() ?? 0, -0.514645, accuracy: 1e-3)
    }

    // MARK: - Encoder output length (HF `_get_feat_extract_output_lengths`)

    func testEncoderOutputLength() {
        XCTAssertEqual(Qwen3ASRAudioEncoder.outputLength(frames: 100), 13)
        XCTAssertEqual(Qwen3ASRAudioEncoder.outputLength(frames: 400), 52)
        XCTAssertEqual(Qwen3ASRAudioEncoder.outputLength(frames: 40), 5)
        XCTAssertEqual(Qwen3ASRAudioEncoder.outputLength(frames: 1), 1)
        XCTAssertEqual(Qwen3ASRAudioEncoder.outputLength(frames: 3_001), 391)
    }

    // MARK: - Model location

    func testModelDirectoryIsHubSnapshotOfRepo() {
        let dir = Qwen3ASREngine.modelDirectory()
        XCTAssertTrue(dir.path.hasSuffix("models/\(Qwen3ASREngine.repoId)"), dir.path)
    }

    func testForcedLanguageTableOnlyCoversModelLanguages() {
        for code in Qwen3ASREngine.forcedLanguageTokens.keys {
            XCTAssertTrue(Qwen3ASREngine.languageCodes.values.contains(code), code)
        }
        XCTAssertEqual(Qwen3ASREngine.forcedLanguageTokens.count, Qwen3ASREngine.languageCodes.count)
    }
}

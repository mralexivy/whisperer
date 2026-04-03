//
//  WhisperModel.swift
//  Whisperer
//
//  Defines available whisper model sizes with metadata
//

import Foundation
import SwiftUI

enum WhisperModel: String, CaseIterable, Identifiable {
    // Standard models
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case medium = "ggml-medium.bin"
    case largeV3 = "ggml-large-v3.bin"

    // Turbo models (optimized for speed)
    case largeTurbo = "ggml-large-v3-turbo.bin"
    case largeTurboQ5 = "ggml-large-v3-turbo-q5_0.bin"

    // Quantized models (smaller file size, good accuracy)
    case largeV3Q5 = "ggml-large-v3-q5_0.bin"

    // Language-specific fine-tuned models
    case ivritLargeTurbo = "ggml-ivrit-v3-turbo.bin"

    // Distilled models (faster inference, good accuracy)
    case distilLargeV3 = "ggml-distil-large-v3.bin"
    case distilSmallEn = "ggml-distil-small.en.bin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeV3: return "Large V3"
        case .largeTurbo: return "Large V3 Turbo"
        case .largeTurboQ5: return "Whisperer V3"
        case .largeV3Q5: return "Large V3 Q5"
        case .distilLargeV3: return "Distil Large V3"
        case .distilSmallEn: return "Distil Small (EN)"
        case .ivritLargeTurbo: return "Hebrew Large V3 Turbo"
        }
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "142 MB"
        case .small: return "466 MB"
        case .medium: return "1.5 GB"
        case .largeV3: return "2.9 GB"
        case .largeTurbo: return "1.5 GB"
        case .largeTurboQ5: return "547 MB"
        case .largeV3Q5: return "1.1 GB"
        case .distilLargeV3: return "756 MB"
        case .distilSmallEn: return "166 MB"
        case .ivritLargeTurbo: return "1.5 GB"
        }
    }

    var speedDescription: String {
        switch self {
        case .tiny: return "Fastest"
        case .base: return "Fast"
        case .small: return "Medium"
        case .medium: return "Slow"
        case .largeV3: return "Slowest"
        case .largeTurbo: return "Fast"
        case .largeTurboQ5: return "Fast"
        case .largeV3Q5: return "Medium"
        case .distilLargeV3: return "Very Fast"
        case .distilSmallEn: return "Very Fast"
        case .ivritLargeTurbo: return "Fast"
        }
    }

    var isDistilled: Bool {
        switch self {
        case .distilLargeV3, .distilSmallEn:
            return true
        default:
            return false
        }
    }

    var isQuantized: Bool {
        switch self {
        case .largeTurboQ5, .largeV3Q5:
            return true
        default:
            return false
        }
    }

    var isTurbo: Bool {
        switch self {
        case .largeTurbo, .largeTurboQ5, .ivritLargeTurbo:
            return true
        default:
            return false
        }
    }

    /// Minimum file size in bytes for a valid download (~65-75% of actual size).
    /// Files smaller than this are corrupted or truncated.
    var minimumFileSizeBytes: Int64 {
        switch self {
        case .tiny:           return 50_000_000      // actual ~75 MB
        case .base:           return 100_000_000     // actual ~142 MB
        case .small:          return 350_000_000     // actual ~466 MB
        case .medium:         return 1_100_000_000   // actual ~1.5 GB
        case .largeV3:        return 2_000_000_000   // actual ~2.9 GB
        case .largeTurbo:     return 1_100_000_000   // actual ~1.5 GB
        case .largeTurboQ5:   return 400_000_000     // actual ~547 MB
        case .largeV3Q5:      return 750_000_000     // actual ~1.1 GB
        case .distilLargeV3:  return 500_000_000     // actual ~756 MB
        case .distilSmallEn:  return 110_000_000     // actual ~166 MB
        case .ivritLargeTurbo: return 1_100_000_000  // actual ~1.5 GB
        }
    }

    /// Approximate memory required to load and run this model (file size + Metal GPU overhead)
    var requiredMemoryGB: Double {
        switch self {
        case .tiny:           return 0.2
        case .base:           return 0.3
        case .small:          return 0.8
        case .medium:         return 2.5
        case .largeV3:        return 5.0
        case .largeTurbo:     return 2.5
        case .largeTurboQ5:   return 1.0
        case .largeV3Q5:      return 2.0
        case .distilLargeV3:  return 1.5
        case .distilSmallEn:  return 0.4
        case .ivritLargeTurbo: return 2.5
        }
    }

    var categoryIcon: String {
        switch self {
        case .largeTurboQ5:
            return "sparkles"
        case .largeTurbo, .largeV3Q5:
            return "bolt.fill"
        case .ivritLargeTurbo:
            return "star.of.david.fill"
        case .distilLargeV3, .distilSmallEn:
            return "wand.and.stars"
        default:
            return "cube.fill"
        }
    }

    var categoryColor: Color {
        switch self {
        case .largeTurboQ5:
            return Color(red: 0.357, green: 0.424, blue: 0.969) // accent
        case .largeTurbo, .largeV3Q5:
            return .orange
        case .ivritLargeTurbo:
            return .blue
        case .distilLargeV3, .distilSmallEn:
            return .red
        default:
            return .blue
        }
    }

    var isRecommended: Bool { self == .largeTurboQ5 }

    /// Display order with recommended model first
    static let displayOrder: [WhisperModel] = [
        .largeTurboQ5, .largeTurbo, .ivritLargeTurbo, .largeV3Q5,
        .distilLargeV3, .distilSmallEn,
        .tiny, .base, .small, .medium, .largeV3,
    ]

    var modelDescription: String {
        switch self {
        case .largeTurboQ5:
            return "Best balance of speed, size & accuracy"
        case .largeTurbo:
            return "8x faster than large-v3, high accuracy"
        case .largeV3Q5:
            return "Quantized large-v3, smaller file"
        case .distilLargeV3:
            return "6x faster than large-v3, good accuracy"
        case .distilSmallEn:
            return "2x faster than small, English only"
        case .ivritLargeTurbo:
            return "Fine-tuned for Hebrew, best Hebrew accuracy"
        default:
            return ""
        }
    }

    /// Language restriction for fine-tuned models. Nil means all languages supported.
    var supportedLanguage: TranscriptionLanguage? {
        switch self {
        case .ivritLargeTurbo: return .hebrew
        default: return nil
        }
    }

    var isLanguageRestricted: Bool { supportedLanguage != nil }

    /// Core ML encoder directory name that whisper.cpp looks for next to the .bin file.
    /// whisper.cpp strips quantization suffix (e.g., "-q5_0") automatically.
    var coreMLEncoderDirectoryName: String? {
        switch self {
        case .tiny: return "ggml-tiny-encoder.mlmodelc"
        case .base: return "ggml-base-encoder.mlmodelc"
        case .small: return "ggml-small-encoder.mlmodelc"
        case .medium: return "ggml-medium-encoder.mlmodelc"
        case .largeV3: return "ggml-large-v3-encoder.mlmodelc"
        case .largeTurbo, .largeTurboQ5: return "ggml-large-v3-turbo-encoder.mlmodelc"
        case .largeV3Q5: return "ggml-large-v3-encoder.mlmodelc"
        case .distilLargeV3: return nil  // No Core ML encoder available
        case .distilSmallEn: return nil
        case .ivritLargeTurbo: return nil
        }
    }

    /// Download URL for the Core ML encoder zip
    var coreMLEncoderDownloadURL: URL? {
        guard let dirName = coreMLEncoderDirectoryName else { return nil }
        let zipName = dirName.replacingOccurrences(of: ".mlmodelc", with: ".mlmodelc.zip")
        return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(zipName)")
    }

    /// Whether this is an English-only model variant
    var isEnglishOnly: Bool {
        switch self {
        case .distilSmallEn: return true
        default: return false
        }
    }

    /// Whether this model supports multilingual transcription
    var isMultilingual: Bool { !isEnglishOnly }

    /// The model used for language detection (must be multilingual)
    static let detectorModel: WhisperModel = .tiny

    /// Best model for a specific language from available downloaded models
    static func recommendedModel(
        for language: TranscriptionLanguage,
        downloaded: Set<WhisperModel>
    ) -> WhisperModel? {
        switch language {
        case .english:
            if downloaded.contains(.distilSmallEn) { return .distilSmallEn }
            return nil
        case .hebrew:
            if downloaded.contains(.ivritLargeTurbo) { return .ivritLargeTurbo }
            return nil
        default:
            return nil  // use default multilingual
        }
    }

    var downloadURL: URL {
        switch self {
        case .distilLargeV3:
            // Hosted at official distil-whisper repo
            return URL(string: "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/ggml-distil-large-v3.bin")!
        case .distilSmallEn:
            // Hosted at dharmab's community repo
            return URL(string: "https://huggingface.co/dharmab/distill-whisper-ggml/resolve/main/ggml-distil-small.en.bin")!
        case .ivritLargeTurbo:
            // Hebrew fine-tuned model from ivrit-ai
            return URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin")!
        default:
            // Standard models from ggerganov/whisper.cpp
            return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
        }
    }

    // Default model: Large V3 Turbo Q5 - best balance of speed, size & accuracy
    static var `default`: WhisperModel { .largeTurboQ5 }

    /// Initialize from raw filename, returns nil if not found
    init?(filename: String) {
        if let model = WhisperModel.allCases.first(where: { $0.rawValue == filename }) {
            self = model
        } else {
            return nil
        }
    }
}

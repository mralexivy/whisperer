//
//  WhisperModel.swift
//  Whisperer
//
//  Defines available whisper model sizes with metadata
//

import Foundation

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
        case .largeTurboQ5: return "Large V3 Turbo Q5"
        case .largeV3Q5: return "Large V3 Q5"
        case .distilLargeV3: return "Distil Large V3"
        case .distilSmallEn: return "Distil Small (EN)"
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
        case .largeTurbo, .largeTurboQ5:
            return true
        default:
            return false
        }
    }

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
        default:
            return ""
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

//
//  WhisperModel.swift
//  Whisperer
//
//  Defines available whisper model sizes with metadata
//

import Foundation

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case medium = "ggml-medium.bin"
    case largeTurbo = "ggml-large-v3-turbo.bin"
    case largeV3 = "ggml-large-v3.bin"

    // Distilled models (faster, smaller, good accuracy)
    case distilLargeV3 = "ggml-distil-large-v3.bin"
    case distilMediumEn = "ggml-distil-medium.en.bin"
    case distilSmallEn = "ggml-distil-small.en.bin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeTurbo: return "Large V3 Turbo"
        case .largeV3: return "Large V3"
        case .distilLargeV3: return "Distil Large V3"
        case .distilMediumEn: return "Distil Medium (EN)"
        case .distilSmallEn: return "Distil Small (EN)"
        }
    }

    var sizeDescription: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "142 MB"
        case .small: return "466 MB"
        case .medium: return "1.5 GB"
        case .largeTurbo: return "1.5 GB"
        case .largeV3: return "2.9 GB"
        case .distilLargeV3: return "1.0 GB"
        case .distilMediumEn: return "400 MB"
        case .distilSmallEn: return "170 MB"
        }
    }

    var speedDescription: String {
        switch self {
        case .tiny: return "Fastest"
        case .base: return "Fast"
        case .small: return "Medium"
        case .medium: return "Slow"
        case .largeTurbo: return "Fast"
        case .largeV3: return "Slowest"
        case .distilLargeV3: return "Very Fast"
        case .distilMediumEn: return "Very Fast"
        case .distilSmallEn: return "Very Fast"
        }
    }

    var isDistilled: Bool {
        switch self {
        case .distilLargeV3, .distilMediumEn, .distilSmallEn:
            return true
        default:
            return false
        }
    }

    var modelDescription: String {
        switch self {
        case .distilLargeV3:
            return "6x faster than large-v3, high accuracy"
        case .distilMediumEn:
            return "2x faster than medium, English only"
        case .distilSmallEn:
            return "2x faster than small, English only"
        default:
            return ""
        }
    }

    var downloadURL: URL {
        switch self {
        case .distilLargeV3:
            return URL(string: "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/\(rawValue)")!
        case .distilMediumEn:
            return URL(string: "https://huggingface.co/distil-whisper/distil-medium.en-ggml/resolve/main/\(rawValue)")!
        case .distilSmallEn:
            return URL(string: "https://huggingface.co/distil-whisper/distil-small.en-ggml/resolve/main/\(rawValue)")!
        default:
            return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
        }
    }

    static var `default`: WhisperModel { .largeTurbo }

    /// Initialize from raw filename, returns nil if not found
    init?(filename: String) {
        if let model = WhisperModel.allCases.first(where: { $0.rawValue == filename }) {
            self = model
        } else {
            return nil
        }
    }
}

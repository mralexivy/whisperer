//
//  LLMModelVariant.swift
//  Whisperer
//
//  Qwen3.5 model variants for local LLM post-processing
//

import Foundation

enum LLMModelVariant: String, CaseIterable, Identifiable {
    case qwen3_5_0_8B = "Qwen3.5-0.8B"
    case qwen3_5_2B = "Qwen3.5-2B"
    case qwen3_5_4B = "Qwen3.5-4B"
    case qwen3_5_9B = "Qwen3.5-9B"

    var id: String { rawValue }

    var huggingFaceId: String {
        "mlx-community/\(rawValue)-4bit"
    }

    var displayName: String { rawValue }

    var sizeDescription: String {
        switch self {
        case .qwen3_5_0_8B: return "~0.6 GB"
        case .qwen3_5_2B: return "~1.6 GB"
        case .qwen3_5_4B: return "~2.8 GB"
        case .qwen3_5_9B: return "~5.5 GB"
        }
    }

    var speedDescription: String {
        switch self {
        case .qwen3_5_0_8B: return "Fastest"
        case .qwen3_5_2B: return "Fast"
        case .qwen3_5_4B: return "Balanced"
        case .qwen3_5_9B: return "Best quality"
        }
    }
}

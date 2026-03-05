//
//  LLMModelVariant.swift
//  Whisperer
//
//  Qwen3 model variants for local LLM post-processing
//

import Foundation

enum LLMModelVariant: String, CaseIterable, Identifiable {
    case qwen3_0_6B = "Qwen3-0.6B"
    case qwen3_1_7B = "Qwen3-1.7B"
    case qwen3_4B = "Qwen3-4B"
    case qwen3_8B = "Qwen3-8B"

    var id: String { rawValue }

    var huggingFaceId: String {
        "mlx-community/\(rawValue)-4bit"
    }

    var displayName: String { rawValue }

    var sizeDescription: String {
        switch self {
        case .qwen3_0_6B: return "~0.4 GB"
        case .qwen3_1_7B: return "~1.0 GB"
        case .qwen3_4B: return "~2.5 GB"
        case .qwen3_8B: return "~4.6 GB"
        }
    }

    var speedDescription: String {
        switch self {
        case .qwen3_0_6B: return "Fastest"
        case .qwen3_1_7B: return "Fast"
        case .qwen3_4B: return "Balanced"
        case .qwen3_8B: return "Best quality"
        }
    }
}

//
//  LLMModelVariant.swift
//  Whisperer
//
//  LLM model variants for local post-processing
//

import Foundation

enum LLMModelVariant: String, CaseIterable, Identifiable {
    case qwen3_0_6B = "Qwen3-0.6B"
    case qwen3_5_4B = "Qwen3.5-4B"
    case qwen3_5_2B = "Qwen3.5-2B"
    case qwen3_5_9B = "Qwen3.5-9B"

    var id: String { rawValue }

    var huggingFaceId: String {
        switch self {
        case .qwen3_0_6B: return "mlx-community/Qwen3-0.6B-4bit"
        case .qwen3_5_4B: return "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .qwen3_5_2B: return "mlx-community/Qwen3.5-2B-MLX-4bit"
        case .qwen3_5_9B: return "mlx-community/Qwen3.5-9B-MLX-4bit"
        }
    }

    var displayName: String { rawValue }

    var sizeDescription: String {
        switch self {
        case .qwen3_0_6B: return "~0.4 GB"
        case .qwen3_5_4B: return "~2.8 GB"
        case .qwen3_5_2B: return "~1.6 GB"
        case .qwen3_5_9B: return "~5.5 GB"
        }
    }

    var speedDescription: String {
        switch self {
        case .qwen3_0_6B: return "Ultra-fast"
        case .qwen3_5_4B: return "Balanced"
        case .qwen3_5_2B: return "Fast"
        case .qwen3_5_9B: return "Best quality"
        }
    }

    var isRecommended: Bool {
        self == .qwen3_5_4B
    }
}

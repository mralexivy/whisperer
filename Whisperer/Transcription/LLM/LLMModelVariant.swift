//
//  LLMModelVariant.swift
//  Whisperer
//
//  LLM model variants for local post-processing
//

import Foundation

enum LLMModelVariant: String, CaseIterable, Identifiable {
    case whispererV3 = "Whisperer V3"
    case qwen3_5_4B_mtp = "Qwen3.5-4B (MTP)"
    case qwen3_5_4B = "Qwen3.5-4B"
    case qwen3_5_2B = "Qwen3.5-2B"
    case qwen3_5_9B = "Qwen3.5-9B"

    var id: String { rawValue }

    var huggingFaceId: String {
        switch self {
        case .whispererV3:    return "shantanugoel/aawaaz-qwen3-0.6b-transcriber-4bit"
        case .qwen3_5_4B_mtp: return "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed"
        case .qwen3_5_4B:     return "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .qwen3_5_2B:     return "mlx-community/Qwen3.5-2B-MLX-4bit"
        case .qwen3_5_9B:     return "mlx-community/Qwen3.5-9B-MLX-4bit"
        }
    }

    var displayName: String { rawValue }

    var sizeDescription: String {
        switch self {
        case .whispererV3:    return "~0.3 GB"
        case .qwen3_5_4B_mtp: return "~3.2 GB"
        case .qwen3_5_4B:     return "~2.8 GB"
        case .qwen3_5_2B:     return "~1.6 GB"
        case .qwen3_5_9B:     return "~5.5 GB"
        }
    }

    var speedDescription: String {
        switch self {
        case .whispererV3:    return "Ultra-fast · EN"
        case .qwen3_5_4B_mtp: return "Ultra-fast (MTP)"
        case .qwen3_5_4B:     return "Balanced"
        case .qwen3_5_2B:     return "Fast"
        case .qwen3_5_9B:     return "Best quality"
        }
    }

    var isRecommended: Bool {
        self == .whispererV3
    }

    /// True for models that embed MTP speculative decoding heads and use generateMTPTokens().
    var isMTPCapable: Bool {
        self == .qwen3_5_4B_mtp
    }
}

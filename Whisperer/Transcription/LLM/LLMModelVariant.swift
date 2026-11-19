//
//  LLMModelVariant.swift
//  Whisperer
//
//  LLM model variants for local post-processing
//

import Foundation
import FoundationModels

nonisolated enum LLMModelVariant: String, CaseIterable, Identifiable {
    case qwen2_5_1_5B = "Qwen2.5-1.5B"
    case whispererV3 = "Whisperer V3"
    case qwen3_5_4B_mtp = "Qwen3.5-4B (MTP)"
    case qwen3_5_4B = "Qwen3.5-4B"
    case qwen3_5_2B = "Qwen3.5-2B"
    case qwen3_5_9B = "Qwen3.5-9B"
    /// The model macOS ships (Foundation Models). Nothing to download; used only where macOS reports it available.
    case appleIntelligence = "Apple Intelligence"

    var id: String { rawValue }

    var huggingFaceId: String {
        switch self {
        case .qwen2_5_1_5B:   return "mlx-community/Qwen2.5-1.5B-Instruct-8bit"
        case .whispererV3:    return "shantanugoel/aawaaz-qwen3-0.6b-transcriber-4bit"
        case .qwen3_5_4B_mtp: return "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed"
        case .qwen3_5_4B:     return "mlx-community/Qwen3.5-4B-MLX-4bit"
        case .qwen3_5_2B:     return "mlx-community/Qwen3.5-2B-MLX-4bit"
        case .qwen3_5_9B:     return "mlx-community/Qwen3.5-9B-MLX-4bit"
        case .appleIntelligence: return ""   // not a download
        }
    }

    var displayName: String { rawValue }

    var sizeDescription: String {
        switch self {
        case .qwen2_5_1_5B:   return "~1.6 GB"
        case .whispererV3:    return "~0.3 GB"
        case .qwen3_5_4B_mtp: return "~3.2 GB"
        case .qwen3_5_4B:     return "~2.8 GB"
        case .qwen3_5_2B:     return "~1.6 GB"
        case .qwen3_5_9B:     return "~5.5 GB"
        case .appleIntelligence: return "Built into macOS"
        }
    }

    var speedDescription: String {
        switch self {
        case .qwen2_5_1_5B:   return "Fast · Multilingual"
        case .whispererV3:    return "Ultra-fast · EN"
        case .qwen3_5_4B_mtp: return "Ultra-fast (MTP)"
        case .qwen3_5_4B:     return "Balanced"
        case .qwen3_5_2B:     return "Fast"
        case .qwen3_5_9B:     return "Best quality"
        case .appleIntelligence: return "No download · Multilingual"
        }
    }

    /// Whether the weights can be downloaded in this market (`ModelSources`).
    /// Apple Intelligence is not a download: macOS itself says whether this Mac has it, in every market.
    var isAvailableInThisMarket: Bool {
        self == .appleIntelligence ? Self.appleIntelligenceIsAvailable : ModelSources.isReachable(repo: huggingFaceId)
    }

    static var appleIntelligenceIsAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Models that run through MLX weights Whisperer downloads.
    private static var downloadable: [LLMModelVariant] { allCases.filter { $0 != .appleIntelligence } }

    /// The variants this market offers.
    /// The China edition offers exactly one: the best Qwen it can download.
    static var available: [LLMModelVariant] {
        let reachable = downloadable.filter(\.isAvailableInThisMarket)
        // The model built into macOS is offered wherever macOS has it, the China edition included.
        let builtIn: [LLMModelVariant] = appleIntelligenceIsAvailable ? [.appleIntelligence] : []
        guard MarketPolicy.isChinaEdition else { return reachable + builtIn }
        let one = [qwen3_5_4B_mtp, qwen3_5_4B].first(where: reachable.contains) ?? reachable.first
        return (one.map { [$0] } ?? []) + builtIn
    }

    /// The default LLM: the recommended MTP build, or the plain 4B where only that one can be downloaded.
    static var marketDefault: LLMModelVariant {
        qwen3_5_4B_mtp.isAvailableInThisMarket ? .qwen3_5_4B_mtp : (qwen3_5_4B.isAvailableInThisMarket ? .qwen3_5_4B : available.first ?? .qwen3_5_4B_mtp)
    }

    var isRecommended: Bool {
        self == .qwen3_5_4B_mtp
    }

    /// True for models that embed MTP speculative decoding heads and use generateMTPTokens().
    var isMTPCapable: Bool {
        self == .qwen3_5_4B_mtp
    }
}

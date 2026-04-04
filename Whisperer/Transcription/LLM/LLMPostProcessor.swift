//
//  LLMPostProcessor.swift
//  Whisperer
//
//  Local LLM post-processor using MLXLLM (Qwen3) for transcription refinement
//

import Foundation
import Combine
import MLXLLM
import MLXLMCommon

enum LLMLoadPhase: Equatable {
    case idle
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

@MainActor
class LLMPostProcessor: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var isProcessing = false
    @Published var loadPhase: LLMLoadPhase = .idle
    @Published var errorMessage: String?

    // Legacy — kept for backward compat with any code reading loadProgress
    var loadProgress: Double {
        if case .downloading(let p) = loadPhase { return p }
        if case .ready = loadPhase { return 1.0 }
        return 0
    }

    private var modelContainer: ModelContainer?
    private var loadedVariant: LLMModelVariant?

    // MARK: - Model Management

    func loadModel(_ variant: LLMModelVariant) async throws {
        guard !isLoading else {
            Logger.debug("LLM load already in progress, skipping", subsystem: .model)
            return
        }
        guard loadedVariant != variant else {
            Logger.info("LLM \(variant.displayName) already loaded", subsystem: .model)
            return
        }

        Logger.info("Loading LLM \(variant.displayName)...", subsystem: .model)
        isModelLoaded = false
        isLoading = true
        errorMessage = nil
        loadPhase = .loading

        var didReceiveProgress = false

        let configuration = ModelConfiguration(id: variant.huggingFaceId)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    let fraction = progress.fractionCompleted
                    if fraction > 0 {
                        didReceiveProgress = true
                        self?.loadPhase = .downloading(progress: fraction)
                    }
                }
            }
        )

        // Download done (if it happened) — now loading into memory
        if didReceiveProgress {
            loadPhase = .loading
            Logger.info("LLM \(variant.displayName) downloaded, loading into memory...", subsystem: .model)
        }

        modelContainer = container
        loadedVariant = variant
        isModelLoaded = true
        isLoading = false
        loadPhase = .ready
        errorMessage = nil

        Logger.info("LLM \(variant.displayName) loaded", subsystem: .model)
    }

    func unloadModel() {
        modelContainer = nil
        loadedVariant = nil
        isModelLoaded = false
        isLoading = false
        loadPhase = .idle
        errorMessage = nil
        Logger.info("LLM unloaded", subsystem: .model)
    }

    // MARK: - Processing
    func process(text: String, systemPrompt: String, targetLanguage: String? = nil, temperature: Float = 0.3, topP: Float = 0.9) async throws -> String {
        guard let container = modelContainer else {
            Logger.warning("LLM not loaded, returning original text", subsystem: .transcription)
            return text
        }

        isProcessing = true
        defer { isProcessing = false }

        guard !systemPrompt.isEmpty else {
            return text
        }

        // Fresh session per call — proper system/user message separation,
        // no cross-call context leaking from previous transcriptions
        var instructions = systemPrompt
        if let lang = targetLanguage, !lang.isEmpty {
            instructions += " Translate to \(lang)."
        }

        // Qwen3.5 recommended params for non-thinking (instruct) mode:
        // temperature=0.7, top_p=0.8, top_k=20, presence_penalty=1.5
        // maxTokens caps output to 2x input length to prevent runaway generation
        let maxTokens = max(256, text.count * 2)
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                topK: 20,
                repetitionPenalty: 1.2,
                presencePenalty: 1.5
            ),
            additionalContext: ["enable_thinking": false]
        )

        var result = try await session.respond(to: text)

        // Strip <think>...</think> tags from Qwen3 models
        if let thinkRange = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.removeSubrange(thinkRange)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

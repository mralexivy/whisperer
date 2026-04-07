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

        // Track download progress on MainActor to avoid data race with background progress callbacks
        var didReceiveProgress = false

        let configuration = ModelConfiguration(id: variant.huggingFaceId)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    let fraction = progress.fractionCompleted
                    if fraction > 0 {
                        didReceiveProgress = true
                        self?.loadPhase = .downloading(progress: fraction)
                    }
                }
            }
        )

        // Download done (if it happened) — now loading into memory.
        // didReceiveProgress is safe to read here: loadContainer awaits completion of all
        // progress callbacks before returning, and we're back on @MainActor.
        if didReceiveProgress {
            loadPhase = .loading
            Logger.info("LLM \(variant.displayName) downloaded, loading into memory...", subsystem: .model)
        }

        // Check cancellation after the long await — if the user switched models or disabled LLM
        // while we were loading, discard the container to free GPU buffers immediately
        guard !Task.isCancelled else {
            isLoading = false
            loadPhase = .idle
            Logger.info("LLM load cancelled for \(variant.displayName)", subsystem: .model)
            return
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

    func process(
        text: String,
        systemPrompt: String,
        userMessage: String,
        targetLanguage: String? = nil,
        temperature: Float = 0.0,
        topP: Float = 1.0,
        topK: Int = 0,
        repetitionPenalty: Float = 1.05,
        maxTokensCap: Int = 256
    ) async throws -> String {
        guard let container = modelContainer else {
            Logger.warning("LLM not loaded, returning original text", subsystem: .transcription)
            return text
        }

        guard !systemPrompt.isEmpty else {
            return text
        }

        isProcessing = true
        defer { isProcessing = false }

        var instructions = systemPrompt
        if let lang = targetLanguage, !lang.isEmpty {
            instructions += " Translate to \(lang)."
        }

        // maxTokens: tight cap based on input size + mode ceiling
        let estimatedTokens = max(16, text.count / 4)
        let maxTokens = max(32, min(maxTokensCap, Int(ceil(Float(estimatedTokens) * 1.15))))

        Logger.debug("LLM gen: inputChars=\(text.count) estTokens=\(estimatedTokens) maxTokens=\(maxTokens) cap=\(maxTokensCap) temp=\(temperature) topP=\(topP) topK=\(topK) repPenalty=\(repetitionPenalty)", subsystem: .transcription)

        // Fresh session per call — no cross-call context leaking
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                topK: topK,
                repetitionPenalty: repetitionPenalty
            ),
            additionalContext: ["enable_thinking": false]
        )

        // Stream to capture finish reason and real token counts
        var result = ""
        var completionInfo: GenerateCompletionInfo?
        for try await generation in session.streamDetails(to: userMessage, images: [], videos: []) {
            switch generation {
            case .chunk(let chunk):
                result += chunk
            case .info(let info):
                completionInfo = info
            case .toolCall:
                break
            }
        }

        // Log generation diagnostics
        if let info = completionInfo {
            Logger.debug("LLM gen: promptTokens=\(info.promptTokenCount) genTokens=\(info.generationTokenCount) stopReason=\(info.stopReason) promptTime=\(String(format: "%.1f", info.promptTime * 1000))ms genTime=\(String(format: "%.1f", info.generateTime * 1000))ms", subsystem: .transcription)
        } else {
            Logger.warning("LLM gen: stream ended without completion info", subsystem: .transcription)
        }

        // Strip <think>...</think> tags from Qwen3 models
        if let thinkRange = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.removeSubrange(thinkRange)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

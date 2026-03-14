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

@MainActor
class LLMPostProcessor: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var isProcessing = false
    @Published var loadProgress: Double = 0
    @Published var errorMessage: String?

    private var modelContainer: ModelContainer?
    private var session: ChatSession?
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
        loadProgress = 0

        let configuration = ModelConfiguration(id: variant.huggingFaceId)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    let fraction = progress.fractionCompleted
                    if fraction > 0 {
                        self?.loadProgress = fraction
                    }
                }
            }
        )

        modelContainer = container
        session = ChatSession(container)
        loadedVariant = variant
        isModelLoaded = true
        isLoading = false
        loadProgress = 1.0

        Logger.info("LLM \(variant.displayName) loaded", subsystem: .model)
    }

    func unloadModel() {
        session = nil
        modelContainer = nil
        loadedVariant = nil
        isModelLoaded = false
        isLoading = false
        loadProgress = 0
        errorMessage = nil
        Logger.info("LLM unloaded", subsystem: .model)
    }

    // MARK: - Processing

    func process(text: String, task: LLMTask, customPrompt: String? = nil, targetLanguage: String? = nil) async throws -> String {
        guard let session = session else {
            Logger.warning("LLM not loaded, returning original text", subsystem: .transcription)
            return text
        }

        isProcessing = true
        defer { isProcessing = false }

        var prompt: String
        switch task {
        case .translate:
            let lang = targetLanguage ?? "English"
            prompt = "\(task.systemPrompt) Translate to \(lang).\n\nText: \(text)"
        case .custom:
            let userPrompt = customPrompt ?? "Improve this text"
            prompt = "\(userPrompt)\n\nText: \(text)"
        default:
            prompt = "\(task.systemPrompt)\n\nText: \(text)"
        }

        let result = try await session.respond(to: prompt)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

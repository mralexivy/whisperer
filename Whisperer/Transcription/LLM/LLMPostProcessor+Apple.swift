//
//  LLMPostProcessor+Apple.swift
//  Whisperer
//
//  The model macOS ships (Foundation Models) behind the same `LLMPostProcessor` entry points that
//  dictation's rewrite modes already call, so `isModelLoaded`, preload and the mode pipeline need
//  no second code path. There are no weights to load: "loading" checks that macOS reports the model
//  available, and `process` is one request to the system model.
//
//  Languages: `supportsLocale` is false for Hebrew and Russian, yet the model answers them (see
//  docs/knowledge/llm/knowledge.md), so no language gate sits here. When the model refuses a text
//  the caller gets the original text back, the same as any other model that produced nothing usable.
//

import Foundation
import FoundationModels

extension LLMPostProcessor {

    /// Marks the model ready if macOS has it. Nothing is downloaded or held in memory by Whisperer.
    func loadAppleIntelligence() throws {
        guard SystemLanguageModel.default.isAvailable else {
            let message = AppleIntelligenceProvider.readiness(for: SystemLanguageModel.default.availability).statusText
            loadPhase = .error(message)
            errorMessage = message
            isModelLoaded = false
            isLoading = false
            throw LLMFallbackError.noModelLoaded
        }
        setAppleIntelligenceLoaded()
        Logger.info("LLM Apple Intelligence ready (context \(SystemLanguageModel.default.contextSize) tokens)", subsystem: .model)
    }

    func processAppleIntelligence(
        text: String, systemPrompt: String, userMessage: String, targetLanguage: String?,
        maxTokens: Int, onPartialText: (@Sendable (String) -> Void)?,
        throwOnFallback: Bool, priority: ModelWorkPriority
    ) async throws -> String {
        guard !systemPrompt.isEmpty else { return text }
        await ForegroundGate.shared.waitWhileRaisedAsync("apple-intelligence", priority: priority)

        isProcessing = true
        defer { isProcessing = false }

        var instructions = systemPrompt
        if let lang = targetLanguage, !lang.isEmpty { instructions += " Translate to \(lang)." }

        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: max(16, maxTokens))
        let started = Date()
        do {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            var output: String
            if let onPartialText {
                output = ""
                for try await snapshot in session.streamResponse(to: userMessage, options: options) {
                    output = snapshot.content
                    onPartialText(output)
                }
            } else {
                output = try await session.respond(to: userMessage, options: options).content
            }
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.debug("LLM Apple Intelligence: \(text.count) → \(output.count) chars in \(Int(Date().timeIntervalSince(started) * 1000))ms", subsystem: .transcription)
            if output.isEmpty {
                if throwOnFallback { throw LLMFallbackError.emptyOutput }
                return text
            }
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mapped = AppleIntelligenceProvider.map(error)
            Logger.warning("LLM Apple Intelligence failed (\(mapped)) — returning original text", subsystem: .transcription)
            if throwOnFallback { throw mapped }
            return text
        }
    }
}

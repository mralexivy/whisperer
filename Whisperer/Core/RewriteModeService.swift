//
//  RewriteModeService.swift
//  Whisperer
//
//  Handles rewrite mode: voice instruction + selected text -> LLM -> inject result
//

import Foundation

@MainActor
class RewriteModeService {
    private let llmProcessor: LLMPostProcessor

    init(llmProcessor: LLMPostProcessor) {
        self.llmProcessor = llmProcessor
    }

    /// Processes a rewrite request.
    /// - Parameters:
    ///   - instruction: Voice-transcribed instruction from the user
    ///   - selectedText: Text selected in the target app (nil = write mode)
    ///   - rewritePrompt: Optional system prompt override from active profile
    /// - Returns: The rewritten/generated text
    func process(instruction: String, selectedText: String?, rewritePrompt: String?) async throws -> String {
        guard llmProcessor.isModelLoaded else {
            Logger.warning("LLM not loaded for rewrite mode", subsystem: .transcription)
            return instruction
        }

        if let selected = selectedText, !selected.isEmpty {
            // Rewrite mode: apply instruction to selected text
            let prompt = buildRewritePrompt(instruction: instruction, selectedText: selected, systemPrompt: rewritePrompt)
            return try await llmProcessor.process(text: selected, systemPrompt: prompt)
        } else {
            // Write mode: generate text from instruction alone
            let prompt = buildWritePrompt(instruction: instruction, systemPrompt: rewritePrompt)
            return try await llmProcessor.process(text: instruction, systemPrompt: prompt)
        }
    }

    // MARK: - Prompt Building

    private func buildRewritePrompt(instruction: String, selectedText: String, systemPrompt: String?) -> String {
        if let custom = systemPrompt, !custom.isEmpty {
            return """
            \(custom)

            User instruction: \(instruction)

            Apply the instruction to the following text. Return only the result; no explanations.
            """
        }

        return """
        You are a text editor. The user has selected text and given a voice instruction for how to modify it.

        User instruction: \(instruction)

        Apply the instruction to the text below. Return only the modified text; no explanations.
        """
    }

    private func buildWritePrompt(instruction: String, systemPrompt: String?) -> String {
        if let custom = systemPrompt, !custom.isEmpty {
            return """
            \(custom)

            User instruction: \(instruction)

            Generate text based on the instruction. Return only the result; no explanations.
            """
        }

        return """
        You are a writing assistant. The user has given a voice instruction for what to write.

        Generate text based on this instruction. Return only the text; no explanations.
        """
    }
}

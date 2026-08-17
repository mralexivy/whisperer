//
//  LLMEditingModel.swift
//  Whisperer
//
//  The existing 4B, behind the gate instead of in front of it. Scaffolding — retired at the
//  end of M4, when `MMBERTEditingModel` has weights.
//
//  Nothing about the model or the prompt changes here. `LLMPostProcessor` is used exactly as
//  `AppState` uses it and the Correct prompt is taken verbatim from `AIMode.builtInModes` —
//  the prompt was evolved against a 112-case gold corpus and its examples are worth 0.11
//  balanced score, so re-deriving or trimming it would silently change what is being measured.
//  What changes is what happens to the output: instead of replacing the transcript wholesale,
//  it is diffed back into per-token edits that `ConfidenceGate` judges one at a time.
//
//  **Confidence.** A decoder emits token log-probabilities for its own output, not a
//  calibrated probability that a given edit is correct — and this path does not even see the
//  logprobs, because `process()` returns a `String`. So there is no honest per-edit number to
//  report, and this type reports `unclaimedConfidence` (0.50) rather than inventing one.
//
//  The gate's floor for `.llm` is 0.99, so in practice **every edit this produces is refused
//  today**. That is the intended M2/M3 state and not a bug: the plan ships a model-sourced
//  edit only at ≥99% measured precision per language per action at `ASRCapabilities = []`,
//  and until that measurement exists the correct number of auto-applied model edits is zero.
//  The value of this type before then is that the benchmark can count how many edits *would*
//  have been applied, per language and per action, which is precisely the data the calibration
//  needs. Raising this constant is the last step of that calibration, not a shortcut past it.
//

import Foundation

final class LLMEditingModel: EditingModel {

    // MARK: - Calibration

    /// See the note above. Deliberately below every floor in `ConfidenceGate`, so that
    /// forgetting to calibrate degrades to "no model edits" rather than to "all model edits".
    static let unclaimedConfidence: Float = 0.50

    // MARK: - Prompt

    /// The sampling parameters and prompt that belong to one `AIMode`, snapshotted at init.
    ///
    /// A copy rather than the `AIMode` itself: this type is used from a non-isolated async
    /// context, and reducing the captured surface to plain value fields keeps that trivially
    /// safe without adding conformances to a `Codable` model type owned elsewhere.
    struct PromptConfig: Sendable {
        let systemPrompt: String
        let temperature: Float
        let topP: Float
        let topK: Int
        let repetitionPenalty: Float
        let maxTokensCap: Int

        /// Split an `AIMode` prompt at `{transcript}` into a system prompt and the envelope
        /// the user message is built from.
        ///
        /// Mirrors `AppState.splitPrompt`, which is private and belongs to a type this seam
        /// must not modify. Duplicated on purpose and kept to the same shape — the `[INPUT]`
        /// envelope is part of what the prompt was measured with, so the two must not drift.
        init(mode: AIMode) {
            var head = mode.prompt.components(separatedBy: "{transcript}").first ?? mode.prompt
            if let inputRange = head.range(of: "[INPUT]", options: .backwards) {
                head = String(head[..<inputRange.lowerBound])
            }
            systemPrompt = head.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\nDo not include [INPUT] or [/INPUT] in your response."
            temperature = mode.temperature
            topP = mode.topP
            topK = mode.topK
            repetitionPenalty = mode.repetitionPenalty
            maxTokensCap = mode.maxTokensCap
        }

        /// The unmodified Correct mode. Falls back to an empty prompt if the built-in table is
        /// ever renumbered, which `LLMPostProcessor.process` treats as "return the input".
        static var correct: PromptConfig {
            guard let mode = AIMode.builtInDefault(for: AIMode.correctModeId) else {
                Logger.error("Correct mode missing from the built-in table",
                             subsystem: .transcription)
                return PromptConfig(mode: AIMode(id: AIMode.correctModeId, name: "Correct",
                                                 icon: "", color: "", prompt: "",
                                                 temperature: 0, topP: 1, isBuiltIn: true,
                                                 sortOrder: 0))
            }
            return PromptConfig(mode: mode)
        }
    }

    // MARK: - State

    /// `LLMPostProcessor` is `@MainActor`, so the reference itself crosses isolation safely
    /// and every member access below happens with an `await` onto the main actor.
    private let processor: LLMPostProcessor
    private let config: PromptConfig
    private let confidence: Float

    init(processor: LLMPostProcessor,
         config: PromptConfig = .correct,
         confidence: Float = LLMEditingModel.unclaimedConfidence) {
        self.processor = processor
        self.config = config
        self.confidence = confidence
    }

    // MARK: - EditingModel

    func propose(_ tokens: [TranscriptToken], context: EditContext) async -> [TranscriptEdit] {
        let text = tokens.reduce(into: "") { $0 += $1.effectiveText }
        guard text.contains(where: \.isLetter) else { return [] }

        var systemPrompt = config.systemPrompt
        if context.pass == .live {
            // Same wording `AppState` uses for mid-stream chunks. A fragment has no decidable
            // sentence start or end, and a model that punctuates one anyway produces an edit
            // the next chunk has to undo — which the graph forbids, so it would simply be wrong.
            systemPrompt += "\n\nThis is a speech fragment from a continuous dictation stream — "
                + "it may begin or end mid-sentence. Do NOT capitalize the first word unless the "
                + "source already capitalizes it or it is a proper noun/acronym. Do NOT add "
                + "terminal punctuation (.!?) at the end unless the source already contains it."
        }

        let revised: String
        do {
            revised = try await processor.process(
                text: text,
                systemPrompt: systemPrompt,
                userMessage: "[INPUT]\n\(text)\n[/INPUT]",
                temperature: config.temperature,
                topP: config.topP,
                topK: config.topK,
                repetitionPenalty: config.repetitionPenalty,
                maxTokensCap: config.maxTokensCap,
                throwOnFallback: true)
        } catch {
            Logger.warning("LLM editing model produced nothing: \(error.localizedDescription)",
                           subsystem: .transcription)
            return []
        }

        let cleaned = Self.stripStructuralTags(revised)
        guard !cleaned.isEmpty, cleaned != text else { return [] }

        let edits = TranscriptDiff.edits(from: tokens,
                                         to: cleaned,
                                         source: .llm,
                                         confidence: confidence)
        Logger.debug("LLM editing model: \(edits.count) candidate edits at "
                     + "confidence \(confidence) (floor \(ConfidenceGate.floor(for: .llm)))",
                     subsystem: .transcription)
        return edits
    }

    // MARK: - Output hygiene

    /// Remove envelope tags the model occasionally echoes.
    ///
    /// Short chunks are out of distribution for the fine-tuned model and it sometimes emits
    /// `[/INPUT]`, including truncated. Left in place these become inserted-token edits, so
    /// they are stripped before the diff rather than judged by the gate — the gate's job is
    /// deciding about the user's words, not about the harness's delimiters.
    static func stripStructuralTags(_ text: String) -> String {
        var out = text
        for tag in ["[CONTEXT=previous]", "[/CONTEXT]", "[INPUT]", "[/INPUT]", "[/INPUT"] {
            out = out.replacingOccurrences(of: tag, with: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

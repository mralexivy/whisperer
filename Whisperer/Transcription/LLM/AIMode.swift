//
//  AIMode.swift
//  Whisperer
//
//  Unified AI mode with single prompt and function-based assignment
//

import Foundation

struct AIMode: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var color: String
    var prompt: String              // Single prompt with {transcript} placeholder
    var temperature: Float
    var topP: Float
    var topK: Int
    var repetitionPenalty: Float
    var maxTokensCap: Int
    var isBuiltIn: Bool
    var targetLanguage: String?     // For Translate mode
    var sortOrder: Int

    // MARK: - Codable Migration

    enum CodingKeys: String, CodingKey {
        case id, name, icon, color, prompt, temperature, topP, topK
        case repetitionPenalty, maxTokensCap, isBuiltIn, targetLanguage, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        color = try container.decode(String.self, forKey: .color)
        prompt = try container.decode(String.self, forKey: .prompt)
        temperature = try container.decode(Float.self, forKey: .temperature)
        topP = try container.decode(Float.self, forKey: .topP)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? 0
        repetitionPenalty = try container.decodeIfPresent(Float.self, forKey: .repetitionPenalty) ?? 1.05
        maxTokensCap = try container.decodeIfPresent(Int.self, forKey: .maxTokensCap) ?? 256
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
    }

    init(
        id: UUID,
        name: String,
        icon: String,
        color: String,
        prompt: String,
        temperature: Float,
        topP: Float,
        topK: Int = 0,
        repetitionPenalty: Float = 1.05,
        maxTokensCap: Int = 256,
        isBuiltIn: Bool,
        targetLanguage: String? = nil,
        sortOrder: Int
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.prompt = prompt
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.maxTokensCap = maxTokensCap
        self.isBuiltIn = isBuiltIn
        self.targetLanguage = targetLanguage
        self.sortOrder = sortOrder
    }

    // MARK: - Built-in Mode IDs (stable, never change)

    static let correctModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
    static let rewriteModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let translateModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    static let formatModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
    static let summarizeModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!
    static let grammarModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!
    static let listFormatModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!
    static let codingModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!
    static let emailModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000008")!
    static let creativeModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000009")!
    static let customModeId = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!

    // MARK: - Built-in Modes

    static let builtInModes: [AIMode] = [
        AIMode(
            id: correctModeId,
            name: "Correct",
            icon: "checkmark.circle",
            color: "10B981",
            prompt: """
            You are a live transcription cleanup engine.

            Rules: preserve meaning exactly. Keep the same language. Do not translate. Fix punctuation, capitalization, spacing, and obvious transcription mistakes. Remove only empty filler words and accidental repetitions. Keep wording as close as possible to the original. Preserve names, numbers, dates, URLs, code terms, and technical terms exactly. Preserve inline foreign technical terms exactly. Output only the cleaned text.

            [MODE=cleanup]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            repetitionPenalty: 1.05,
            maxTokensCap: 256,
            isBuiltIn: true,
            sortOrder: 0
        ),
        AIMode(
            id: rewriteModeId,
            name: "Rewrite",
            icon: "pencil.and.outline",
            color: "5B6CF7",
            prompt: """
            You are a live transcription cleanup engine.

            Rules: preserve meaning exactly. Keep the same language. Do not translate. Rewrite into clear professional written language. Keep all facts, names, numbers, and technical terms unchanged. Do not add information. Output only the final text.

            [MODE=formalize]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.25,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 1
        ),
        AIMode(
            id: translateModeId,
            name: "Translate",
            icon: "globe",
            color: "3B82F6",
            prompt: """
            You are a professional translator.

            Rules: translate accurately. Preserve meaning, tone, style, and register. Preserve names, numbers, and technical terms. Output only the translated text.

            [MODE=translate]
            [LANG=English]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.1,
            topP: 1.0,
            topK: 0,
            repetitionPenalty: 1.05,
            maxTokensCap: 512,
            isBuiltIn: true,
            targetLanguage: "English",
            sortOrder: 2
        ),
        AIMode(
            id: formatModeId,
            name: "Format",
            icon: "text.alignleft",
            color: "22C55E",
            prompt: """
            You are a formatting assistant.

            Rules: format text using Markdown with headers, bullet points, and structure. Identify logical sections. Preserve all content. Output only the formatted text.

            [MODE=format]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 3
        ),
        AIMode(
            id: summarizeModeId,
            name: "Summarize",
            icon: "text.redaction",
            color: "F59E0B",
            prompt: """
            You are a summarization expert.

            Rules: capture main ideas and essential details. Use bullet points for multiple points. Keep it brief but complete. Output only the summary.

            [MODE=summarize]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.3,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 384,
            isBuiltIn: true,
            sortOrder: 4
        ),
        AIMode(
            id: grammarModeId,
            name: "Grammar",
            icon: "textformat.abc",
            color: "EC4899",
            prompt: """
            You are a live transcription cleanup engine.

            Rules: preserve meaning exactly. Keep the same language. Do not translate. Fix grammar, punctuation, and spelling only. Do not rephrase or restructure. Keep wording identical where possible. Output only the corrected text.

            [MODE=grammar]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            repetitionPenalty: 1.05,
            maxTokensCap: 256,
            isBuiltIn: true,
            sortOrder: 5
        ),
        AIMode(
            id: listFormatModeId,
            name: "List Format",
            icon: "list.bullet",
            color: "06B6D4",
            prompt: """
            You are a list formatting assistant.

            Rules: detect if text contains a list and format accordingly. Convert spoken markers to Markdown lists. Handle self-corrections. Preserve text before the list as prefix. If NO list detected, return text UNCHANGED. Output only the formatted text.

            [MODE=list]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.1,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.08,
            maxTokensCap: 256,
            isBuiltIn: true,
            sortOrder: 6
        ),
        AIMode(
            id: codingModeId,
            name: "Coding",
            icon: "chevron.left.forwardslash.chevron.right",
            color: "8B5CF6",
            prompt: """
            You are a coding assistant.

            Rules: rewrite into clean technical documentation or code comments. Use precise technical language. Preserve technical terms, function names, and code references. Be concise. Output only the technical text.

            [MODE=coding]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 7
        ),
        AIMode(
            id: emailModeId,
            name: "Email",
            icon: "envelope.fill",
            color: "F97316",
            prompt: """
            You are an email editor.

            Rules: rewrite as a professional email. Add appropriate greeting and sign-off. Match tone to content. Keep the message clear and concise. Output only the email text.

            [MODE=email]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.3,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 8
        ),
        AIMode(
            id: creativeModeId,
            name: "Creative",
            icon: "paintbrush.fill",
            color: "EF4444",
            prompt: """
            You are a creative writing assistant.

            Rules: enhance with vivid, engaging language. Improve flow. Preserve original meaning and key ideas. Add creative flair while staying true to intent. Output only the creative text.

            [MODE=creative]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.5,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 9
        ),
        AIMode(
            id: customModeId,
            name: "Custom",
            icon: "sparkle",
            color: "A855F7",
            prompt: """
            Process this text:

            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.3,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 10
        ),
    ]

    static func defaultMode() -> AIMode {
        builtInModes[0]
    }

    /// Returns the default built-in values for a built-in mode (for "Reset to Default")
    static func builtInDefault(for id: UUID) -> AIMode? {
        builtInModes.first { $0.id == id }
    }
}

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
    var isBuiltIn: Bool
    var targetLanguage: String?     // For Translate mode
    var sortOrder: Int

    // MARK: - Built-in Modes

    static let builtInModes: [AIMode] = [
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!,
            name: "Correct",
            icon: "checkmark.circle",
            color: "10B981",
            prompt: """
            You are a live transcription cleanup engine.

            Your job is to lightly improve speech-to-text output while preserving exactly what the speaker meant.

            Rules:
            - Keep the original meaning, intent, tone, and factual content.
            - Keep the wording as close as possible to the original.
            - Fix punctuation, capitalization, spacing, and obvious transcription errors.
            - Remove only clearly unnecessary filler or accidental repetitions, such as repeated words or empty hesitations.
            - Rephrase only when the sentence is unclear or grammatically broken.
            - Preserve names, numbers, dates, URLs, code terms, product names, and technical terms exactly when possible.
            - Do not add new facts.
            - Do not remove important details.
            - Do not make the text more formal than necessary.
            - Do not explain changes.
            - Output only the cleaned text.

            Clean up this live transcription with light edits only.
            Keep the wording close to what was said.

            Text:
            {transcript}
            """,
            temperature: 0.1,
            topP: 0.8,
            isBuiltIn: true,
            sortOrder: 0
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            name: "Rewrite",
            icon: "pencil.and.outline",
            color: "5B6CF7",
            prompt: """
            You are a professional editor. Rewrite transcribed speech into clear, professional written text.

            Rules:
            - Fix grammar, punctuation, and sentence structure.
            - Remove filler words (um, uh, like, you know, so).
            - Fix words that are clearly wrong based on surrounding context.
            - Output only the rewritten text.

            Rewrite this:
            {transcript}
            """,
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 1
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!,
            name: "Translate",
            icon: "globe",
            color: "3B82F6",
            prompt: """
            You are a professional translator. Translate accurately while preserving meaning and tone.

            Rules:
            - Maintain the original style and register.
            - Output only the translated text.

            Translate this:
            {transcript}
            """,
            temperature: 0.1,
            topP: 1.0,
            isBuiltIn: true,
            targetLanguage: "English",
            sortOrder: 2
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!,
            name: "Format",
            icon: "text.alignleft",
            color: "22C55E",
            prompt: """
            You are a formatting assistant. Format text using Markdown with appropriate headers, bullet points, and structure.

            Rules:
            - Identify logical sections and add headers.
            - Use bullet points for lists.
            - Preserve all content.
            - Output only the formatted text.

            Format this:
            {transcript}
            """,
            temperature: 0.2,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 3
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!,
            name: "Summarize",
            icon: "text.redaction",
            color: "F59E0B",
            prompt: """
            You are a summarization expert. Summarize into concise key points.

            Rules:
            - Capture the main ideas and essential details.
            - Use bullet points for multiple points.
            - Keep it brief but complete.
            - Output only the summary.

            Summarize this:
            {transcript}
            """,
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 4
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!,
            name: "Grammar",
            icon: "textformat.abc",
            color: "EC4899",
            prompt: """
            You are a grammar checker. Fix grammar, punctuation, and spelling errors.

            Rules:
            - Fix words that are clearly wrong based on context.
            - Do not change meaning, tone, or style.
            - Do not rephrase or restructure.
            - Output only the corrected text.

            Fix this:
            {transcript}
            """,
            temperature: 0.1,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 5
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!,
            name: "List Format",
            icon: "list.bullet",
            color: "06B6D4",
            prompt: """
            You are a list formatting assistant. Detect if text contains a list and format accordingly.

            Rules:
            - Convert spoken markers: "bullet point X" -> "- X", "number one X" -> "1. X"
            - Handle self-corrections: "bullet point milk no wait eggs" -> "- Eggs"
            - Preserve text before the list as a prefix paragraph.
            - If NO list detected, return text UNCHANGED.
            - Output only the formatted text.

            Format any lists:
            {transcript}
            """,
            temperature: 0.1,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 6
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!,
            name: "Coding",
            icon: "chevron.left.forwardslash.chevron.right",
            color: "8B5CF6",
            prompt: """
            You are a coding assistant. Rewrite into clean, technical documentation or code comments.

            Rules:
            - Use precise technical language.
            - Preserve technical terms, function names, and code references.
            - Be concise and clear.
            - Output only the technical text.

            Rewrite as technical documentation:
            {transcript}
            """,
            temperature: 0.2,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 7
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000008")!,
            name: "Email",
            icon: "envelope.fill",
            color: "F97316",
            prompt: """
            You are an email editor. Rewrite as a professional email.

            Rules:
            - Add appropriate greeting and sign-off.
            - Match tone to the content (formal/casual as appropriate).
            - Keep the message clear and concise.
            - Output only the email text.

            Rewrite as email:
            {transcript}
            """,
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 8
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000009")!,
            name: "Creative",
            icon: "paintbrush.fill",
            color: "EF4444",
            prompt: """
            You are a creative writing assistant. Rewrite with vivid, engaging language.

            Rules:
            - Enhance descriptions and improve flow.
            - Preserve the original meaning and key ideas.
            - Add creative flair while staying true to intent.
            - Output only the creative text.

            Rewrite creatively:
            {transcript}
            """,
            temperature: 0.5,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 9
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!,
            name: "Custom",
            icon: "sparkle",
            color: "A855F7",
            prompt: "Process this text:\n{transcript}",
            temperature: 0.3,
            topP: 0.9,
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

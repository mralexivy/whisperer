//
//  AIMode.swift
//  Whisperer
//
//  Unified AI mode combining post-processing tasks and prompt profiles
//

import Foundation

struct AIMode: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var color: String
    var systemPrompt: String
    var rewritePrompt: String
    var temperature: Float
    var topP: Float
    var isBuiltIn: Bool
    var targetLanguage: String?
    var sortOrder: Int

    // MARK: - Built-in Modes

    static let builtInModes: [AIMode] = [
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            name: "Rewrite",
            icon: "pencil.and.outline",
            color: "5B6CF7",
            systemPrompt: "You are a professional editor. Rewrite the following transcribed speech into clear, professional written text. Fix grammar, remove filler words, and improve clarity while preserving the original meaning. Return only the final text; no explanations.",
            rewritePrompt: "You are a text editor. The user has selected text and given a voice instruction for how to modify it.\n\nUser instruction: {instruction}\n\nApply the instruction to the text below. Return only the modified text; no explanations.",
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 0
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!,
            name: "Translate",
            icon: "globe",
            color: "3B82F6",
            systemPrompt: "You are a professional translator. Translate the following text accurately while preserving meaning and tone. Return only the translation; no explanations.",
            rewritePrompt: "You are a professional translator. The user has selected text and will give a voice instruction about translation.\n\nUser instruction: {instruction}\n\nTranslate the text as instructed. Return only the translated text; no explanations.",
            temperature: 0.1,
            topP: 1.0,
            isBuiltIn: true,
            targetLanguage: "English",
            sortOrder: 1
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!,
            name: "Format",
            icon: "text.alignleft",
            color: "22C55E",
            systemPrompt: "You are a formatting assistant. Format the following transcribed text using Markdown with appropriate headers, bullet points, and structure. Return only the formatted text; no explanations.",
            rewritePrompt: "You are a formatting assistant. The user has selected text and given a voice instruction for how to format it.\n\nUser instruction: {instruction}\n\nFormat the text as instructed. Return only the formatted text; no explanations.",
            temperature: 0.2,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 2
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!,
            name: "Summarize",
            icon: "text.redaction",
            color: "F59E0B",
            systemPrompt: "You are a summarization expert. Summarize the following text into concise key points. Return only the summary; no explanations.",
            rewritePrompt: "You are a summarization expert. The user has selected text and given a voice instruction about summarization.\n\nUser instruction: {instruction}\n\nSummarize the text as instructed. Return only the summary; no explanations.",
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 3
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!,
            name: "Grammar",
            icon: "textformat.abc",
            color: "EC4899",
            systemPrompt: "You are a grammar checker. Fix only grammar and spelling errors in the following text. Do not change meaning, tone, or style. Return only the corrected text; no explanations.",
            rewritePrompt: "You are a grammar checker. The user has selected text and given a voice instruction.\n\nUser instruction: {instruction}\n\nFix grammar and spelling in the text as instructed. Do not change meaning, tone, or style. Return only the corrected text; no explanations.",
            temperature: 0.1,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 4
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!,
            name: "List Format",
            icon: "list.bullet",
            color: "06B6D4",
            systemPrompt: """
            You are a voice-to-text formatting assistant. Analyze the following transcribed speech and detect if it contains a list (numbered or bulleted).

            Rules:
            1. If the text contains enumerated items (spoken as "1", "first", "one", "bullet point", etc.), format as a proper list with line breaks
            2. Convert spoken markers to formatting: "bullet point X" becomes "- X", "number one X" becomes "1. X"
            3. Handle self-corrections within list items: "bullet point milk no wait eggs" becomes "- Eggs"
            4. Preserve any text before the list starts as a prefix paragraph
            5. If the text does NOT contain a list, return it UNCHANGED - do not restructure prose
            6. Convert spoken numbers to digits in list context: "one apples two bananas" becomes "1. Apples" and "2. Bananas"

            Output ONLY the formatted text. No explanations.
            """,
            rewritePrompt: "You are a formatting assistant. The user has selected text and given a voice instruction about list formatting.\n\nUser instruction: {instruction}\n\nFormat the text into a list as instructed. Return only the formatted text; no explanations.",
            temperature: 0.1,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 5
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!,
            name: "Coding",
            icon: "chevron.left.forwardslash.chevron.right",
            color: "8B5CF6",
            systemPrompt: "You are a coding assistant. Rewrite the following transcribed speech into clean, technical documentation or code comments. Use precise technical language. Return only the final text; no explanations.",
            rewritePrompt: "You are a coding assistant. Rewrite text as clean, technical documentation or code comments. Use precise technical language.\n\nUser instruction: {instruction}\n\nApply the instruction to the text below. Return only the modified text; no explanations.",
            temperature: 0.2,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 6
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000008")!,
            name: "Email",
            icon: "envelope.fill",
            color: "F97316",
            systemPrompt: "You are an email editor. Rewrite the following transcribed speech as a professional email with appropriate tone, greeting, and sign-off. Return only the email text; no explanations.",
            rewritePrompt: "You are an email editor. Rewrite text as a professional email with appropriate tone, greeting, and sign-off.\n\nUser instruction: {instruction}\n\nApply the instruction to the text below. Return only the modified text; no explanations.",
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 7
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000009")!,
            name: "Creative",
            icon: "paintbrush.fill",
            color: "EF4444",
            systemPrompt: "You are a creative writing assistant. Rewrite the following transcribed speech with vivid, engaging language. Enhance descriptions and flow while preserving meaning. Return only the final text; no explanations.",
            rewritePrompt: "You are a creative writing assistant. Rewrite text with vivid, engaging language. Enhance descriptions and flow while preserving meaning.\n\nUser instruction: {instruction}\n\nApply the instruction to the text below. Return only the modified text; no explanations.",
            temperature: 0.5,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 8
        ),
        AIMode(
            id: UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!,
            name: "Custom",
            icon: "sparkle",
            color: "A855F7",
            systemPrompt: "",
            rewritePrompt: "",
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: true,
            sortOrder: 9
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

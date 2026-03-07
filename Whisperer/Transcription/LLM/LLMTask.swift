//
//  LLMTask.swift
//  Whisperer
//
//  LLM post-processing task presets for transcription refinement
//

import Foundation

enum LLMTask: String, CaseIterable, Identifiable {
    case rewrite = "Rewrite"
    case translate = "Translate"
    case format = "Format"
    case summarize = "Summarize"
    case grammar = "Grammar"
    case listFormat = "List Format"
    case custom = "Custom"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var description: String {
        switch self {
        case .rewrite: return "Professional tone"
        case .translate: return "To target language"
        case .format: return "Markdown, bullets"
        case .summarize: return "Condense key points"
        case .grammar: return "Fix grammar only"
        case .listFormat: return "Detect and format lists"
        case .custom: return "Your own prompt"
        }
    }

    var systemPrompt: String {
        switch self {
        case .rewrite:
            return "You are a professional editor. Rewrite the following transcribed speech into clear, professional written text. Fix grammar, remove filler words, and improve clarity while preserving the original meaning. Return only the final text; no explanations."
        case .translate:
            return "You are a professional translator. Translate the following text accurately while preserving meaning and tone. Return only the translation; no explanations."
        case .format:
            return "You are a formatting assistant. Format the following transcribed text using Markdown with appropriate headers, bullet points, and structure. Return only the formatted text; no explanations."
        case .summarize:
            return "You are a summarization expert. Summarize the following text into concise key points. Return only the summary; no explanations."
        case .grammar:
            return "You are a grammar checker. Fix only grammar and spelling errors in the following text. Do not change meaning, tone, or style. Return only the corrected text; no explanations."
        case .listFormat:
            return """
            You are a voice-to-text formatting assistant. Analyze the following transcribed speech and detect if it contains a list (numbered or bulleted).

            Rules:
            1. If the text contains enumerated items (spoken as "1", "first", "one", "bullet point", etc.), format as a proper list with line breaks
            2. Convert spoken markers to formatting: "bullet point X" becomes "- X", "number one X" becomes "1. X"
            3. Handle self-corrections within list items: "bullet point milk no wait eggs" becomes "- Eggs"
            4. Preserve any text before the list starts as a prefix paragraph
            5. If the text does NOT contain a list, return it UNCHANGED - do not restructure prose
            6. Convert spoken numbers to digits in list context: "one apples two bananas" becomes "1. Apples" and "2. Bananas"

            Output ONLY the formatted text. No explanations.
            """
        case .custom:
            return ""
        }
    }

    var temperature: Float {
        switch self {
        case .rewrite: return 0.3
        case .translate: return 0.1
        case .format: return 0.2
        case .summarize: return 0.3
        case .grammar: return 0.1
        case .listFormat: return 0.1
        case .custom: return 0.3
        }
    }

    var topP: Float {
        switch self {
        case .translate: return 1.0
        default: return 0.9
        }
    }
}

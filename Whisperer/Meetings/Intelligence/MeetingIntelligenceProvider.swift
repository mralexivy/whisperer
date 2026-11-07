//
//  MeetingIntelligenceProvider.swift
//  Whisperer
//
//  The seam between meeting intelligence (notes + Ask AI) and whatever model runs it.
//
//  Local MLX stays the default and lives in `MeetingAIService` unchanged. A connected
//  provider — a CLI the user is signed in to (Claude Code, Codex, Antigravity), a ChatGPT
//  plan via OAuth, or an API key — implements this protocol. The interface is task-level
//  (notes, ask), not chat-level: the CLIs are agents, not completion endpoints, and these
//  two operations are everything meetings need.
//
//  See docs/exec-plans/connected-ai-providers.md.
//

import Foundation

// MARK: - Provider identity

nonisolated enum AIProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode
    case codex
    case antigravity
    case chatGPT
    case openAIKey
    case anthropicKey
    case geminiKey

    var id: String { rawValue }

    enum Kind: Sendable { case cli, oauth, apiKey }

    var kind: Kind {
        switch self {
        case .claudeCode, .codex, .antigravity: return .cli
        case .chatGPT:                           return .oauth
        case .openAIKey, .anthropicKey, .geminiKey: return .apiKey
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode:   return "Claude Code"
        case .codex:        return "Codex"
        case .antigravity:  return "Antigravity"
        case .chatGPT:      return "ChatGPT"
        case .openAIKey:    return "OpenAI API"
        case .anthropicKey: return "Anthropic API"
        case .geminiKey:    return "Gemini API"
        }
    }

    /// Who the user's account is with — shown under the name on the card.
    var vendorLine: String {
        switch self {
        case .claudeCode:   return "Uses your Claude Pro or Max plan"
        case .codex:        return "Uses your ChatGPT plan through Codex"
        case .antigravity:  return "Uses your Google AI Pro or Ultra plan"
        case .chatGPT:      return "Uses your ChatGPT Plus or Pro plan"
        case .openAIKey:    return "Billed to your OpenAI API key"
        case .anthropicKey: return "Billed to your Anthropic API key"
        case .geminiKey:    return "Billed to your Google AI Studio key"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode:   return "terminal.fill"
        case .codex:        return "chevron.left.forwardslash.chevron.right"
        case .antigravity:  return "sparkles"
        case .chatGPT:      return "bubble.left.and.bubble.right.fill"
        case .openAIKey:    return "key.fill"
        case .anthropicKey: return "key.horizontal.fill"
        case .geminiKey:    return "diamond.fill"
        }
    }

    /// Short name of the company that receives the transcript, for consent copy.
    var recipient: String {
        switch self {
        case .claudeCode, .anthropicKey: return "Anthropic"
        case .codex, .chatGPT, .openAIKey: return "OpenAI"
        case .antigravity, .geminiKey:   return "Google"
        }
    }

    var privacyPolicyURL: URL? {
        switch recipient {
        case "Anthropic": return URL(string: "https://www.anthropic.com/legal/privacy")
        case "OpenAI":    return URL(string: "https://openai.com/policies/privacy-policy")
        default:          return URL(string: "https://policies.google.com/privacy")
        }
    }

    /// CLI adapters need to launch a user-installed binary that reads its own credentials
    /// from the home directory. The App Store sandbox forbids both.
    var isAvailableInThisBuild: Bool {
        #if APP_STORE
        return kind != .cli
        #else
        return true
        #endif
    }

    /// Adapters whose vendor flow is still in preview, shown with a badge.
    var isPreview: Bool { self == .antigravity || self == .chatGPT }
}

// MARK: - Readiness

nonisolated enum ProviderReadiness: Equatable, Sendable {
    case ready(detail: String?)
    case notInstalled
    case notSignedIn(hint: String)
    case needsKey
    case quotaExhausted(until: Date?)
    case unavailable(String)

    var isReady: Bool { if case .ready = self { return true } else { return false } }

    var statusText: String {
        switch self {
        case .ready(let detail):          return detail.map { "Ready · \($0)" } ?? "Ready"
        case .notInstalled:               return "Not installed"
        case .notSignedIn:                return "Not signed in"
        case .needsKey:                   return "No API key"
        case .quotaExhausted(let until):
            if let until {
                return "Limit reached until \(until.formatted(date: .omitted, time: .shortened))"
            }
            return "Usage limit reached"
        case .unavailable(let why):       return why
        }
    }
}

// MARK: - Errors

nonisolated enum MeetingAIProviderError: Error, Equatable, Sendable, LocalizedError {
    case notInstalled
    case notSignedIn
    case consentRequired
    case quotaExhausted(retryAfter: TimeInterval?)
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized
    case timeout
    case offline
    case contextTooLong
    case schemaMismatch(raw: String)
    case processFailed(exitCode: Int32, stderrTail: String)
    case server(status: Int, body: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled:                  return "The app isn't installed."
        case .notSignedIn:                   return "You're not signed in."
        case .consentRequired:               return "Sending this meeting needs your permission first."
        case .quotaExhausted:                return "Your plan's usage limit is reached."
        case .rateLimited:                   return "Too many requests — try again in a moment."
        case .unauthorized:                  return "Sign-in expired or the key was rejected."
        case .timeout:                       return "The request took too long."
        case .offline:                       return "No internet connection."
        case .contextTooLong:                return "This meeting is too long for the selected AI."
        case .schemaMismatch:                return "The AI replied in an unexpected format."
        case .processFailed(let code, _):    return "The command-line tool failed (exit \(code))."
        case .server(let status, _):         return "The AI service returned an error (\(status))."
        case .cancelled:                     return "Cancelled."
        }
    }

    /// Classifies free-form failure text (CLI stderr, API error bodies) into the errors the
    /// router reacts to differently. Order matters: a quota message often also says "login".
    static func classify(_ text: String, exitCode: Int32) -> MeetingAIProviderError {
        let lower = text.lowercased()
        let quotaMarkers = ["usage limit", "rate limit", "quota", "limit reached", "hit your limit", "too many requests", "credit balance"]
        if quotaMarkers.contains(where: lower.contains) {
            return .quotaExhausted(retryAfter: nil)
        }
        let authMarkers = ["not logged in", "please log in", "login required", "/login", "unauthorized", "authenticate", "invalid api key", "not signed in", "sign in"]
        if authMarkers.contains(where: lower.contains) {
            return .notSignedIn
        }
        if lower.contains("context") && (lower.contains("too long") || lower.contains("exceed")) {
            return .contextTooLong
        }
        let tail = String(text.suffix(400))
        return .processFailed(exitCode: exitCode, stderrTail: tail)
    }
}

// MARK: - Inputs and outputs

nonisolated struct MeetingNotesInput: Sendable {
    /// `[123s] Speaker: text` lines.
    var transcript: String
    /// Display name of the meeting's language, or nil when unknown ("write in the transcript's language").
    var languageName: String?
    var wordCount: Int
    /// A short recording gets a two-field note instead of the full structure.
    var isShortNote: Bool
}

nonisolated struct MeetingAskInput: Sendable {
    var question: String
    var transcript: String
}

nonisolated struct MeetingNotes: Sendable, Equatable {
    var title: String?
    var summary: MeetingAISummary
}

// MARK: - Protocol

nonisolated protocol MeetingIntelligenceProvider: Sendable {
    var id: AIProviderID { get }
    /// The model the provider will use, for provenance. Nil when the CLI chooses.
    var modelLabel: String? { get }
    /// Characters of transcript the provider takes in one request.
    var maxTranscriptChars: Int { get }

    func readiness() async -> ProviderReadiness
    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes
    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String
    /// One generic request: `instructions` as the system prompt, `input` as the user turn,
    /// optionally constrained to `jsonSchema`. Used by transcript polish.
    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String
}

/// Lets exactly one caller through, from any thread.
nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

nonisolated extension MeetingIntelligenceProvider {
    var modelLabel: String? { nil }
    /// ~200k tokens is the floor across the supported cloud models; leave room for the
    /// instructions and the answer.
    var maxTranscriptChars: Int { 400_000 }
}

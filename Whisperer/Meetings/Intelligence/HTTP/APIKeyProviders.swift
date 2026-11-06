//
//  APIKeyProviders.swift
//  Whisperer
//
//  Meeting notes and Ask AI over the vendors' public APIs: OpenAI Responses (also used by
//  the ChatGPT plan route), Anthropic Messages and Gemini generateContent. All stream SSE,
//  so the title lands as soon as its JSON string closes.
//

import Foundation

// MARK: - Shared request content

nonisolated enum MeetingRequestContent {
    static func notes(_ input: MeetingNotesInput) -> (instructions: String, user: String) {
        (MeetingCloudPrompts.notesInstructions(languageName: input.languageName, isShortNote: input.isShortNote),
         MeetingCloudPrompts.notesUserMessage(transcript: input.transcript))
    }

    /// For APIs without schema enforcement, the schema travels in the instructions.
    static func notesWithInlineSchema(_ input: MeetingNotesInput) -> (instructions: String, user: String) {
        let base = notes(input)
        return (base.instructions + "\n\nJSON schema the reply must match:\n" + MeetingNotesSchema.full, base.user)
    }

    static func ask(_ input: MeetingAskInput) -> (instructions: String, user: String) {
        (MeetingCloudPrompts.askInstructions,
         MeetingCloudPrompts.askUserMessage(question: input.question, transcript: input.transcript))
    }
}

/// Accumulates streamed text and fires the title callback once.
nonisolated final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private let once = OnceFlag()
    let onTitle: (@Sendable (String) -> Void)?
    let onPartial: (@Sendable (String) -> Void)?

    init(onTitle: (@Sendable (String) -> Void)? = nil, onPartial: (@Sendable (String) -> Void)? = nil) {
        self.onTitle = onTitle
        self.onPartial = onPartial
    }

    func append(_ piece: String) {
        guard !piece.isEmpty else { return }
        lock.lock(); text += piece; let snapshot = text; lock.unlock()
        onPartial?(snapshot)
        if let onTitle, let title = MeetingNotesSchema.streamedTitle(in: snapshot), once.take() {
            onTitle(title)
        }
    }

    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

// MARK: - OpenAI Responses

nonisolated struct OpenAIResponsesProvider: MeetingIntelligenceProvider {
    let id: AIProviderID
    var model: String
    /// Supplies a bearer token per request: an API key, or a freshly refreshed OAuth token.
    let token: @Sendable () async throws -> String
    /// The ChatGPT plan route rejects several standard fields; see `body(...)`.
    let isPlanRoute: Bool
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!

    var modelLabel: String? { model }
    var keyPresent: @Sendable () async -> Bool = { true }
    /// `reasoning.effort` for reasoning models ("low", "minimal"…); nil sends nothing.
    var reasoningEffort: String?

    func readiness() async -> ProviderReadiness {
        await keyPresent() ? .ready(detail: model) : (isPlanRoute ? .notSignedIn(hint: "Continue with ChatGPT") : .needsKey)
    }

    /// Request body. Only fields the plan route accepts are ever sent: no temperature,
    /// top_p, max_output_tokens, truncation, metadata, user or previous_response_id, on
    /// either route — the API-key route gains nothing from them here. System text goes in
    /// `instructions` (a `role: "system"` item is rejected on the plan route), the full
    /// context goes in `input` every call, and `store` is always false.
    func body(instructions: String, user: String, schema: String?) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [[
                "role": "user",
                "content": [["type": "input_text", "text": user]],
            ]],
            "stream": true,
            "store": false,
        ]
        if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort] }
        if let schema, let data = schema.data(using: .utf8),
           let schemaObject = try? JSONSerialization.jsonObject(with: data) {
            body["text"] = ["format": [
                "type": "json_schema", "name": "meeting_notes", "strict": true, "schema": schemaObject,
            ]]
        }
        return body
    }

    static let unsupportedPlanFields: Set<String> = [
        "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation",
        "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature",
        "top_logprobs", "top_p", "truncation", "user", "previous_response_id",
    ]

    func request(body: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.httpBody = ProviderHTTPClient.jsonBody(body)
        return request
    }

    func stream(instructions: String, user: String, schema: String?, into acc: StreamAccumulator) async throws {
        // The plan route answers `text.format` with "not supported" (seen live, 2026-11-06), so
        // asking for it there only costs a round trip. Put the schema in the instructions.
        if isPlanRoute, let schema {
            try await run(body(instructions: instructions + "\n\nJSON schema the reply must match:\n" + schema,
                               user: user, schema: nil), acc: acc)
            return
        }
        do {
            try await run(body(instructions: instructions, user: user, schema: schema), acc: acc)
        } catch MeetingAIProviderError.server(let status, let message) where status == 400 && schema != nil {
            // A route or model without structured outputs: ask for JSON in the instructions instead.
            Logger.info("Connected AI: \(id.rawValue) rejected json_schema (\(message.prefix(120))) — retrying with inline schema", subsystem: .transcription)
            try await run(body(instructions: instructions + "\n\nJSON schema the reply must match:\n" + (schema ?? ""),
                               user: user, schema: nil), acc: acc)
        }
    }

    private func run(_ body: [String: Any], acc: StreamAccumulator) async throws {
        let request = try await request(body: body)
        try await ProviderHTTPClient.streamEvents(request) { event in
            guard let data = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let type = (json["type"] as? String) ?? event.event ?? ""
            switch type {
            case "response.output_text.delta":
                acc.append((json["delta"] as? String) ?? "")
            case "response.failed", "error", "response.error":
                let error = (json["error"] as? [String: Any]) ?? ((json["response"] as? [String: Any])?["error"] as? [String: Any])
                let message = (error?["message"] as? String) ?? event.data
                switch MeetingAIProviderError.classify(message, exitCode: 0) {
                case .quotaExhausted(let wait): throw MeetingAIProviderError.quotaExhausted(retryAfter: wait)
                case .notSignedIn:              throw MeetingAIProviderError.unauthorized
                case .contextTooLong:           throw MeetingAIProviderError.contextTooLong
                default: throw MeetingAIProviderError.server(status: 200, body: String(message.prefix(500)))
                }
            default:
                break
            }
        }
    }

    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        let content = MeetingRequestContent.notes(input)
        let acc = StreamAccumulator(onTitle: onTitle)
        try await stream(instructions: content.instructions, user: content.user,
                         schema: MeetingNotesSchema.full, into: acc)
        guard let notes = MeetingNotesSchema.decode(acc.value) else {
            throw MeetingAIProviderError.schemaMismatch(raw: String(acc.value.prefix(2_000)))
        }
        return notes
    }

    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let content = MeetingRequestContent.ask(input)
        let acc = StreamAccumulator(onPartial: onPartial)
        try await stream(instructions: content.instructions, user: content.user, schema: nil, into: acc)
        let answer = acc.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw MeetingAIProviderError.schemaMismatch(raw: "") }
        return answer
    }

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        let acc = StreamAccumulator()
        try await stream(instructions: instructions, user: input, schema: jsonSchema, into: acc)
        return acc.value
    }

    /// The newest model in a plan's list: highest `gpt-<major>.<minor>`, server order breaking
    /// ties. Plan accounts list several generations; the oldest is never the right default.
    static func newestModel(_ ids: [String]) -> String? {
        func version(_ id: String) -> (Int, Int) {
            guard let range = id.range(of: #"gpt-(\d+)(?:\.(\d+))?"#, options: .regularExpression) else { return (-1, -1) }
            let parts = id[range].dropFirst(4).split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
            return (parts.first ?? -1, parts.count > 1 ? parts[1] : 0)
        }
        var best: (id: String, v: (Int, Int))?
        for id in ids {
            let v = version(id)
            if best == nil || v > best!.v { best = (id, v) }
        }
        return best?.id
    }

    /// Model ids the token can use. The plan route marks selectable ones `visibility: list`
    /// and names them by `slug`; the API-key route returns `id`s.
    static func listModels(token: String,
                           url: URL = URL(string: "https://api.openai.com/v1/models")!) async throws -> [String] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let json = try await ProviderHTTPClient.json(request)
        let items = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        let ids: [String] = items.compactMap { item in
            if let visibility = item["visibility"] as? String, visibility != "list" { return nil }
            return (item["slug"] as? String) ?? (item["id"] as? String)
        }
        // Server order, not alphabetical: the plan route lists the account's models with the
        // current default first, and "first" is what a fresh sign-in picks.
        return ids
    }
}

// MARK: - Anthropic Messages

nonisolated struct AnthropicAPIProvider: MeetingIntelligenceProvider {
    let id: AIProviderID = .anthropicKey
    var model: String
    let apiKey: @Sendable () -> String?
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    var modelLabel: String? { model }

    func readiness() async -> ProviderReadiness {
        (apiKey()?.isEmpty == false) ? .ready(detail: model) : .needsKey
    }

    func body(instructions: String, user: String, maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": [["type": "text", "text": instructions]],
            "messages": [["role": "user", "content": user]],
        ]
    }

    private func stream(instructions: String, user: String, maxTokens: Int, into acc: StreamAccumulator) async throws {
        guard let key = apiKey(), !key.isEmpty else { throw MeetingAIProviderError.unauthorized }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = ProviderHTTPClient.jsonBody(body(instructions: instructions, user: user, maxTokens: maxTokens))
        try await ProviderHTTPClient.streamEvents(request) { event in
            guard let data = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            switch json["type"] as? String {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any] { acc.append((delta["text"] as? String) ?? "") }
            case "error":
                let error = json["error"] as? [String: Any]
                let kind = (error?["type"] as? String) ?? ""
                let message = (error?["message"] as? String) ?? event.data
                if kind == "overloaded_error" || kind == "rate_limit_error" {
                    throw MeetingAIProviderError.rateLimited(retryAfter: nil)
                }
                if kind == "authentication_error" || kind == "permission_error" { throw MeetingAIProviderError.unauthorized }
                throw MeetingAIProviderError.server(status: 200, body: String(message.prefix(500)))
            default:
                break
            }
        }
    }

    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        let content = MeetingRequestContent.notesWithInlineSchema(input)
        let acc = StreamAccumulator(onTitle: onTitle)
        try await stream(instructions: content.instructions, user: content.user, maxTokens: 8_192, into: acc)
        guard let notes = MeetingNotesSchema.decode(acc.value) else {
            throw MeetingAIProviderError.schemaMismatch(raw: String(acc.value.prefix(2_000)))
        }
        return notes
    }

    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let content = MeetingRequestContent.ask(input)
        let acc = StreamAccumulator(onPartial: onPartial)
        try await stream(instructions: content.instructions, user: content.user, maxTokens: 4_096, into: acc)
        let answer = acc.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw MeetingAIProviderError.schemaMismatch(raw: "") }
        return answer
    }

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        let acc = StreamAccumulator()
        let system = jsonSchema.map { instructions + "\n\nReply with JSON matching this schema:\n" + $0 } ?? instructions
        try await stream(instructions: system, user: input, maxTokens: 16_000, into: acc)
        return acc.value
    }

    static func listModels(apiKey: String,
                           url: URL = URL(string: "https://api.anthropic.com/v1/models?limit=100")!) async throws -> [String] {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let json = try await ProviderHTTPClient.json(request)
        return ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }
}

// MARK: - Gemini

nonisolated struct GeminiAPIProvider: MeetingIntelligenceProvider {
    let id: AIProviderID = .geminiKey
    var model: String
    let apiKey: @Sendable () -> String?
    var baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    var modelLabel: String? { model }

    func readiness() async -> ProviderReadiness {
        (apiKey()?.isEmpty == false) ? .ready(detail: model) : .needsKey
    }

    func body(instructions: String, user: String, json: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
        ]
        if json { body["generationConfig"] = ["responseMimeType": "application/json"] }
        return body
    }

    private func stream(instructions: String, user: String, json: Bool, into acc: StreamAccumulator) async throws {
        guard let key = apiKey(), !key.isEmpty else { throw MeetingAIProviderError.unauthorized }
        let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"
        guard var components = URLComponents(url: baseURL.appendingPathComponent("\(modelPath):streamGenerateContent"),
                                             resolvingAgainstBaseURL: false) else {
            throw MeetingAIProviderError.server(status: 0, body: "Bad model name")
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        guard let url = components.url else { throw MeetingAIProviderError.server(status: 0, body: "Bad model name") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = ProviderHTTPClient.jsonBody(body(instructions: instructions, user: user, json: json))
        try await ProviderHTTPClient.streamEvents(request) { event in
            guard let data = event.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let error = object["error"] as? [String: Any] {
                let status = (error["code"] as? Int) ?? 500
                throw ProviderHTTPClient.error(status: status, body: (error["message"] as? String) ?? event.data, retryAfter: nil)
            }
            let candidates = (object["candidates"] as? [[String: Any]]) ?? []
            let parts = ((candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for part in parts where part["thought"] as? Bool != true {
                acc.append((part["text"] as? String) ?? "")
            }
        }
    }

    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        let content = MeetingRequestContent.notesWithInlineSchema(input)
        let acc = StreamAccumulator(onTitle: onTitle)
        try await stream(instructions: content.instructions, user: content.user, json: true, into: acc)
        guard let notes = MeetingNotesSchema.decode(acc.value) else {
            throw MeetingAIProviderError.schemaMismatch(raw: String(acc.value.prefix(2_000)))
        }
        return notes
    }

    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let content = MeetingRequestContent.ask(input)
        let acc = StreamAccumulator(onPartial: onPartial)
        try await stream(instructions: content.instructions, user: content.user, json: false, into: acc)
        let answer = acc.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw MeetingAIProviderError.schemaMismatch(raw: "") }
        return answer
    }

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        let acc = StreamAccumulator()
        let system = jsonSchema.map { instructions + "\n\nReply with JSON matching this schema:\n" + $0 } ?? instructions
        try await stream(instructions: system, user: input, json: jsonSchema != nil, into: acc)
        return acc.value
    }

    static func listModels(apiKey: String,
                           url: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!) async throws -> [String] {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let json = try await ProviderHTTPClient.json(request)
        return ((json["models"] as? [[String: Any]]) ?? []).compactMap { model in
            let methods = (model["supportedGenerationMethods"] as? [String]) ?? []
            guard methods.contains("generateContent") || methods.isEmpty,
                  let name = model["name"] as? String else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
    }
}

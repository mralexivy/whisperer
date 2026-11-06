//
//  ClaudeCodeProvider.swift
//  Whisperer
//
//  Meeting notes and Ask AI through the user's own, signed-in Claude Code (`claude -p`).
//
//  Verified on claude 2.1.308 (2026-11-06): `-p --output-format json --json-schema` returns
//  the object in `structured_output`; `--tools ""` disables every tool; `--strict-mcp-config`
//  with no `--mcp-config` loads no MCP servers (so Claude can't call back into Whisperer's
//  own server, which our installer may have added); `--no-session-persistence` keeps the
//  meeting out of Claude's resumable history. `--bare` is deliberately NOT used: it skips
//  keychain reads, which is where a subscription sign-in lives.
//

#if !APP_STORE

import Foundation

nonisolated struct ClaudeCodeProvider: MeetingIntelligenceProvider {
    let id: AIProviderID = .claudeCode
    var model: String?

    var modelLabel: String? { model }

    init(model: String? = nil) {
        let trimmed = model?.trimmingCharacters(in: .whitespaces)
        self.model = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: Readiness

    func readiness() async -> ProviderReadiness {
        guard let binary = CLIDiscovery.locate(.claudeCode) else { return .notInstalled }
        do {
            let (result, _) = try await CLIProcessRunner.run(
                executable: binary, arguments: { _ in ["auth", "status", "--json"] },
                stdin: "", timeout: 15)
            return Self.readiness(fromAuthStatus: result.stdout)
        } catch {
            return .unavailable("Couldn't run claude")
        }
    }

    static func readiness(fromAuthStatus output: String) -> ProviderReadiness {
        guard let data = MeetingNotesSchema.jsonObjectCandidates(in: output).first?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable("Unexpected response from claude auth status")
        }
        guard json["loggedIn"] as? Bool == true else {
            return .notSignedIn(hint: CLIDiscovery.signInCommand(for: .claudeCode) ?? "claude auth login")
        }
        let method = (json["authMethod"] as? String) ?? ""
        switch method {
        case "claude.ai": return .ready(detail: "Claude plan")
        case "":          return .ready(detail: nil)
        default:          return .ready(detail: "API key")
        }
    }

    // MARK: Arguments

    func arguments(systemPrompt: String, schema: String?) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--system-prompt", systemPrompt,
        ]
        if let schema { args += ["--json-schema", schema] }
        if let model { args += ["--model", model] }
        return args
    }

    // MARK: Notes

    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        guard let binary = CLIDiscovery.locate(.claudeCode) else { throw MeetingAIProviderError.notInstalled }
        let parser = ClaudeStreamParser()
        let titleOnce = OnceFlag()
        let (result, _) = try await CLIProcessRunner.run(
            executable: binary,
            arguments: { _ in
                arguments(systemPrompt: MeetingCloudPrompts.notesInstructions(
                              languageName: input.languageName, isShortNote: input.isShortNote),
                          schema: MeetingNotesSchema.fullCompact)
            },
            stdin: MeetingCloudPrompts.notesUserMessage(transcript: input.transcript),
            timeout: Self.notesTimeout(words: input.wordCount),
            onStdout: { chunk in
                parser.feed(chunk)
                if let title = MeetingNotesSchema.streamedTitle(in: parser.streamedText), titleOnce.take() {
                    onTitle(title)
                }
            })
        parser.finish()
        let outcome = try Self.outcome(parser: parser, result: result)
        if let structured = outcome.structured, let notes = MeetingNotesSchema.decode(object: structured) {
            return notes
        }
        if let notes = MeetingNotesSchema.decode(outcome.text) { return notes }
        throw MeetingAIProviderError.schemaMismatch(raw: String(outcome.text.prefix(2_000)))
    }

    // MARK: Ask

    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let binary = CLIDiscovery.locate(.claudeCode) else { throw MeetingAIProviderError.notInstalled }
        let parser = ClaudeStreamParser()
        let (result, _) = try await CLIProcessRunner.run(
            executable: binary,
            arguments: { _ in arguments(systemPrompt: MeetingCloudPrompts.askInstructions, schema: nil) },
            stdin: MeetingCloudPrompts.askUserMessage(question: input.question, transcript: input.transcript),
            timeout: 180,
            onStdout: { chunk in
                parser.feed(chunk)
                let text = parser.streamedText
                if !text.isEmpty { onPartial(text) }
            })
        parser.finish()
        let outcome = try Self.outcome(parser: parser, result: result)
        let answer = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw MeetingAIProviderError.schemaMismatch(raw: "") }
        return answer
    }

    // MARK: Generic

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        guard let binary = CLIDiscovery.locate(.claudeCode) else { throw MeetingAIProviderError.notInstalled }
        let parser = ClaudeStreamParser()
        let (result, _) = try await CLIProcessRunner.run(
            executable: binary,
            arguments: { _ in arguments(systemPrompt: instructions, schema: jsonSchema.map(Self.compact)) },
            stdin: input,
            timeout: 600,
            onStdout: { parser.feed($0) })
        parser.finish()
        let outcome = try Self.outcome(parser: parser, result: result)
        if let structured = outcome.structured, JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return outcome.text
    }

    static func compact(_ schema: String) -> String {
        guard let data = schema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: out, encoding: .utf8) else { return schema }
        return text
    }

    // MARK: Helpers

    static func notesTimeout(words: Int) -> TimeInterval {
        min(600, 90 + Double(words) / 40)
    }

    struct Outcome { var text: String; var structured: Any? }

    static func outcome(parser: ClaudeStreamParser, result: CLIResult) throws -> Outcome {
        if let final = parser.result {
            if final.isError {
                throw MeetingAIProviderError.classify(final.text, exitCode: result.exitCode)
            }
            return Outcome(text: final.text, structured: final.structured)
        }
        if result.exitCode != 0 {
            throw MeetingAIProviderError.classify(result.stderr + "\n" + result.stdout, exitCode: result.exitCode)
        }
        // Older CLIs without stream-json events: the whole stdout is the reply.
        return Outcome(text: parser.streamedText.isEmpty ? result.stdout : parser.streamedText, structured: nil)
    }
}

// MARK: - stream-json parser

/// Consumes `claude -p --output-format stream-json` line by line.
///
/// Partial text arrives as `stream_event` lines wrapping Messages API deltas: `text_delta`
/// for prose and `input_json_delta` for the structured-output tool call `--json-schema`
/// produces. Both are accumulated so the title scanner sees the JSON as it is written.
/// The last line is `{"type":"result", "result": …, "structured_output": …, "is_error": …}`.
nonisolated final class ClaudeStreamParser: @unchecked Sendable {
    struct Final { var text: String; var structured: Any?; var isError: Bool }

    private let lock = NSLock()
    private var buffer = ""
    private var streamed = ""
    private var final: Final?

    var streamedText: String { lock.lock(); defer { lock.unlock() }; return streamed }
    var result: Final? { lock.lock(); defer { lock.unlock() }; return final }

    func feed(_ chunk: String) {
        lock.lock()
        buffer += chunk
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newline]))
            buffer = String(buffer[buffer.index(after: newline)...])
        }
        lock.unlock()
        lines.forEach(handle)
    }

    func finish() {
        lock.lock()
        let rest = buffer
        buffer = ""
        lock.unlock()
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { handle(rest) }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { return }
            let piece = (delta["text"] as? String) ?? (delta["partial_json"] as? String) ?? ""
            guard !piece.isEmpty else { return }
            lock.lock(); streamed += piece; lock.unlock()
        case "result":
            let text = (json["result"] as? String) ?? ""
            let isError = (json["is_error"] as? Bool) ?? ((json["subtype"] as? String).map { $0 != "success" } ?? false)
            let structured = json["structured_output"].flatMap { $0 is NSNull ? nil : $0 }
            lock.lock(); final = Final(text: text, structured: structured, isError: isError); lock.unlock()
        default:
            break
        }
    }
}

#endif

//
//  AntigravityProvider.swift
//  Whisperer
//
//  Meeting notes and Ask AI through the user's own, signed-in Antigravity CLI (`agy -p`),
//  Google's successor to Gemini CLI for AI Pro / Ultra subscribers.
//
//  Preview: `agy` was not installed on the machine this adapter was written on, so its
//  flags come from Google's docs and secondary sources, not a verified run:
//  `-p` one-shot, `--output-format json`, `--json-schema <schema>`. One known defect is
//  handled: `agy -p` reportedly prints nothing when stdout is not a terminal, so an empty
//  successful run is retried under `script(1)`, which gives it a pseudo-terminal. The reply
//  is then located with the same balanced-brace scan used for every provider, so echoed
//  input around it is ignored.
//

#if !APP_STORE

import Foundation

nonisolated struct AntigravityProvider: MeetingIntelligenceProvider {
    let id: AIProviderID = .antigravity
    var model: String?

    var modelLabel: String? { model }

    init(model: String? = nil) {
        let trimmed = model?.trimmingCharacters(in: .whitespaces)
        self.model = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func readiness() async -> ProviderReadiness {
        guard CLIDiscovery.locate(.antigravity) != nil else { return .notInstalled }
        // No documented non-interactive status command; sign-in is checked on first use and
        // a not-signed-in failure is classified from the CLI's own message.
        return .ready(detail: "sign-in checked on first use")
    }

    func arguments(prompt: String, schema: String?) -> [String] {
        var args = ["-p", prompt, "--output-format", "json"]
        if let schema { args += ["--json-schema", schema] }
        if let model { args += ["--model", model] }
        return args
    }

    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        let prompt = MeetingCloudPrompts.notesInstructions(languageName: input.languageName,
                                                           isShortNote: input.isShortNote)
            + "\n\nThe transcript is provided on standard input. Do not use any tools."
        let reply = try await run(arguments: arguments(prompt: prompt, schema: MeetingNotesSchema.fullCompact),
                                  stdin: MeetingCloudPrompts.notesUserMessage(transcript: input.transcript),
                                  timeout: ClaudeCodeProvider.notesTimeout(words: input.wordCount))
        guard let notes = Self.notes(fromReply: reply) else {
            throw MeetingAIProviderError.schemaMismatch(raw: String(reply.prefix(2_000)))
        }
        if let title = notes.title { onTitle(title) }
        return notes
    }

    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let prompt = MeetingCloudPrompts.askInstructions
            + "\n\nThe question and transcript are provided on standard input. Do not use any tools."
        let reply = try await run(arguments: arguments(prompt: prompt, schema: nil),
                                  stdin: MeetingCloudPrompts.askUserMessage(question: input.question,
                                                                            transcript: input.transcript),
                                  timeout: 180)
        let answer = Self.text(fromReply: reply)
        guard !answer.isEmpty else { throw MeetingAIProviderError.schemaMismatch(raw: String(reply.prefix(500))) }
        onPartial(answer)
        return answer
    }

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        let prompt = instructions + "\n\nThe input is provided on standard input. Do not use any tools."
        let reply = try await run(arguments: arguments(prompt: prompt, schema: jsonSchema.map(ClaudeCodeProvider.compact)),
                                  stdin: input, timeout: 600)
        return jsonSchema == nil ? Self.text(fromReply: reply) : reply
    }

    // MARK: Process

    private func run(arguments: [String], stdin: String, timeout: TimeInterval) async throws -> String {
        guard let binary = CLIDiscovery.locate(.antigravity) else { throw MeetingAIProviderError.notInstalled }
        let (first, _) = try await CLIProcessRunner.run(
            executable: binary, arguments: { _ in arguments }, stdin: stdin, timeout: timeout)
        if first.exitCode != 0 {
            throw MeetingAIProviderError.classify(first.stderr + "\n" + first.stdout, exitCode: first.exitCode)
        }
        if !first.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return first.stdout }

        // Empty success: retry with a pseudo-terminal. `script -q /dev/null cmd…` runs cmd on
        // a pty and copies its output to our stdout; no shell is involved.
        let script = URL(fileURLWithPath: "/usr/bin/script")
        let (second, _) = try await CLIProcessRunner.run(
            executable: script, arguments: { _ in ["-q", "/dev/null", binary.path] + arguments },
            stdin: stdin, timeout: timeout)
        if second.exitCode != 0 {
            throw MeetingAIProviderError.classify(second.stderr + "\n" + second.stdout, exitCode: second.exitCode)
        }
        return second.stdout
    }

    // MARK: Reply parsing

    /// Notes from either the bare schema object or a `{"result": "…json…"}` envelope.
    static func notes(fromReply reply: String) -> MeetingNotes? {
        if let notes = MeetingNotesSchema.decode(reply) { return notes }
        let inner = text(fromReply: reply)
        return inner == reply ? nil : MeetingNotesSchema.decode(inner)
    }

    /// The answer text from a JSON envelope (`result`, `response` or `text`), or the raw reply.
    static func text(fromReply reply: String) -> String {
        for candidate in MeetingNotesSchema.jsonObjectCandidates(in: reply) {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for key in ["result", "response", "text", "output"] {
                if let value = json[key] as? String, !value.isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif

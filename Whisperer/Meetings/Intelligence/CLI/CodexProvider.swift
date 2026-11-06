//
//  CodexProvider.swift
//  Whisperer
//
//  Meeting notes and Ask AI through the user's own, signed-in Codex (`codex exec`).
//  Also works when Codex is only present inside the ChatGPT desktop app.
//
//  Verified on codex-cli 0.166.0-alpha.5.1 (2026-11-06): with no PROMPT-reading flag the
//  piped stdin is appended to the prompt as a `<stdin>` block; `--output-schema` constrains
//  the final message and `-o` writes it to a file; `--sandbox read-only` + an empty temp cwd
//  leave nothing to read or write; `--ignore-user-config` skips `config.toml` (so no user
//  MCP servers start — including Whisperer's own) while auth still comes from CODEX_HOME;
//  `--ephemeral` keeps the meeting out of Codex's session files.
//

#if !APP_STORE

import Foundation

nonisolated struct CodexProvider: MeetingIntelligenceProvider {
    let id: AIProviderID = .codex
    var model: String?

    var modelLabel: String? { model }

    init(model: String? = nil) {
        let trimmed = model?.trimmingCharacters(in: .whitespaces)
        self.model = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: Readiness

    func readiness() async -> ProviderReadiness {
        guard let binary = CLIDiscovery.locate(.codex) else { return .notInstalled }
        do {
            let (result, _) = try await CLIProcessRunner.run(
                executable: binary, arguments: { _ in ["login", "status"] }, stdin: "", timeout: 15)
            return Self.readiness(fromLoginStatus: result.stdout + "\n" + result.stderr)
        } catch {
            return .unavailable("Couldn't run codex")
        }
    }

    static func readiness(fromLoginStatus output: String) -> ProviderReadiness {
        let lower = output.lowercased()
        if lower.contains("not logged in") {
            return .notSignedIn(hint: CLIDiscovery.signInCommand(for: .codex) ?? "codex login")
        }
        if lower.contains("logged in using chatgpt") { return .ready(detail: "ChatGPT plan") }
        if lower.contains("api key") { return .ready(detail: "API key") }
        if lower.contains("logged in") { return .ready(detail: nil) }
        return .unavailable("Unexpected response from codex login status")
    }

    // MARK: Arguments

    func arguments(workDir: URL, prompt: String, schemaFile: String?) -> [String] {
        var args = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--color", "never",
            "-C", workDir.path,
            "-o", workDir.appendingPathComponent("out.txt").path,
        ]
        if let schemaFile { args += ["--output-schema", workDir.appendingPathComponent(schemaFile).path] }
        if let model { args += ["-m", model] }
        args.append(prompt)
        return args
    }

    // MARK: Notes

    func generateNotes(_ input: MeetingNotesInput,
                       onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        guard let binary = CLIDiscovery.locate(.codex) else { throw MeetingAIProviderError.notInstalled }
        let prompt = MeetingCloudPrompts.notesInstructions(languageName: input.languageName,
                                                           isShortNote: input.isShortNote)
            + "\n\nThe transcript is in the <stdin> block. Do not run any commands."
        let (result, collected) = try await CLIProcessRunner.run(
            executable: binary,
            arguments: { dir in arguments(workDir: dir, prompt: prompt, schemaFile: "schema.json") },
            stdin: MeetingCloudPrompts.notesUserMessage(transcript: input.transcript),
            files: ["schema.json": MeetingNotesSchema.full],
            timeout: ClaudeCodeProvider.notesTimeout(words: input.wordCount),
            collect: { dir in try? String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8) })
        let reply = try Self.reply(result: result, collected: collected)
        guard let notes = MeetingNotesSchema.decode(reply) else {
            throw MeetingAIProviderError.schemaMismatch(raw: String(reply.prefix(2_000)))
        }
        if let title = notes.title { onTitle(title) }
        return notes
    }

    // MARK: Ask

    func ask(_ input: MeetingAskInput,
             onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let binary = CLIDiscovery.locate(.codex) else { throw MeetingAIProviderError.notInstalled }
        let prompt = MeetingCloudPrompts.askInstructions
            + "\n\nThe question and the transcript are in the <stdin> block. Do not run any commands."
        let (result, collected) = try await CLIProcessRunner.run(
            executable: binary,
            arguments: { dir in arguments(workDir: dir, prompt: prompt, schemaFile: nil) },
            stdin: MeetingCloudPrompts.askUserMessage(question: input.question, transcript: input.transcript),
            timeout: 180,
            collect: { dir in try? String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8) })
        let answer = try Self.reply(result: result, collected: collected)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw MeetingAIProviderError.schemaMismatch(raw: "") }
        onPartial(answer)
        return answer
    }

    // MARK: Generic

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        guard let binary = CLIDiscovery.locate(.codex) else { throw MeetingAIProviderError.notInstalled }
        let prompt = instructions + "\n\nThe input is in the <stdin> block. Do not run any commands."
        var files: [String: String] = [:]
        if let jsonSchema { files["schema.json"] = jsonSchema }
        let (result, collected) = try await CLIProcessRunner.run(
            executable: binary,
            arguments: { dir in arguments(workDir: dir, prompt: prompt, schemaFile: jsonSchema == nil ? nil : "schema.json") },
            stdin: input, files: files, timeout: 600,
            collect: { dir in try? String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8) })
        return try Self.reply(result: result, collected: collected)
    }

    /// The final message, from `-o` when present, otherwise the tail of stdout.
    static func reply(result: CLIResult, collected: String?) throws -> String {
        if result.exitCode != 0 {
            throw MeetingAIProviderError.classify(result.stderr + "\n" + result.stdout, exitCode: result.exitCode)
        }
        if let collected, !collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return collected
        }
        // Exit 0 with no final message is how a usage limit surfaces in some versions.
        let combined = result.stdout + "\n" + result.stderr
        if case .quotaExhausted = MeetingAIProviderError.classify(combined, exitCode: 0) {
            throw MeetingAIProviderError.quotaExhausted(retryAfter: nil)
        }
        return result.stdout
    }
}

#endif

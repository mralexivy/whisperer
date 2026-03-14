//
//  CommandModeService.swift
//  Whisperer
//
//  Agentic voice-to-terminal using local LLM (non-sandboxed builds only)
//

#if !APP_STORE

import Foundation
import Combine

enum MessageRole: String, Codable {
    case user
    case assistant
    case tool
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

@MainActor
class CommandModeService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var pendingCommand: String?
    @Published var streamingText: String = ""

    private let llmProcessor: LLMPostProcessor
    private let terminal = TerminalService()
    private let maxTurns = 20

    init(llmProcessor: LLMPostProcessor) {
        self.llmProcessor = llmProcessor
    }

    /// Process a voice command through the agentic loop
    func processVoiceCommand(_ transcription: String) async {
        guard llmProcessor.isModelLoaded else {
            messages.append(ChatMessage(role: .assistant, content: "LLM model not loaded. Please load a model first."))
            return
        }

        messages.append(ChatMessage(role: .user, content: transcription))
        isProcessing = true
        defer { isProcessing = false }

        // Build context from conversation history
        let context = buildContext()
        let systemPrompt = """
        You are a terminal assistant. The user gives voice commands and you help execute them.

        When you need to run a shell command, respond with EXACTLY this format:
        ```command
        <the command here>
        ```

        When you want to explain something or show results, just write normally.
        Always explain what you're about to do before running commands.
        If a command seems destructive (rm -rf, sudo, etc.), warn the user first.
        Keep responses concise.
        """

        let prompt = "\(systemPrompt)\n\n\(context)\n\nUser: \(transcription)"

        for turn in 0..<maxTurns {
            do {
                let contextPrompt = turn == 0 ? prompt : buildContext()
                let response = try await llmProcessor.process(
                    text: prompt + (turn > 0 ? "\n\n\(buildContext())" : ""),
                    systemPrompt: contextPrompt
                )

                // Parse response for command blocks
                if let command = extractCommand(from: response) {
                    // Check if destructive
                    if await terminal.isDestructive(command) {
                        pendingCommand = command
                        messages.append(ChatMessage(role: .assistant, content: "This command could be destructive:\n```\n\(command)\n```\nWaiting for confirmation..."))
                        return
                    }

                    // Execute command
                    messages.append(ChatMessage(role: .assistant, content: response))
                    let result = try await terminal.execute(command: command)

                    let output = result.exitCode == 0
                        ? (result.stdout.isEmpty ? "(no output)" : result.stdout)
                        : "Error (exit \(result.exitCode)):\n\(result.stderr.isEmpty ? result.stdout : result.stderr)"

                    messages.append(ChatMessage(role: .tool, content: output))

                    // If command succeeded, continue the loop for follow-up
                    if result.exitCode == 0 {
                        continue
                    }
                } else {
                    // No command in response — just text explanation
                    messages.append(ChatMessage(role: .assistant, content: response))
                }

                break
            } catch {
                messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                break
            }
        }
    }

    /// Confirm and execute a pending destructive command
    func confirmPendingCommand() async {
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        isProcessing = true
        defer { isProcessing = false }

        do {
            let result = try await terminal.execute(command: command)
            let output = result.exitCode == 0
                ? (result.stdout.isEmpty ? "(command completed)" : result.stdout)
                : "Error (exit \(result.exitCode)):\n\(result.stderr.isEmpty ? result.stdout : result.stderr)"
            messages.append(ChatMessage(role: .tool, content: output))
        } catch {
            messages.append(ChatMessage(role: .tool, content: "Execution failed: \(error.localizedDescription)"))
        }
    }

    /// Cancel a pending destructive command
    func cancelPendingCommand() {
        pendingCommand = nil
        messages.append(ChatMessage(role: .assistant, content: "Command cancelled."))
    }

    /// Clear all messages
    func clearConversation() {
        messages.removeAll()
        pendingCommand = nil
        streamingText = ""
    }

    // MARK: - Private

    private func buildContext() -> String {
        let recentMessages = messages.suffix(10)
        return recentMessages.map { msg in
            switch msg.role {
            case .user: return "User: \(msg.content)"
            case .assistant: return "Assistant: \(msg.content)"
            case .tool: return "Tool output: \(msg.content)"
            }
        }.joined(separator: "\n\n")
    }

    private func extractCommand(from text: String) -> String? {
        // Look for ```command ... ``` blocks
        let pattern = "```command\\s*\\n([\\s\\S]*?)\\n?```"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let command = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

#endif

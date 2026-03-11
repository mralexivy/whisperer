//
//  TerminalService.swift
//  Whisperer
//
//  Shell command execution for command mode (non-sandboxed builds only)
//

#if !APP_STORE

import Foundation

struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let duration: TimeInterval
}

actor TerminalService {
    private let executionTimeout: TimeInterval = 30.0

    // Commands that could cause data loss or system damage
    private static let destructivePatterns: [String] = [
        "rm -rf /", "rm -rf ~", "rm -rf /*",
        "sudo rm", "sudo mkfs", "sudo dd",
        "mkfs.", "dd if=", "> /dev/",
        ":(){:|:&};:", "chmod -R 777 /",
    ]

    /// Execute a shell command and return the result
    func execute(command: String, workingDirectory: String? = nil) async throws -> CommandResult {
        let start = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Timeout handling
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(executionTimeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
                Logger.warning("Command timed out after \(executionTimeout)s: \(command.prefix(50))", subsystem: .app)
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let duration = Date().timeIntervalSince(start)

        return CommandResult(
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: process.terminationStatus,
            duration: duration
        )
    }

    /// Check if a command appears destructive
    func isDestructive(_ command: String) -> Bool {
        let lower = command.lowercased()
        return Self.destructivePatterns.contains { lower.contains($0) }
    }
}

#endif

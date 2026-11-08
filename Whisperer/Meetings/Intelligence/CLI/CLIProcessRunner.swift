//
//  CLIProcessRunner.swift
//  Whisperer
//
//  Runs a user-installed AI CLI as a text-in, JSON-out function.
//
//  These CLIs are coding agents. Whisperer never wants their agency, so every call:
//  - runs in a fresh, empty temp directory that is deleted afterwards (never $HOME or the
//    meetings store), so a stray tool call has nothing to read;
//  - passes the transcript on stdin, never argv (argv is visible to every local user in `ps`);
//  - gets a scrubbed environment: PATH, HOME, locale and the vendor's own auth variables;
//  - is bounded by a wall-clock timeout and an output cap, and is killed (SIGTERM, then
//    SIGKILL after 2 s) when the calling task is cancelled.
//
//  Whisperer never reads, copies or forwards the CLI's credentials — the binary
//  authenticates itself from its own config, exactly as when the user runs it in Terminal.
//
//  Direct-download build only: the App Store sandbox is inherited by child processes,
//  which then cannot read their own credentials.
//

#if !APP_STORE

import Foundation

nonisolated struct CLIResult: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

nonisolated enum CLIProcessRunner {

    /// Variables passed through from Whisperer's environment. Vendor-specific auth variables
    /// are the user's own configuration for that CLI, so they travel with it.
    static let passthroughVariables: [String] = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CONFIG_DIR",
        "CODEX_HOME", "OPENAI_API_KEY",
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CLOUD_PROJECT",
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
    ]

    /// Whisperer is launched by launchd with a minimal PATH; CLIs installed by npm or
    /// Homebrew are node scripts that need `node` on PATH to start.
    static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }()

    static func environment(extra: [String: String] = [:],
                            from source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        for key in passthroughVariables {
            if let value = source[key], !value.isEmpty { env[key] = value }
        }
        // Keep the user's PATH entries (nvm and friends) after ours.
        let inherited = source["PATH"] ?? ""
        env["PATH"] = inherited.isEmpty ? searchPath : "\(searchPath):\(inherited)"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Runs `executable` with `arguments`, writing `stdin` and returning what it printed.
    ///
    /// - Parameters:
    ///   - files: written into the temp working directory before launch (schemas); the
    ///     closure receives the directory so arguments can reference them.
    ///   - onStdout: called with every chunk of stdout as it arrives, for streaming.
    ///   - collect: called after exit, before the temp directory is deleted, to read files the
    ///     CLI wrote there (Codex `-o`).
    ///
    /// `@concurrent`: temp-file writes, `posix_spawn` and the final pipe drain are synchronous,
    /// and callers include the main actor (`ConnectedAIStore.refreshReadiness`).
    @concurrent
    static func run(
        executable: URL,
        arguments: (URL) -> [String],
        stdin: String,
        files: [String: String] = [:],
        environment extraEnvironment: [String: String] = [:],
        timeout: TimeInterval,
        maxOutputBytes: Int = 8 * 1024 * 1024,
        onStdout: (@Sendable (String) -> Void)? = nil,
        collect: ((URL) -> String?)? = nil
    ) async throws -> (CLIResult, collected: String?) {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("whisperer-ai-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workDir) }

        for (name, contents) in files {
            let url = workDir.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(workDir)
        process.currentDirectoryURL = workDir
        process.environment = environment(extra: extraEnvironment)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let sink = OutputSink(limit: maxOutputBytes, onStdout: onStdout)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { sink.appendStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { sink.appendStderr(data) }
        }

        let exited = ExitSignal()
        process.terminationHandler = { proc in exited.fire(proc.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw MeetingAIProviderError.notInstalled
        }

        // stdin is written off the caller's executor: a large transcript can exceed the pipe
        // buffer, and the write blocks until the child reads it.
        let input = Data(stdin.utf8)
        let writer = stdinPipe.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }

        let pid = process.processIdentifier
        let status: Int32 = try await withTaskCancellationHandler {
            try await exited.wait(timeout: timeout) {
                Self.terminate(pid: pid, process: process)
            }
        } onCancel: {
            Self.terminate(pid: pid, process: process)
        }

        // Drain whatever the handlers have not delivered yet.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stdoutPipe.fileHandleForReading.readToEnd() { sink.appendStdout(rest) }
        if let rest = try? stderrPipe.fileHandleForReading.readToEnd() { sink.appendStderr(rest) }

        if Task.isCancelled { throw MeetingAIProviderError.cancelled }
        if exited.timedOut { throw MeetingAIProviderError.timeout }

        let collected = collect?(workDir)
        return (CLIResult(stdout: sink.stdoutText, stderr: sink.stderrText, exitCode: status), collected)
    }

    private static func terminate(pid: pid_t, process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Helpers

    /// Thread-safe accumulator fed by the pipe readability handlers.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private let limit: Int
        private let onStdout: (@Sendable (String) -> Void)?

        init(limit: Int, onStdout: (@Sendable (String) -> Void)?) {
            self.limit = limit
            self.onStdout = onStdout
        }

        func appendStdout(_ data: Data) {
            lock.lock()
            let room = max(0, limit - stdout.count)
            let accepted = data.prefix(room)
            stdout.append(accepted)
            lock.unlock()
            if !accepted.isEmpty, let onStdout, let text = String(data: accepted, encoding: .utf8) {
                onStdout(text)
            }
        }

        func appendStderr(_ data: Data) {
            lock.lock()
            // stderr is only ever used for classification and a log tail.
            if stderr.count < 256 * 1024 { stderr.append(data) }
            lock.unlock()
        }

        var stdoutText: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: stdout, as: UTF8.self)
        }

        var stderrText: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: stderr, as: UTF8.self)
        }
    }

    /// One-shot exit notification with a timeout.
    private final class ExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var continuation: CheckedContinuation<Int32, Error>?
        private(set) var timedOut = false

        func fire(_ code: Int32) {
            lock.lock()
            status = code
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: code)
        }

        func wait(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) async throws -> Int32 {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let status {
                    lock.unlock()
                    cont.resume(returning: status)
                    return
                }
                continuation = cont
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let stillWaiting = self.status == nil
                    if stillWaiting { self.timedOut = true }
                    self.lock.unlock()
                    if stillWaiting { onTimeout() }
                }
            }
        }
    }
}

#endif

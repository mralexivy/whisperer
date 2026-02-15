//
//  WhisperRunner.swift
//  Whisperer
//
//  Executes whisper.cpp transcription
//

import Foundation

class WhisperRunner {
    private let modelDownloader = ModelDownloader()

    private var whisperCLIPath: URL? {
        Bundle.main.url(forResource: "whisper-cli", withExtension: nil)
    }

    private var modelPath: URL {
        modelDownloader.modelPath
    }

    // MARK: - Transcription

    func transcribe(audioFile: URL) async throws -> String {
        guard let whisperCLI = whisperCLIPath else {
            throw TranscriptionError.whisperCLINotFound
        }

        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw TranscriptionError.modelNotFound
        }

        print("Transcribing audio file: \(audioFile.path)")
        print("Using model: \(modelPath.path)")

        let process = Process()
        process.executableURL = whisperCLI

        // Build arguments
        let threadCount = ProcessInfo.processInfo.activeProcessorCount
        process.arguments = [
            "-m", modelPath.path,
            "-f", audioFile.path,
            "-t", "\(threadCount)",
            "--no-timestamps",
            "-l", "auto"  // auto-detect language
        ]

        // Capture stdout
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        print("Running whisper.cpp with \(threadCount) threads")
        print("Command: \(whisperCLI.path) -m \(modelPath.path) -f \(audioFile.path)")

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()

                process.terminationHandler = { process in
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                    print("=== WHISPER OUTPUT ===")
                    print(output)
                    print("=== WHISPER ERRORS ===")
                    print(errorOutput)
                    print("=== EXIT CODE: \(process.terminationStatus) ===")

                    if process.terminationStatus != 0 {
                        print("Whisper process failed with exit code \(process.terminationStatus)")
                        continuation.resume(throwing: TranscriptionError.processFailed(errorOutput))
                        return
                    }

                    // Parse output
                    let transcription = self.parseWhisperOutput(output)
                    print("Parsed transcription: '\(transcription)'")

                    if transcription.isEmpty {
                        print("No transcription found in output")
                        continuation.resume(throwing: TranscriptionError.noSpeechDetected)
                    } else {
                        print("Transcription successful: \(transcription)")
                        continuation.resume(returning: transcription)
                    }
                }
            } catch {
                continuation.resume(throwing: TranscriptionError.processLaunchFailed(error))
            }
        }
    }

    // MARK: - Output Parsing

    nonisolated private func parseWhisperOutput(_ output: String) -> String {
        // Whisper.cpp outputs the transcription in the format:
        // [TRANSCRIPTION] text here
        // or sometimes just the text directly

        var lines = output.components(separatedBy: .newlines)

        // Filter out empty lines, progress indicators, and metadata
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty &&
                   !trimmed.hasPrefix("[") &&
                   !trimmed.contains("whisper_") &&
                   !trimmed.contains("system_info") &&
                   !trimmed.contains("load time") &&
                   !trimmed.contains("mel time") &&
                   !trimmed.contains("sample time")
        }

        // Join remaining lines and clean up
        let transcription = lines
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return transcription
    }
}

enum TranscriptionError: Error, LocalizedError {
    case whisperCLINotFound
    case modelNotFound
    case processFailed(String)
    case processLaunchFailed(Error)
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .whisperCLINotFound:
            return "Whisper CLI binary not found in app bundle"
        case .modelNotFound:
            return "Whisper model not found. Please download the model first."
        case .processFailed(let output):
            return "Whisper process failed: \(output)"
        case .processLaunchFailed(let error):
            return "Failed to launch whisper process: \(error.localizedDescription)"
        case .noSpeechDetected:
            return "No speech detected in audio"
        }
    }
}

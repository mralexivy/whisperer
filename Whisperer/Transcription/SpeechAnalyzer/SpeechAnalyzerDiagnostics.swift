//
//  SpeechAnalyzerDiagnostics.swift
//  Whisperer
//
//  In-app diagnostic tests for SpeechAnalyzer transcription pipeline
//

#if canImport(Speech)
import Combine
import Foundation
import AVFoundation
import Speech

@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerDiagnostics: ObservableObject {

    struct TestResult: Identifiable {
        let id = UUID()
        let fileName: String
        let duration: Double
        let expectedText: String
        let actualText: String
        let latencyMs: Double
        let passed: Bool
    }

    @Published var isRunning = false
    @Published var results: [TestResult] = []
    @Published var status: String = ""

    /// Run diagnostics using saved recordings from the Recordings directory.
    /// Tests that SpeechAnalyzer produces correct full-sentence output.
    func runDiagnostics() {
        guard !isRunning else { return }

        Task { [weak self] in
            guard let self = self else { return }
            self.isRunning = true
            self.results.removeAll()

            // Gather test cases from saved recordings
            let testCases = self.gatherTestCases()
            guard !testCases.isEmpty else {
                self.status = "No test recordings found"
                self.isRunning = false
                return
            }

            self.status = "Preparing SpeechAnalyzer..."

            // Prepare a fresh bridge
            let bridge: SpeechAnalyzerBridge
            do {
                bridge = try await SpeechAnalyzerBridge.prepare()
            } catch {
                self.status = "Failed to prepare SpeechAnalyzer: \(error.localizedDescription)"
                self.isRunning = false
                return
            }

            // Run each test case
            for (index, testCase) in testCases.enumerated() {
                self.status = "Testing \(index + 1)/\(testCases.count): \(testCase.fileName)..."

                guard let samples = self.loadSamplesFromWAV(url: testCase.url) else {
                    self.results.append(TestResult(
                        fileName: testCase.fileName,
                        duration: 0,
                        expectedText: testCase.expectedText,
                        actualText: "[Failed to load WAV]",
                        latencyMs: 0,
                        passed: false
                    ))
                    continue
                }

                let duration = Double(samples.count) / 16000.0
                let start = CFAbsoluteTimeGetCurrent()

                // Test: sync transcribe (the path used by stop() final pass)
                let result = bridge.transcribe(
                    samples: samples,
                    initialPrompt: nil,
                    language: .english
                )

                let latencyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                let normalizedResult = result.lowercased().trimmingCharacters(in: .punctuationCharacters)
                let normalizedExpected = testCase.expectedText.lowercased().trimmingCharacters(in: .punctuationCharacters)

                // Pass if result contains most of the expected words
                let expectedWords = Set(normalizedExpected.split(separator: " "))
                let resultWords = Set(normalizedResult.split(separator: " "))
                let matchRatio = expectedWords.isEmpty ? 0 : Double(expectedWords.intersection(resultWords).count) / Double(expectedWords.count)
                let passed = matchRatio >= 0.6 && !result.isEmpty

                self.results.append(TestResult(
                    fileName: testCase.fileName,
                    duration: duration,
                    expectedText: testCase.expectedText,
                    actualText: result,
                    latencyMs: latencyMs,
                    passed: passed
                ))

                Logger.info("SpeechAnalyzer test: '\(testCase.fileName)' → '\(result)' (\(String(format: "%.0f", latencyMs))ms, \(passed ? "PASS" : "FAIL"))", subsystem: .transcription)
            }

            let passCount = self.results.filter(\.passed).count
            self.status = "\(passCount)/\(self.results.count) tests passed"
            self.isRunning = false
        }
    }

    // MARK: - Test Case Discovery

    private struct TestCase {
        let url: URL
        let fileName: String
        let expectedText: String
    }

    /// Finds recordings with recognizable expected text in the filename.
    /// Filenames like "2026-03-04_18-07-07_Hello_how_are_you_doing_today.wav"
    /// encode the expected transcription after the timestamp.
    private func gatherTestCases() -> [TestCase] {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")

        guard let files = try? fileManager.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var testCases: [TestCase] = []
        for file in files where file.pathExtension == "wav" {
            let name = file.deletingPathExtension().lastPathComponent
            // Extract expected text after "YYYY-MM-DD_HH-MM-SS_" prefix
            // e.g., "2026-03-04_20-10-50_Hello" → "Hello"
            // e.g., "2026-03-04_18-07-07_Hello_how_are_you" → "Hello how are you"
            let parts = name.split(separator: "_", maxSplits: 2)
            guard parts.count >= 3 else { continue }
            // parts[0] = date, parts[1] = time, parts[2] = text with underscores
            let expectedText = String(parts[2]).replacingOccurrences(of: "_", with: " ")
            guard expectedText.count >= 3 else { continue }

            testCases.append(TestCase(
                url: file,
                fileName: file.lastPathComponent,
                expectedText: expectedText
            ))
        }

        // Sort by date (most recent first), limit to 10
        return testCases.sorted { $0.fileName > $1.fileName }.prefix(10).map { $0 }
    }

    // MARK: - Audio Loading

    private func loadSamplesFromWAV(url: URL) -> [Float]? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard frameCount > 0 else { return nil }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                return nil
            }
            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        } catch {
            Logger.error("Failed to load WAV: \(error)", subsystem: .transcription)
            return nil
        }
    }
}
#endif

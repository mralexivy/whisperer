//
//  BenchmarkManager.swift
//  Whisperer
//
//  Orchestrates transcription backend benchmarks with measurement
//

import Foundation
import Combine
import Accelerate
import AVFoundation

@MainActor
class BenchmarkManager: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var results: [BenchmarkResult] = []
    @Published var comparison: BenchmarkComparison?
    @Published var currentStatus: String = ""

    // Configuration
    @Published var selectedDuration: BenchmarkDuration = .fiveSeconds
    @Published var iterations: Int = 3
    @Published var useCustomAudio: Bool = false
    @Published var customAudioSamples: [Float]?

    // Recording-based benchmark
    @Published var audioSource: BenchmarkAudioSource = .recording
    @Published var availableRecordings: [BenchmarkRecording] = []
    @Published var selectedRecording: BenchmarkRecording?

    // Per-backend model selection (independent of app-wide settings)
    @Published var benchmarkWhisperModel: WhisperModel = AppState.shared.selectedModel
    @Published var benchmarkParakeetVariant: ParakeetModelVariant = AppState.shared.selectedParakeetModel

    private var benchmarkTask: Task<Void, Never>?

    // Dedicated bridges for benchmarking — independent of the active backend.
    // Each backend gets its own bridge so we never accidentally test the wrong engine.
    private var benchmarkWhisperBridge: WhisperBridge?
    private var benchmarkParakeetBridge: FluidAudioBridge?

    // MARK: - Run Benchmark

    func runBenchmark(backends: [BackendType]) {
        guard !isRunning else { return }

        benchmarkTask = Task { [weak self] in
            guard let self = self else { return }

            self.isRunning = true
            self.progress = 0
            self.results.removeAll()
            self.comparison = nil

            // Prepare dedicated bridges for each backend
            var activeBackends = backends

            if activeBackends.contains(.whisperCpp) {
                let ready = await self.prepareBenchmarkWhisperBridge()
                if !ready {
                    Logger.warning("whisper.cpp model not available, skipping", subsystem: .transcription)
                    activeBackends.removeAll { $0 == .whisperCpp }
                    self.currentStatus = "whisper.cpp model not available — running Parakeet only"
                }
            }

            if activeBackends.contains(.parakeet) {
                let ready = await self.prepareBenchmarkParakeetBridge()
                if !ready {
                    Logger.warning("Parakeet backend not available, skipping", subsystem: .transcription)
                    activeBackends.removeAll { $0 == .parakeet }
                    self.currentStatus = "Parakeet model not available — running whisper.cpp only"
                }
            }

            guard !activeBackends.isEmpty else {
                self.currentStatus = "No backends available"
                self.isRunning = false
                return
            }

            let testSamples: [Float]
            if self.audioSource == .recording, let recording = self.selectedRecording {
                self.currentStatus = "Loading recording..."
                if let samples = self.loadSamplesFromRecording(recording) {
                    testSamples = samples
                } else {
                    self.currentStatus = "Failed to load recording"
                    self.isRunning = false
                    return
                }
            } else if self.useCustomAudio, let custom = self.customAudioSamples {
                testSamples = custom
            } else {
                testSamples = self.generateTestAudio(duration: self.selectedDuration)
            }

            let audioDuration = Double(testSamples.count) / 16000.0

            // Warmup: run one untimed transcription per backend to warm up ANE/Metal caches
            for backend in activeBackends {
                guard !Task.isCancelled else { break }
                self.currentStatus = "\(backend.displayName) — warming up..."

                let warmupSamples = Array(testSamples.prefix(16000)) // 1 second
                await self.runUntimed(backend: backend, samples: warmupSamples)
            }

            // Measured iterations
            let totalRuns = activeBackends.count * self.iterations
            var completedRuns = 0

            for backend in activeBackends {
                guard !Task.isCancelled else { break }

                for iteration in 1...self.iterations {
                    guard !Task.isCancelled else { break }

                    self.currentStatus = "\(backend.displayName) — iteration \(iteration)/\(self.iterations)"

                    let result = await self.runSingleBenchmark(
                        backend: backend,
                        samples: testSamples,
                        audioDuration: audioDuration,
                        iteration: iteration
                    )

                    if let result = result {
                        self.results.append(result)
                    }

                    completedRuns += 1
                    self.progress = Double(completedRuns) / Double(totalRuns)
                }
            }

            // Compute comparison if we have results from multiple backends
            if activeBackends.count >= 2 {
                let a = activeBackends[0]
                let b = activeBackends[1]
                let resultsA = self.results.filter { $0.backendType == a }
                let resultsB = self.results.filter { $0.backendType == b }
                if !resultsA.isEmpty && !resultsB.isEmpty {
                    self.comparison = BenchmarkComparison(
                        backendA: a,
                        backendB: b,
                        resultsA: resultsA,
                        resultsB: resultsB
                    )
                }
            }

            // Release temporary bridges
            self.releaseBenchmarkBridges()

            self.currentStatus = "Complete"
            self.isRunning = false
        }
    }

    /// Whether Parakeet is available for benchmarking (Apple Silicon only)
    var isParakeetReady: Bool {
        BackendType.parakeet.isAvailable
    }

    /// Whether the selected whisper.cpp benchmark model is downloaded
    var isWhisperCppReady: Bool {
        ModelDownloader.shared.isModelDownloaded(benchmarkWhisperModel)
    }

    /// All downloaded whisper.cpp models available for benchmarking
    var downloadedWhisperModels: [WhisperModel] {
        ModelDownloader.shared.downloadedModels()
    }

    /// Whether the selected Parakeet variant is cached locally
    var isParakeetModelCached: Bool {
        FluidAudioBridge.isModelCached(variant: benchmarkParakeetVariant)
    }

    func cancelBenchmark() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
        releaseBenchmarkBridges()
        isRunning = false
        currentStatus = "Cancelled"
    }

    // MARK: - Bridge Lifecycle

    /// Load a dedicated WhisperBridge for benchmarking using benchmark-local model selection
    private func prepareBenchmarkWhisperBridge() async -> Bool {
        // If the benchmark model matches the active backend's model, reuse it
        if AppState.shared.selectedBackendType == .whisperCpp,
           AppState.shared.selectedModel == benchmarkWhisperModel,
           let existing = AppState.shared.fileTranscriptionBridge as? WhisperBridge {
            benchmarkWhisperBridge = existing
            return true
        }

        // Otherwise load a fresh WhisperBridge with the benchmark-selected model
        let model = benchmarkWhisperModel
        let path = ModelDownloader.shared.modelPath(for: model)

        guard FileManager.default.fileExists(atPath: path.path) else {
            Logger.warning("whisper.cpp model not downloaded: \(model.displayName)", subsystem: .transcription)
            return false
        }

        do {
            currentStatus = "Loading whisper.cpp \(model.displayName) for benchmark..."
            let bridge = try WhisperBridge(modelPath: path)
            benchmarkWhisperBridge = bridge
            Logger.info("WhisperBridge (\(model.displayName)) loaded for benchmarking", subsystem: .transcription)
            return true
        } catch {
            Logger.error("Failed to load WhisperBridge for benchmark: \(error)", subsystem: .transcription)
            return false
        }
    }

    /// Load a dedicated FluidAudioBridge for benchmarking using benchmark-local variant selection
    private func prepareBenchmarkParakeetBridge() async -> Bool {
        // If the benchmark variant matches the active backend's variant, reuse it
        if AppState.shared.selectedBackendType == .parakeet,
           AppState.shared.selectedParakeetModel == benchmarkParakeetVariant,
           let existing = AppState.shared.fileTranscriptionBridge as? FluidAudioBridge {
            benchmarkParakeetBridge = existing
            return true
        }

        // Otherwise load a fresh FluidAudioBridge with the benchmark-selected variant
        let variant = benchmarkParakeetVariant
        do {
            currentStatus = "Loading \(variant.displayName) for benchmark..."
            // Use cache-first loading to avoid unnecessary download checks
            if FluidAudioBridge.isModelCached(variant: variant) {
                benchmarkParakeetBridge = try await FluidAudioBridge.loadFromCache(variant: variant)
            } else {
                benchmarkParakeetBridge = try await FluidAudioBridge.load(variant: variant)
            }
            Logger.info("\(variant.displayName) bridge loaded for benchmarking", subsystem: .transcription)
            return true
        } catch {
            Logger.error("Failed to load Parakeet bridge for benchmark: \(error)", subsystem: .transcription)
            return false
        }
    }

    /// Release benchmark bridges (only release bridges we created, not borrowed ones)
    private func releaseBenchmarkBridges() {
        // Only shut down bridges we created ourselves (not borrowed from the active backend)
        let isBorrowedWhisper = AppState.shared.selectedBackendType == .whisperCpp
            && AppState.shared.selectedModel == benchmarkWhisperModel
        if !isBorrowedWhisper {
            benchmarkWhisperBridge?.prepareForShutdown()
        }
        benchmarkWhisperBridge = nil

        let isBorrowedParakeet = AppState.shared.selectedBackendType == .parakeet
            && AppState.shared.selectedParakeetModel == benchmarkParakeetVariant
        if !isBorrowedParakeet {
            benchmarkParakeetBridge?.prepareForShutdown()
        }
        benchmarkParakeetBridge = nil
    }

    // MARK: - Single Benchmark Run

    /// Run one untimed warmup transcription to prime ANE/Metal caches
    private func runUntimed(backend: BackendType, samples: [Float]) async {
        guard let bridge = bridgeFor(backend) else { return }
        let language = AppState.shared.selectedLanguage

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bridge.transcribeAsync(
                samples: samples,
                initialPrompt: nil,
                language: language,
                singleSegment: false,
                maxTokens: 0
            ) { _ in
                continuation.resume()
            }
        }
    }

    private func bridgeFor(_ backend: BackendType) -> TranscriptionBackend? {
        switch backend {
        case .whisperCpp: return benchmarkWhisperBridge
        case .parakeet: return benchmarkParakeetBridge
        case .speechAnalyzer: return nil  // Benchmarking not supported for Apple Speech
        }
    }

    private func runSingleBenchmark(
        backend: BackendType,
        samples: [Float],
        audioDuration: Double,
        iteration: Int
    ) async -> BenchmarkResult? {
        guard let bridge = bridgeFor(backend) else {
            Logger.error("No \(backend.displayName) backend loaded for benchmark", subsystem: .transcription)
            return nil
        }

        let modelName: String
        switch backend {
        case .whisperCpp:
            modelName = benchmarkWhisperModel.displayName
        case .parakeet:
            modelName = benchmarkParakeetVariant.displayName
        case .speechAnalyzer:
            modelName = "Apple Speech"
        }

        let baselineMemory = Self.currentMemoryMB()
        let language = AppState.shared.selectedLanguage

        // Use transcribeAsync to avoid cooperative thread blocking.
        // This lets each backend dispatch to its own GCD queue without
        // burning cooperative threads on semaphore waits.
        let startTime = CFAbsoluteTimeGetCurrent()

        let text: String = await withCheckedContinuation { continuation in
            bridge.transcribeAsync(
                samples: samples,
                initialPrompt: nil,
                language: language,
                singleSegment: false,
                maxTokens: 0
            ) { result in
                continuation.resume(returning: result)
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0  // ms
        let peakMemory = Self.currentMemoryMB()
        let wordCount = text.split(separator: " ").count

        Logger.info("Benchmark [\(backend.displayName)] iter \(iteration): \(String(format: "%.0f", elapsed))ms, \(wordCount) words", subsystem: .transcription)

        return BenchmarkResult(
            id: UUID(),
            timestamp: Date(),
            backendType: backend,
            modelName: modelName,
            totalLatencyMs: elapsed,
            audioDurationSeconds: audioDuration,
            sampleCount: samples.count,
            wordCount: wordCount,
            transcribedText: text,
            peakMemoryMB: peakMemory,
            baselineMemoryMB: baselineMemory
        )
    }

    // MARK: - Memory Measurement

    static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576.0
    }

    // MARK: - Test Audio Generation

    /// Generate synthetic audio with speech-like frequency content for reproducible benchmarks.
    /// Uses a combination of formant frequencies modulated to mimic speech patterns.
    func generateTestAudio(duration: BenchmarkDuration) -> [Float] {
        let sampleRate: Double = 16000.0
        let totalSamples = duration.sampleCount
        var samples = [Float](repeating: 0, count: totalSamples)

        // Speech-like frequencies (formants: F1~500Hz, F2~1500Hz, F3~2500Hz)
        let frequencies: [(freq: Double, amp: Float)] = [
            (250.0, 0.3),
            (500.0, 0.25),
            (1000.0, 0.15),
            (1500.0, 0.1),
            (2500.0, 0.05),
        ]

        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            var sample: Float = 0

            // Amplitude modulation at ~4Hz (syllable rate)
            let envelope = Float(0.5 + 0.5 * sin(2.0 * .pi * 4.0 * t))

            for (freq, amp) in frequencies {
                // Slight frequency wobble for naturalness
                let wobble = 1.0 + 0.02 * sin(2.0 * .pi * 0.5 * t)
                sample += amp * Float(sin(2.0 * .pi * freq * wobble * t))
            }

            samples[i] = sample * envelope * 0.3  // Keep amplitude in reasonable range
        }

        // Add light noise
        var noise = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            noise[i] = Float.random(in: -0.02...0.02)
        }
        vDSP_vadd(samples, 1, noise, 1, &samples, 1, vDSP_Length(totalSamples))

        return samples
    }

    // MARK: - Recording Audio Source

    /// Scan recordings directory for WAV files with real speech
    func loadAvailableRecordings() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")

        guard fileManager.fileExists(atPath: recordingsDir.path) else {
            availableRecordings = []
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])
            let wavFiles = files.filter { $0.pathExtension.lowercased() == "wav" }
                .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) } // newest first

            availableRecordings = wavFiles.compactMap { url in
                guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else { return nil }
                let sizeBytes = attrs.fileSize ?? 0
                // WAV header ~44 bytes, 4 bytes per Float32 sample, 16kHz
                let estimatedDuration = max(0, Double(sizeBytes - 44) / (4.0 * 16000.0))
                guard estimatedDuration >= 0.5 else { return nil } // skip very short files

                // Extract display name from filename (strip timestamp prefix)
                let name = url.deletingPathExtension().lastPathComponent
                let displayName: String
                // Pattern: yyyy-MM-dd_HH-mm-ss_TextHere
                if name.count > 20, let underscoreRange = name.range(of: "_", range: name.index(name.startIndex, offsetBy: 19)..<name.endIndex) {
                    displayName = String(name[underscoreRange.upperBound...]).replacingOccurrences(of: "_", with: " ")
                } else {
                    displayName = name
                }

                return BenchmarkRecording(
                    url: url,
                    displayName: displayName,
                    duration: estimatedDuration,
                    date: attrs.creationDate
                )
            }

            // Auto-select first recording if none selected
            if selectedRecording == nil, let first = availableRecordings.first {
                selectedRecording = first
            }
        } catch {
            Logger.error("Failed to scan recordings directory: \(error)", subsystem: .transcription)
            availableRecordings = []
        }
    }

    /// Load Float32 samples from a WAV recording file
    private func loadSamplesFromRecording(_ recording: BenchmarkRecording) -> [Float]? {
        do {
            let audioFile = try AVAudioFile(forReading: recording.url)
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard frameCount > 0 else { return nil }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                return nil
            }
            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData else { return nil }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            Logger.info("Loaded \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s) from recording", subsystem: .transcription)
            return samples
        } catch {
            Logger.error("Failed to load recording: \(error)", subsystem: .transcription)
            return nil
        }
    }

    // MARK: - Formatted Results

    func averageLatency(for backend: BackendType) -> Double {
        let backendResults = results.filter { $0.backendType == backend }
        guard !backendResults.isEmpty else { return 0 }
        return backendResults.map(\.totalLatencyMs).reduce(0, +) / Double(backendResults.count)
    }

    func averageRTF(for backend: BackendType) -> Double {
        let backendResults = results.filter { $0.backendType == backend }
        guard !backendResults.isEmpty else { return 0 }
        return backendResults.map(\.realTimeFactor).reduce(0, +) / Double(backendResults.count)
    }

    func averageMemory(for backend: BackendType) -> Double {
        let backendResults = results.filter { $0.backendType == backend }
        guard !backendResults.isEmpty else { return 0 }
        return backendResults.map(\.memoryDeltaMB).reduce(0, +) / Double(backendResults.count)
    }

    func formattedLatency(_ ms: Double) -> String {
        if ms < 1000 {
            return String(format: "%.0fms", ms)
        } else {
            return String(format: "%.1fs", ms / 1000.0)
        }
    }

    func formattedRTF(_ rtf: Double) -> String {
        String(format: "%.2fx", rtf)
    }

    func formattedMemory(_ mb: Double) -> String {
        if abs(mb) < 1 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }
}

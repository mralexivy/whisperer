//
//  FileTranscriptionManager.swift
//  Whisperer
//
//  Manages file-based transcription: loads audio/video files, transcribes in chunks with progress
//

import Foundation
import AVFoundation
import Combine
import UniformTypeIdentifiers

// MARK: - State

enum FileTranscriptionState: Equatable {
    case idle
    case fileSelected
    case loading
    case transcribing
    case complete
    case error(message: String)
}

enum FileTranscriptionError: Error, LocalizedError {
    case unsupportedFormat
    case noAudioTrack
    case fileReadFailed(String)
    case modelNotLoaded
    case transcriptionFailed
    case recordingInProgress
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "This file format is not supported"
        case .noAudioTrack: return "No audio track found in this video file"
        case .fileReadFailed(let detail): return "Failed to read audio file: \(detail)"
        case .modelNotLoaded: return "Whisper model is not loaded yet. Please wait for the model to finish loading."
        case .transcriptionFailed: return "Transcription failed"
        case .recordingInProgress: return "Cannot transcribe files while a live recording is in progress"
        case .conversionFailed: return "Failed to convert audio to the required format"
        }
    }
}

// MARK: - Manager

@MainActor
class FileTranscriptionManager: ObservableObject {
    @Published var state: FileTranscriptionState = .idle
    @Published var transcriptionResult: String = ""
    @Published var progress: Double = 0.0
    @Published var currentChunk: Int = 0
    @Published var totalChunks: Int = 0
    @Published var selectedFileURL: URL?
    @Published var fileName: String = ""
    @Published var fileDuration: Double = 0.0
    @Published var fileSize: String = ""
    @Published var savedToHistory: Bool = false

    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    // Chunked transcription constants
    private let sampleRate: Double = 16000.0
    private let chunkDuration: Double = 30.0
    private let overlapDuration: Double = 0.5
    private let contextMaxLength = 100

    private var chunkSamples: Int { Int(chunkDuration * sampleRate) }
    private var overlapSamples: Int { Int(overlapDuration * sampleRate) }

    // Supported file extensions
    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aiff", "flac", "opus", "ogg"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let allExtensions: Set<String> = audioExtensions.union(videoExtensions)

    static var supportedContentTypes: [UTType] {
        [.audio, .mpeg4Movie, .quickTimeMovie, .movie]
    }

    // MARK: - File Selection

    func selectFile(url: URL) {
        selectedFileURL = url
        fileName = url.lastPathComponent
        savedToHistory = false
        transcriptionResult = ""
        progress = 0.0

        // Get file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            fileSize = formatFileSize(size)
        } else {
            fileSize = ""
        }

        // Get duration asynchronously
        fileDuration = 0.0
        Task {
            await loadFileDuration(url: url)
            state = .fileSelected
        }
    }

    func clearSelection() {
        selectedFileURL = nil
        fileName = ""
        fileDuration = 0.0
        fileSize = ""
        transcriptionResult = ""
        progress = 0.0
        savedToHistory = false
        state = .idle
    }

    // MARK: - Transcription

    func transcribeFile(language: TranscriptionLanguage) {
        guard let url = selectedFileURL else { return }

        guard let bridge = AppState.shared.fileTranscriptionBridge else {
            state = .error(message: FileTranscriptionError.modelNotLoaded.localizedDescription)
            return
        }

        guard AppState.shared.state == .idle else {
            state = .error(message: FileTranscriptionError.recordingInProgress.localizedDescription)
            return
        }

        isCancelled = false
        savedToHistory = false
        transcriptionResult = ""
        progress = 0.0
        state = .loading

        transcriptionTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let samples = try await self.loadAudioSamples(from: url)

                guard !self.isCancelled else {
                    await MainActor.run { self.state = .idle }
                    return
                }

                let totalSamples = samples.count
                let chunks = max(1, Int(ceil(Double(totalSamples) / Double(self.chunkSamples))))

                await MainActor.run {
                    self.totalChunks = chunks
                    self.currentChunk = 0
                    self.state = .transcribing
                }

                var accumulatedText = ""

                for chunkIndex in 0..<chunks {
                    guard !self.isCancelled else {
                        await MainActor.run { self.state = .idle }
                        return
                    }

                    let startSample = chunkIndex * self.chunkSamples
                    let endSample = min(startSample + self.chunkSamples, totalSamples)

                    // Add overlap from previous chunk for continuity
                    let overlapStart = max(0, startSample - self.overlapSamples)
                    let chunkData = Array(samples[overlapStart..<endSample])

                    let context: String? = accumulatedText.isEmpty ? nil : String(accumulatedText.suffix(self.contextMaxLength))

                    // Prepend prompt words to context for improved recognition
                    let promptPrefix = await AppState.shared.promptWordsString
                    let combinedPrompt: String? = {
                        let parts = [promptPrefix, context].compactMap { $0 }
                        return parts.isEmpty ? nil : parts.joined(separator: " ")
                    }()

                    // Transcribe on background thread — whisperBridge.transcribe() is blocking
                    let text = await Task.detached(priority: .userInitiated) { [weak self] () -> String in
                        guard self != nil else { return "" }
                        return bridge.transcribe(
                            samples: chunkData,
                            initialPrompt: combinedPrompt,
                            language: language,
                            singleSegment: false
                        )
                    }.value

                    guard !self.isCancelled else {
                        await MainActor.run { self.state = .idle }
                        return
                    }

                    // Deduplicate overlap at chunk boundary
                    let deduplicatedText = self.deduplicateOverlap(
                        previousText: accumulatedText,
                        newText: text
                    )

                    if !deduplicatedText.isEmpty {
                        if accumulatedText.isEmpty {
                            accumulatedText = deduplicatedText
                        } else {
                            accumulatedText += " " + deduplicatedText
                        }
                    }

                    await MainActor.run {
                        self.currentChunk = chunkIndex + 1
                        self.progress = Double(chunkIndex + 1) / Double(chunks)
                        self.transcriptionResult = accumulatedText
                    }
                }

                // Apply dictionary corrections
                let finalText = DictionaryManager.shared.correctText(accumulatedText)

                await MainActor.run {
                    self.transcriptionResult = finalText
                    self.progress = 1.0
                    self.state = .complete
                }

                Logger.info("File transcription complete: \(finalText.split(separator: " ").count) words from \(chunks) chunks", subsystem: .transcription)

            } catch {
                Logger.error("File transcription failed: \(error.localizedDescription)", subsystem: .transcription)
                await MainActor.run {
                    self.state = .error(message: error.localizedDescription)
                }
            }
        }
    }

    func cancelTranscription() {
        isCancelled = true
        transcriptionTask?.cancel()
        state = .idle
        Logger.info("File transcription cancelled", subsystem: .transcription)
    }

    // MARK: - Save to History

    func saveToHistory() async {
        guard state == .complete, !transcriptionResult.isEmpty else { return }
        guard let sourceURL = selectedFileURL else { return }

        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")

        // Ensure recordings directory exists
        try? fileManager.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        // Copy source file with timestamp prefix
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
        let destFileName = "\(timestamp)_\(sourceURL.lastPathComponent)"
        let destURL = recordingsDir.appendingPathComponent(destFileName)

        do {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } catch {
            Logger.warning("Could not copy source file to recordings: \(error.localizedDescription)", subsystem: .app)
            // Continue saving without the audio file reference
        }

        let audioFileName = fileManager.fileExists(atPath: destURL.path) ? destFileName : nil

        // Use detected language when auto-detect is active, otherwise use user selection
        let recordedLanguage: String
        if AppState.shared.selectedLanguage == .auto,
           let detected = AppState.shared.fileTranscriptionBridge?.lastDetectedLanguage {
            recordedLanguage = detected
        } else {
            recordedLanguage = AppState.shared.selectedLanguage.rawValue
        }

        let record = TranscriptionRecord(
            transcription: transcriptionResult,
            audioFileURL: audioFileName,
            duration: fileDuration,
            language: recordedLanguage,
            modelUsed: AppState.shared.activeModelDisplayName,
            targetAppName: "File Import"
        )

        do {
            try await HistoryManager.shared.saveTranscription(record)
            savedToHistory = true
            Logger.info("File transcription saved to history", subsystem: .app)
        } catch {
            Logger.error("Failed to save file transcription to history: \(error.localizedDescription)", subsystem: .app)
        }
    }

    // MARK: - Audio Loading

    private func loadAudioSamples(from url: URL) async throws -> [Float] {
        let ext = url.pathExtension.lowercased()

        if Self.videoExtensions.contains(ext) {
            return try await loadVideoAudioSamples(from: url)
        } else if Self.audioExtensions.contains(ext) || Self.allExtensions.isEmpty {
            return try loadAudioFileSamples(from: url)
        } else {
            // Try audio first, fall back to video
            do {
                return try loadAudioFileSamples(from: url)
            } catch {
                return try await loadVideoAudioSamples(from: url)
            }
        }
    }

    private func loadAudioFileSamples(from url: URL) throws -> [Float] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw FileTranscriptionError.fileReadFailed(error.localizedDescription)
        }

        let processingFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard frameCount > 0 else {
            throw FileTranscriptionError.fileReadFailed("File contains no audio data")
        }

        // Read entire file into buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            throw FileTranscriptionError.conversionFailed
        }
        try audioFile.read(into: buffer)

        // Convert to 16kHz mono Float32
        return try convertToWhisperFormat(buffer: buffer, sourceFormat: processingFormat)
    }

    private func loadVideoAudioSamples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw FileTranscriptionError.fileReadFailed(error.localizedDescription)
        }

        guard let audioTrack = tracks.first else {
            throw FileTranscriptionError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw FileTranscriptionError.fileReadFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw FileTranscriptionError.fileReadFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        var allSamples: [Float] = []

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = length / MemoryLayout<Float>.size

            var data = [Float](repeating: 0, count: sampleCount)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)

            allSamples.append(contentsOf: data)
        }

        guard reader.status == .completed else {
            throw FileTranscriptionError.fileReadFailed("Audio extraction failed")
        }

        guard !allSamples.isEmpty else {
            throw FileTranscriptionError.noAudioTrack
        }

        return allSamples
    }

    private func convertToWhisperFormat(buffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) throws -> [Float] {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw FileTranscriptionError.conversionFailed
        }

        // If already in the correct format, extract directly
        if sourceFormat.sampleRate == sampleRate && sourceFormat.channelCount == 1 &&
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            guard let channelData = buffer.floatChannelData else {
                throw FileTranscriptionError.conversionFailed
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw FileTranscriptionError.conversionFailed
        }

        if sourceFormat.channelCount > 1 {
            converter.channelMap = [0]
        }

        let ratio = sampleRate / sourceFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            throw FileTranscriptionError.conversionFailed
        }

        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

        guard status != .error else {
            throw FileTranscriptionError.conversionFailed
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw FileTranscriptionError.conversionFailed
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    // MARK: - Helpers

    private func loadFileDuration(url: URL) async {
        let ext = url.pathExtension.lowercased()

        if Self.videoExtensions.contains(ext) {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                await MainActor.run {
                    self.fileDuration = duration.seconds
                }
            }
        } else {
            if let audioFile = try? AVAudioFile(forReading: url) {
                let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                await MainActor.run {
                    self.fileDuration = duration
                }
            }
        }
    }

    private func deduplicateOverlap(previousText: String, newText: String) -> String {
        guard !previousText.isEmpty, !newText.isEmpty else { return newText }

        let prevWords = previousText.split(separator: " ").map(String.init)
        let newWords = newText.split(separator: " ").map(String.init)

        guard !prevWords.isEmpty, !newWords.isEmpty else { return newText }

        // Check if the beginning of new text overlaps with the end of previous text
        let maxOverlapWords = min(5, prevWords.count, newWords.count)

        for overlapLen in stride(from: maxOverlapWords, through: 1, by: -1) {
            let prevTail = prevWords.suffix(overlapLen).map { $0.lowercased() }
            let newHead = newWords.prefix(overlapLen).map { $0.lowercased() }

            if prevTail == newHead {
                let remaining = newWords.dropFirst(overlapLen)
                return remaining.joined(separator: " ")
            }
        }

        return newText
    }

    private func formatFileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

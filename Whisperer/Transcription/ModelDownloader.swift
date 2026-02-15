//
//  ModelDownloader.swift
//  Whisperer
//
//  Downloads whisper models and VAD models on demand
//

import Foundation

// VAD Model definition
enum VADModel: String, CaseIterable {
    case sileroV6 = "ggml-silero-v6.2.0.bin"

    var displayName: String {
        switch self {
        case .sileroV6: return "Silero VAD v6.2.0"
        }
    }

    var sizeDescription: String {
        switch self {
        case .sileroV6: return "~2 MB"
        }
    }

    var downloadURL: URL {
        switch self {
        case .sileroV6:
            return URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!
        }
    }

    static var `default`: VADModel { .sileroV6 }
}

class ModelDownloader {
    static let shared = ModelDownloader()

    private var appSupportDir: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let whispererDir = appSupport.appendingPathComponent("Whisperer")

        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: whispererDir, withIntermediateDirectories: true)

        return whispererDir
    }

    // MARK: - Public API

    /// Get the local path for a model
    func modelPath(for model: WhisperModel) -> URL {
        appSupportDir.appendingPathComponent(model.rawValue)
    }

    /// Check if a specific model is downloaded
    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        return FileManager.default.fileExists(atPath: modelPath(for: model).path)
    }

    /// Get list of all downloaded models
    func downloadedModels() -> [WhisperModel] {
        return WhisperModel.allCases.filter { isModelDownloaded($0) }
    }

    /// Download a specific model
    func downloadModel(_ model: WhisperModel, progressCallback: @escaping (Double) -> Void) async throws {
        let destination = modelPath(for: model)

        if FileManager.default.fileExists(atPath: destination.path) {
            print("Model \(model.displayName) already exists at: \(destination.path)")
            return
        }

        print("Downloading \(model.displayName) from: \(model.downloadURL)")
        print("To: \(destination.path)")

        try await performDownload(url: model.downloadURL, destination: destination, progressCallback: progressCallback)
    }

    /// Delete a downloaded model
    func deleteModel(_ model: WhisperModel) throws {
        let path = modelPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            print("Deleted model: \(model.displayName)")
        }
    }

    // MARK: - VAD Model API

    /// Get the local path for a VAD model
    func vadModelPath(for model: VADModel = .default) -> URL {
        appSupportDir.appendingPathComponent(model.rawValue)
    }

    /// Check if a VAD model is downloaded and valid (not corrupted)
    func isVADModelDownloaded(_ model: VADModel = .default) -> Bool {
        let path = vadModelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }

        // Verify file size - Silero VAD model is ~0.85-0.88 MB, reject if < 500KB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int64 {
            if size < 500_000 {
                // File is corrupted/incomplete, delete it
                print("⚠️ VAD model file is corrupted (\(size) bytes), deleting...")
                try? FileManager.default.removeItem(at: path)
                return false
            }
        }
        return true
    }

    /// Download a VAD model
    func downloadVADModel(_ model: VADModel = .default, progressCallback: @escaping (Double) -> Void) async throws {
        let destination = vadModelPath(for: model)

        if FileManager.default.fileExists(atPath: destination.path) {
            print("VAD model \(model.displayName) already exists at: \(destination.path)")
            return
        }

        print("Downloading \(model.displayName) from: \(model.downloadURL)")
        print("To: \(destination.path)")

        try await performDownload(url: model.downloadURL, destination: destination, progressCallback: progressCallback)
    }

    /// Download VAD model if needed (silent, no progress)
    func ensureVADModelDownloaded() async throws {
        if !isVADModelDownloaded() {
            try await downloadVADModel { _ in }
        }
    }

    // MARK: - Legacy API (for backward compatibility)

    var modelPath: URL {
        modelPath(for: .largeTurbo)
    }

    func isModelDownloaded() -> Bool {
        return isModelDownloaded(.largeTurbo)
    }

    func downloadModelIfNeeded(progressCallback: @escaping (Double) -> Void) async throws {
        try await downloadModel(.largeTurbo, progressCallback: progressCallback)
    }

    // MARK: - Private

    private func performDownload(url: URL, destination: URL, progressCallback: @escaping (Double) -> Void) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                destination: destination,
                progressCallback: progressCallback,
                onComplete: { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )

            // Create configuration optimized for sandboxed apps
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3600  // 1 hour for large model downloads
            config.requestCachePolicy = .reloadIgnoringLocalCacheData

            // Create session with delegate
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)

            // Keep session and delegate alive
            objc_setAssociatedObject(task, "session", session, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(task, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

            task.resume()
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let progressCallback: (Double) -> Void
    let onComplete: (Result<Void, Error>) -> Void
    private let completionLock = NSLock()
    private var _hasCompleted = false
    private var hasCompleted: Bool {
        get { completionLock.lock(); defer { completionLock.unlock() }; return _hasCompleted }
        set { completionLock.lock(); _hasCompleted = newValue; completionLock.unlock() }
    }

    init(destination: URL, progressCallback: @escaping (Double) -> Void, onComplete: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.progressCallback = progressCallback
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionLock.lock()
        guard !_hasCompleted else {
            completionLock.unlock()
            return
        }
        _hasCompleted = true
        completionLock.unlock()

        do {
            // Move file to destination
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.moveItem(at: location, to: destination)
            Logger.debug("Model downloaded successfully to: \(destination.path)", subsystem: .model)

            onComplete(.success(()))
        } catch {
            Logger.error("Failed to move model file: \(error)", subsystem: .model)
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        completionLock.lock()
        guard !_hasCompleted else {
            completionLock.unlock()
            return
        }

        if let error = error {
            _hasCompleted = true
            completionLock.unlock()
            Logger.error("Download failed: \(error)", subsystem: .model)
            onComplete(.failure(error))
        } else {
            completionLock.unlock()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        DispatchQueue.main.async { [weak self] in
            self?.progressCallback(progress)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        print("Waiting for network connectivity...")
    }
}

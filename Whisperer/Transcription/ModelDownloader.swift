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

enum ModelDownloadError: Error, LocalizedError {
    case invalidFileSize
    case maxRetriesExhausted(lastError: Error)

    var errorDescription: String? {
        switch self {
        case .invalidFileSize:
            return "Downloaded model file is corrupted or incomplete"
        case .maxRetriesExhausted(let lastError):
            return "Download failed after 3 attempts: \(lastError.localizedDescription)"
        }
    }
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

    /// Check if a specific model is downloaded and valid (not corrupted)
    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        return isModelFileValid(model)
    }

    /// Check if a model file exists and passes size validation.
    /// Returns false (and deletes the file) if the file is corrupted/truncated.
    func isModelFileValid(_ model: WhisperModel) -> Bool {
        let path = modelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? Int64 else {
            return false
        }

        if size < model.minimumFileSizeBytes {
            Logger.warning("Model \(model.displayName) file is corrupted (\(size) bytes, minimum \(model.minimumFileSizeBytes)), deleting", subsystem: .model)
            try? FileManager.default.removeItem(at: path)
            return false
        }

        return true
    }

    /// Get list of all downloaded models
    func downloadedModels() -> [WhisperModel] {
        return WhisperModel.allCases.filter { isModelDownloaded($0) }
    }

    /// Download a specific model with retry logic and file validation
    func downloadModel(
        _ model: WhisperModel,
        progressCallback: @escaping (Double) -> Void,
        retryStatusCallback: ((Int, Int) -> Void)? = nil
    ) async throws {
        let destination = modelPath(for: model)

        // Check if valid model already exists (size-validated, not just file existence)
        if isModelFileValid(model) {
            Logger.info("Model \(model.displayName) already exists and is valid", subsystem: .model)
            return
        }

        // Clean up any corrupted partial file before downloading
        if FileManager.default.fileExists(atPath: destination.path) {
            Logger.warning("Removing invalid model file before re-download", subsystem: .model)
            try? FileManager.default.removeItem(at: destination)
        }

        Logger.info("Downloading \(model.displayName) from: \(model.downloadURL)", subsystem: .model)

        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                if attempt > 1 {
                    let backoffSeconds = UInt64(1 << (attempt - 2))  // 1s, 2s
                    Logger.info("Retrying download (\(attempt)/\(maxAttempts)) after \(backoffSeconds)s backoff...", subsystem: .model)

                    retryStatusCallback?(attempt, maxAttempts)
                    progressCallback(0)

                    try await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)

                    // Clean up partial file from previous attempt
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }

                try await performDownload(url: model.downloadURL, destination: destination, progressCallback: progressCallback)

                // Post-download validation
                guard isModelFileValid(model) else {
                    Logger.error("Downloaded model \(model.displayName) failed size validation (attempt \(attempt)/\(maxAttempts))", subsystem: .model)
                    throw ModelDownloadError.invalidFileSize
                }

                Logger.info("Model \(model.displayName) downloaded and validated successfully", subsystem: .model)
                return

            } catch {
                lastError = error
                Logger.warning("Download attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)", subsystem: .model)

                if error is CancellationError { throw error }
            }
        }

        throw ModelDownloadError.maxRetriesExhausted(lastError: lastError ?? ModelDownloadError.invalidFileSize)
    }

    /// Delete a downloaded model
    func deleteModel(_ model: WhisperModel) throws {
        let path = modelPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            Logger.info("Deleted model: \(model.displayName)", subsystem: .model)
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
                Logger.warning("VAD model file is corrupted (\(size) bytes), deleting", subsystem: .model)
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
            Logger.info("VAD model \(model.displayName) already exists", subsystem: .model)
            return
        }

        Logger.info("Downloading VAD \(model.displayName)", subsystem: .model)

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
        Logger.debug("Waiting for network connectivity...", subsystem: .model)
    }
}

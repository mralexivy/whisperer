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

/// What a transfer reports while it runs. Delivered on the main queue.
enum ModelTransferEvent {
    case progress(written: Int64, expected: Int64)
    case waitingForNetwork
    case retrying(attempt: Int, of: Int)
}

class ModelDownloader {
    static let shared = ModelDownloader()

    /// One transfer per model. A second request for a model already downloading joins the
    /// running transfer instead of starting another one into the same file — the meeting cleanup
    /// prefetch and a tap in the Models tab can ask for Whisperer V3 at the same moment.
    private var inFlight: [WhisperModel: Task<Void, Error>] = [:]
    /// Everyone waiting on a model's transfer, so each caller's progress UI hears every event.
    /// Both maps are main-actor state (the project's default isolation); the URLSession delegate
    /// hops here before touching them.
    private var observers: [WhisperModel: [UUID: (ModelTransferEvent) -> Void]] = [:]

    /// Cancel a model's download. Stops the transfer itself, including during the backoff
    /// between retries — an earlier version only cancelled the URLSession task, so a cancel that
    /// landed in the backoff was followed by the next attempt and a model the user had cancelled
    /// finished downloading and activated.
    func cancelDownload(_ model: WhisperModel) {
        guard let task = inFlight[model] else { return }
        task.cancel()
        Logger.info("Download of \(model.displayName) cancelled", subsystem: .model)
    }

    func isDownloading(_ model: WhisperModel) -> Bool {
        inFlight[model] != nil
    }

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

    /// Get set of downloaded models (for routing queries)
    func downloadedModelSet() -> Set<WhisperModel> {
        Set(downloadedModels())
    }

    // MARK: - Core ML Encoder Management

    /// Path for Core ML encoder directory (next to the model .bin file)
    func coreMLEncoderPath(for model: WhisperModel) -> URL? {
        guard let dirName = model.coreMLEncoderDirectoryName else { return nil }
        return appSupportDir.appendingPathComponent(dirName)
    }

    /// Check if Core ML encoder is downloaded for a model
    func isCoreMLEncoderDownloaded(_ model: WhisperModel) -> Bool {
        guard let path = coreMLEncoderPath(for: model) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Delete a model's Core ML encoder and any half-downloaded zip left by an older build.
    ///
    /// The app deliberately runs whisper.cpp on the Metal encoder — see
    /// `WhisperBridge.purgeCoreMLEncoder(besideModelAt:)` for the measurements. That purge already
    /// runs on every model load; this covers the download directory's leftovers (`.mlmodelc.zip`,
    /// `__MACOSX`) that never reach a load path.
    func purgeCoreMLEncoderArtifacts(for model: WhisperModel) {
        let fm = FileManager.default
        if let path = coreMLEncoderPath(for: model) {
            try? fm.removeItem(at: path)
            try? fm.removeItem(at: appSupportDir.appendingPathComponent("\(path.lastPathComponent).zip"))
        }
        try? fm.removeItem(at: appSupportDir.appendingPathComponent("__MACOSX"))
    }

    /// Download a specific model with retry logic and file validation. Fraction-only form for
    /// background callers (meeting cleanup, routing) that do not show bytes.
    func downloadModel(
        _ model: WhisperModel,
        progressCallback: @escaping (Double) -> Void,
        retryStatusCallback: ((Int, Int) -> Void)? = nil
    ) async throws {
        try await downloadModel(model) { event in
            switch event {
            case .progress(let written, let expected):
                progressCallback(expected > 0 ? Double(written) / Double(expected) : 0)
            case .retrying(let attempt, let max):
                retryStatusCallback?(attempt, max)
                progressCallback(0)
            case .waitingForNetwork:
                break
            }
        }
    }

    /// Download a specific model with retry logic and file validation.
    ///
    /// Joins the transfer already running for `model` if there is one. Cancelling the calling
    /// Task stops waiting; `cancelDownload(_:)` stops the transfer for everyone.
    func downloadModel(_ model: WhisperModel, onEvent: @escaping (ModelTransferEvent) -> Void) async throws {
        // Check if valid model already exists (size-validated, not just file existence)
        if isModelFileValid(model) {
            Logger.info("Model \(model.displayName) already exists and is valid", subsystem: .model)
            return
        }

        let observerID = UUID()
        observers[model, default: [:]][observerID] = onEvent
        let task: Task<Void, Error>
        if let running = inFlight[model] {
            task = running
            Logger.info("Joining the running download of \(model.displayName)", subsystem: .model)
        } else {
            task = Task(priority: .userInitiated) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.runTransfer(model)
            }
            inFlight[model] = task
            // Clears the slot whichever way the transfer ends.
            Task { [weak self] in
                _ = await task.result
                self?.inFlight[model] = nil
                self?.observers[model] = nil
            }
        }

        defer { observers[model]?[observerID] = nil }
        try await task.value
    }

    private func broadcast(_ event: ModelTransferEvent, for model: WhisperModel) {
        for callback in observers[model].map({ Array($0.values) }) ?? [] { callback(event) }
    }

    private func runTransfer(_ model: WhisperModel) async throws {
        let destination = modelPath(for: model)

        // Clean up any corrupted partial file before downloading
        if FileManager.default.fileExists(atPath: destination.path) {
            Logger.warning("Removing invalid model file before re-download", subsystem: .model)
            try? FileManager.default.removeItem(at: destination)
        }

        Logger.info("Downloading \(model.displayName) from: \(model.downloadURL)", subsystem: .model)

        let maxAttempts = 3
        var lastError: Error?
        /// Bytes already fetched by a failed attempt. A dropped connection 1.2 GB into a 1.5 GB
        /// model resumes from there instead of starting the bar over at zero.
        var resumeData: Data?

        for attempt in 1...maxAttempts {
            do {
                if attempt > 1 {
                    let backoffSeconds = UInt64(1 << (attempt - 2))  // 1s, 2s
                    Logger.info("Retrying download (\(attempt)/\(maxAttempts)) after \(backoffSeconds)s backoff\(resumeData != nil ? ", resuming" : "")...", subsystem: .model)
                    broadcast(.retrying(attempt: attempt, of: maxAttempts), for: model)
                    try await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                    try Task.checkCancellation()
                    if resumeData == nil, FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }

                try await performDownload(
                    url: model.downloadURL,
                    destination: destination,
                    resumeData: resumeData,
                    fallbackExpectedBytes: Int64(model.approximateDownloadBytes),
                    onEvent: { [weak self] event in
                        // Delegate queue → main, in order.
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.broadcast(event, for: model) } }
                    }
                )

                // Post-download validation
                guard isModelFileValid(model) else {
                    Logger.error("Downloaded model \(model.displayName) failed size validation (attempt \(attempt)/\(maxAttempts))", subsystem: .model)
                    resumeData = nil
                    throw ModelDownloadError.invalidFileSize
                }

                Logger.info("Model \(model.displayName) downloaded and validated successfully", subsystem: .model)
                return

            } catch {
                lastError = error
                if ModelDownloadFailure.isCancellation(error) || Task.isCancelled {
                    Logger.info("Download cancelled by user, not retrying", subsystem: .model)
                    throw CancellationError()
                }
                resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                Logger.warning("Download attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)", subsystem: .model)
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
        // Bundled so a first launch with no network still has speech detection.
        let name = (model.rawValue as NSString).deletingPathExtension
        return Bundle.main.url(forResource: name, withExtension: "bin")
            ?? appSupportDir.appendingPathComponent(model.rawValue)
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

        try await performDownload(url: model.downloadURL, destination: destination, resumeData: nil,
                                  fallbackExpectedBytes: 1_000_000) { event in
            if case .progress(let written, let expected) = event, expected > 0 {
                DispatchQueue.main.async { progressCallback(Double(written) / Double(expected)) }
            }
        }
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

    /// `onEvent` is called on URLSession's delegate queue.
    private nonisolated func performDownload(
        url: URL,
        destination: URL,
        resumeData: Data?,
        fallbackExpectedBytes: Int64,
        onEvent: @escaping @Sendable (ModelTransferEvent) -> Void
    ) async throws {
        let config = URLSessionConfiguration.default
        // Waits instead of failing when offline; the delegate reports it so the UI can say so.
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600  // 1 hour for large model downloads
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let box = DownloadTaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = DownloadDelegate(
                    destination: destination,
                    fallbackExpectedBytes: fallbackExpectedBytes,
                    onEvent: onEvent,
                    onComplete: { result in
                        switch result {
                        case .success: continuation.resume()
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                )
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = resumeData.map { session.downloadTask(withResumeData: $0) }
                    ?? session.downloadTask(with: url)
                box.set(task, session: session)
                // A cancel that arrived before the task existed.
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the URLSession task so a Swift Task cancellation can reach it.
private nonisolated final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false

    func set(_ task: URLSessionDownloadTask, session: URLSession) {
        lock.lock()
        self.task = task
        self.session = session
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    deinit {
        session?.finishTasksAndInvalidate()
    }
}

// MARK: - Download Delegate

private nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let fallbackExpectedBytes: Int64
    let onEvent: @Sendable (ModelTransferEvent) -> Void
    let onComplete: @Sendable (Result<Void, Error>) -> Void
    private let completionLock = NSLock()
    private var _hasCompleted = false
    private var lastReportedPercent: Int = -1
    private var lastReportedAt = Date.distantPast

    init(destination: URL, fallbackExpectedBytes: Int64,
         onEvent: @escaping @Sendable (ModelTransferEvent) -> Void,
         onComplete: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.fallbackExpectedBytes = fallbackExpectedBytes
        self.onEvent = onEvent
        self.onComplete = onComplete
    }

    /// Returns true exactly once, for whichever completion path gets here first.
    private func claimCompletion() -> Bool {
        completionLock.lock()
        defer { completionLock.unlock() }
        guard !_hasCompleted else { return false }
        _hasCompleted = true
        return true
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // A 404/500 still "finishes" with an error page as the file.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            guard claimCompletion() else { return }
            Logger.error("Model download got HTTP \(http.statusCode)", subsystem: .model)
            onComplete(.failure(URLError(.badServerResponse)))
            session.finishTasksAndInvalidate()
            return
        }
        guard claimCompletion() else { return }
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
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        guard claimCompletion() else { return }
        Logger.error("Download failed: \(error)", subsystem: .model)
        onComplete(.failure(error))
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Servers that send no Content-Length report -1; use the catalogue size instead of
        // producing a negative fraction.
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(fallbackExpectedBytes, totalBytesWritten)
        let percent = Int(Double(totalBytesWritten) / Double(expected) * 100)
        let now = Date()
        // Every 1%, or every half second — bytes and the ETA keep moving between percents.
        guard percent != lastReportedPercent || now.timeIntervalSince(lastReportedAt) >= 0.5 else { return }
        lastReportedPercent = percent
        lastReportedAt = now
        onEvent(.progress(written: totalBytesWritten, expected: expected))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        Logger.info("Download resumed at \(fileOffset) bytes", subsystem: .model)
        onEvent(.progress(written: fileOffset, expected: expectedTotalBytes > 0 ? expectedTotalBytes : fallbackExpectedBytes))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        Logger.info("Model download waiting for network connectivity", subsystem: .model)
        onEvent(.waitingForNetwork)
    }
}

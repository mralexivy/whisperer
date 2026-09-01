import Combine
import Foundation

/// Owns the polish model's lifecycle: is it here, fetch it if not, report where.
///
/// The model is 138 MB and is *not* in the app bundle — shipping it there put the
/// download in the App Store binary, where it cost every user the full size up
/// front and made every build and upload slower. Fetching it on first launch
/// instead means the app is small and starts instantly.
///
/// Startup contract: `start()` returns immediately. Nothing about launch, the menu
/// bar, recording, or transcription waits on this. If the model never arrives the
/// app is exactly as usable as it is today — the editor is an enhancement to
/// polish, not a dependency of it.
@MainActor
final class PolishModelManager: ObservableObject {
    static let shared = PolishModelManager()

    enum Phase: Equatable {
        case notStarted
        case downloading
        case unpacking
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notStarted
    /// 0...1 across download *and* unpack, so the UI needs only one bar.
    @Published private(set) var progress: Double = 0
    /// Bytes on disk of the ciphertext so far, for a "42 of 138 MB" style label.
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0

    /// Where the unpacked model lives once installed, or nil if it is not here yet.
    ///
    /// `nonisolated` because `MMBERTCoreMLRuntime.locate()` is a plain static called from
    /// wherever a runtime is constructed; it only stats the filesystem, so there is no state
    /// to isolate.
    ///
    /// Scans installRoot dynamically so that a background update that installs "v4" is
    /// discovered without a binary change. Returns the lexicographically latest complete
    /// version directory (skipping "staging/", which holds in-progress downloads).
    nonisolated static var installedDirectory: URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: installRoot, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles) else { return nil }
        for dir in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard dir.lastPathComponent != "staging" else { continue }
            let package = dir.appendingPathComponent("MMBERTEditing.mlpackage")
            let compiled = dir.appendingPathComponent("MMBERTEditing.mlmodelc")
            if fm.fileExists(atPath: package.path) || fm.fileExists(atPath: compiled.path) {
                return dir
            }
        }
        return nil
    }

    /// The version string of the currently installed model (e.g. "v3"), or nil.
    nonisolated static var installedVersion: String? { installedDirectory?.lastPathComponent }

    nonisolated var installedDirectory: URL? { Self.installedDirectory }
    nonisolated var isInstalled: Bool { Self.installedDirectory != nil }

    // MARK: - Configuration

    private static let repo = "mralexivy/whisperer-polish"
    private static var baseURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/")!
    }

    /// Unpack is ~0.6 s against a download measured in tens of seconds, so the bar
    /// spends almost all its life in the download leg. Splitting it 97/3 keeps the
    /// last sliver honest instead of letting it sit at 100% during the unpack.
    private static let downloadShare = 0.97

    nonisolated static var installRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Whisperer/PolishModel")
    }

    private var task: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var downloader: ResumableDownload?

    private init() {
        if isInstalled { phase = .ready; progress = 1 }
    }

    // MARK: - Lifecycle

    /// Kick off the fetch if it is needed. Safe to call repeatedly; returns at once.
    /// If a model is already installed, silently checks for a newer version in the background.
    func start() {
        guard task == nil else { return }
        if isInstalled {
            phase = .ready
            progress = 1
            scheduleUpdateCheck()
            return
        }
        phase = .downloading
        task = Task { [weak self] in
            await self?.run()
            await MainActor.run { self?.task = nil }
        }
    }

    /// Silently probe HuggingFace for a newer manifest once per launch, with a short
    /// random jitter so that many users don't hammer the CDN simultaneously.
    private func scheduleUpdateCheck() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            // Jitter: 5–20 s after launch so startup stays snappy.
            let jitter = UInt64.random(in: 5_000_000_000 ..< 20_000_000_000)
            try? await Task.sleep(nanoseconds: jitter)
            await self?.checkForUpdate()
            await MainActor.run { self?.updateTask = nil }
        }
    }

    func cancel() {
        downloader?.cancel()
        task?.cancel()
        updateTask?.cancel()
        task = nil
        updateTask = nil
        downloader = nil
        if !isInstalled {
            phase = .notStarted
            progress = 0
        }
    }

    /// Retry after a failure, keeping whatever partial download survived.
    func retry() {
        guard case .failed = phase else { return }
        phase = .notStarted
        start()
    }

    // MARK: - Work

    private func run() async {
        do {
            let manifest = try await fetchManifest()
            guard manifest.schema <= PolishModelPackage.supportedSchema else {
                throw PolishModelPackage.Failure.unsupportedSchema(manifest.schema)
            }
            totalBytes = manifest.ciphertextBytes

            let staging = Self.installRoot.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging,
                                                    withIntermediateDirectories: true)
            let part = staging.appendingPathComponent("\(manifest.file).part")

            let downloader = ResumableDownload(
                url: Self.baseURL.appendingPathComponent(manifest.file),
                destination: part,
                expectedBytes: manifest.ciphertextBytes)
            self.downloader = downloader

            try await downloader.run { [weak self] written in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadedBytes = written
                    self.progress = Double(written) / Double(manifest.ciphertextBytes)
                        * Self.downloadShare
                }
            }
            try Task.checkCancellation()

            phase = .unpacking
            try await unpack(part: part, staging: staging, manifest: manifest)

            phase = .ready
            progress = 1
            Logger.info("Polish model \(manifest.version) installed", subsystem: .model)

            // The weights just appeared, so any earlier "no weights" verdict is stale. Reset and
            // load now rather than at the next utterance: compiling the package is seconds, and
            // the whole point of downloading at launch is that the first dictation does not wait.
            PolishEditor.reset()
            PolishEditor.prepare()
        } catch is CancellationError {
            Logger.info("Polish model download cancelled", subsystem: .model)
            phase = .notStarted
            progress = 0
        } catch {
            Logger.error("Polish model download failed: \(error)", subsystem: .model)
            phase = .failed(error.localizedDescription)
        }
        downloader = nil
    }

    // MARK: - Background update

    private func checkForUpdate() async {
        do {
            let manifest = try await fetchManifest()
            guard manifest.schema <= PolishModelPackage.supportedSchema else { return }
            guard let current = Self.installedVersion, manifest.version != current else { return }
            Logger.info("Polish model update available: \(current) → \(manifest.version)", subsystem: .model)
            await runUpdate(manifest: manifest, replacingVersion: current)
        } catch {
            // Network unavailable or CDN hiccup — silently skip; we'll try next launch.
            Logger.info("Polish model update check skipped: \(error)", subsystem: .model)
        }
    }

    /// Download and install `manifest` silently while the old version stays live.
    /// On success: atomically swap, delete old directory, reload the editor.
    private func runUpdate(manifest: PolishModelPackage.Manifest, replacingVersion old: String) async {
        do {
            let staging = Self.installRoot.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let part = staging.appendingPathComponent("\(manifest.file).part")

            let updater = ResumableDownload(
                url: Self.baseURL.appendingPathComponent(manifest.file),
                destination: part,
                expectedBytes: manifest.ciphertextBytes)

            try await updater.run { _ in /* no UI progress for background updates */ }
            try Task.checkCancellation()

            try await Task.detached(priority: .utility) {
                let unpacked = staging.appendingPathComponent(manifest.version)
                let final = Self.installRoot.appendingPathComponent(manifest.version)
                try? FileManager.default.removeItem(at: unpacked)
                _ = try PolishModelPackage.install(
                    ciphertextAt: part,
                    manifest: manifest,
                    keyHex: PolishModelKey.hex,
                    destination: unpacked,
                    progress: { _ in },
                    isCancelled: { Task.isCancelled })

                let fm = FileManager.default
                try? fm.removeItem(at: final)
                try fm.createDirectory(at: final.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: unpacked, to: final)
                try? fm.removeItem(at: part)

                // Remove the old version directory now that the new one is live.
                let oldDir = Self.installRoot.appendingPathComponent(old)
                try? fm.removeItem(at: oldDir)
            }.value

            Logger.info("Polish model silently updated to \(manifest.version)", subsystem: .model)
            PolishEditor.reset()
            PolishEditor.prepare()
        } catch is CancellationError {
            // App quit mid-update — the partial .part file survives for next launch's resumable download.
        } catch {
            Logger.warning("Polish model background update failed: \(error)", subsystem: .model)
            // Old version still installed and fully functional — user experiences nothing.
        }
    }

    private func fetchManifest() async throws -> PolishModelPackage.Manifest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("manifest.json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(PolishModelPackage.Manifest.self, from: data)
    }

    /// Unpack off the main actor — it is ~0.6 s of AES and LZFSE, which is short
    /// but not short enough to spend on the thread that draws the menu bar.
    private func unpack(part: URL, staging: URL,
                        manifest: PolishModelPackage.Manifest) async throws {
        let unpacked = staging.appendingPathComponent(manifest.version)
        let final = Self.installRoot.appendingPathComponent(manifest.version)
        let key = PolishModelKey.hex

        try await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: unpacked)
            _ = try PolishModelPackage.install(
                ciphertextAt: part,
                manifest: manifest,
                keyHex: key,
                destination: unpacked,
                progress: { fraction in
                    Task { @MainActor in
                        PolishModelManager.shared.progress =
                            Self.downloadShare + fraction * (1 - Self.downloadShare)
                    }
                },
                isCancelled: { Task.isCancelled })

            // Swap in only once every file has been written and hashed, so a crash
            // mid-unpack leaves the old state rather than a model that looks
            // installed and fails at load.
            let fm = FileManager.default
            try? fm.removeItem(at: final)
            try fm.createDirectory(at: final.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: unpacked, to: final)
            try? fm.removeItem(at: part)
        }.value
    }
}

// MARK: - Resumable download

/// A plain ranged download that appends to a `.part` file.
///
/// `URLSessionDownloadTask` is not used here on purpose: its resume data is opaque,
/// does not survive a relaunch reliably, and it hands back a finished temp file
/// rather than a stream. An explicit `Range:` request against the byte count
/// already on disk resumes across launches, crashes and network drops with no
/// state beyond the partial file itself.
private final class ResumableDownload: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let destination: URL
    private let expectedBytes: Int64

    private var handle: FileHandle?
    private var written: Int64 = 0
    private var onProgress: ((Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private let lock = NSLock()
    private var finished = false
    private var lastReport: Int64 = 0

    init(url: URL, destination: URL, expectedBytes: Int64) {
        self.url = url
        self.destination = destination
        self.expectedBytes = expectedBytes
    }

    func run(onProgress: @escaping (Int64) -> Void) async throws {
        self.onProgress = onProgress

        let fm = FileManager.default
        written = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        if written > expectedBytes {
            // A stale part from an older, larger build. Start over rather than
            // splicing two different artifacts together.
            try? fm.removeItem(at: destination)
            written = 0
        }
        if written == expectedBytes {
            onProgress(written)
            return
        }
        if written == 0 {
            fm.createFile(atPath: destination.path, contents: nil)
        } else {
            Logger.info("Resuming polish model download at \(written) bytes", subsystem: .model)
        }
        handle = try FileHandle(forWritingTo: destination)
        try handle?.seekToEnd()

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if written > 0 {
            request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range")
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true
        continuation = nil
        lock.unlock()

        try? handle?.close()
        handle = nil
        switch result {
        case .success:      cont.resume()
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A server that ignores `Range` answers 200 with the whole file; appending
        // that to a partial download would silently corrupt it.
        if written > 0, (response as? HTTPURLResponse)?.statusCode != 206 {
            Logger.warning("Range request refused, restarting polish model download",
                           subsystem: .model)
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: destination)
            written = 0
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            handle = try? FileHandle(forWritingTo: destination)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle?.write(data)
        written += Int64(data.count)
        // Report at most every 512 KB: a 138 MB download is ~34,000 delegate calls,
        // and hopping to the main actor for each one would cost more than the
        // decrypt does.
        if written - lastReport >= 512 * 1024 || written == expectedBytes {
            lastReport = written
            onProgress?(written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(error))
        } else if written != expectedBytes {
            complete(.failure(PolishModelPackage.Failure.truncated))
        } else {
            onProgress?(written)
            complete(.success(()))
        }
        session.finishTasksAndInvalidate()
    }
}

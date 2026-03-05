//
//  SpeechAnalyzerBridge.swift
//  Whisperer
//
//  TranscriptionBackend implementation using Apple SpeechAnalyzer (macOS 26+)
//

#if canImport(Speech)
import Foundation
import Speech
import AVFoundation

@available(macOS 26.0, *)
nonisolated final class SpeechAnalyzerBridge: TranscriptionBackend {

    private let queue = DispatchQueue(label: "speechanalyzer.transcribe", qos: .userInteractive)
    private var _isShuttingDown = false
    private var _isReady = false

    /// Best audio format for the analyzer (cached after prepare)
    private let analyzerFormat: AVAudioFormat?

    /// Resolved locale from prepare() — guaranteed to be in SpeechTranscriber.supportedLocales
    private let resolvedLocale: Locale

    /// Supported locales snapshot from prepare() — avoids async lookup per transcription
    private let supportedLocalesSnapshot: [Locale]

    /// Audio converter for format conversion (lazy, created on first use)
    private var converter: AVAudioConverter?

    /// Thread-safe cache for model installation status
    private var _modelsInstalledCache = false
    private let _cacheQueue = DispatchQueue(label: "speechanalyzer.cache")

    private init(analyzerFormat: AVAudioFormat?, resolvedLocale: Locale, supportedLocales: [Locale]) {
        self.analyzerFormat = analyzerFormat
        self.resolvedLocale = resolvedLocale
        self.supportedLocalesSnapshot = supportedLocales
        self._isReady = true
    }

    // MARK: - Initialization

    /// Prepare the bridge: check locale support, download model if needed, get best audio format
    static func prepare(
        locale: Locale = .current,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> SpeechAnalyzerBridge {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // Check if locale is supported
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let localeID = locale.identifier(.bcp47)
        let supportedIDs = supportedLocales.map { $0.identifier(.bcp47) }
        let isSupported = supportedIDs.contains(localeID)

        guard isSupported else {
            // Try matching by language code (e.g., "en" → "en-US", "en-IL" → "en-US")
            let languageCode = locale.language.languageCode?.identifier ?? localeID.split(separator: "-").first.map(String.init) ?? localeID
            if let bestMatch = supportedLocales.first(where: { $0.language.languageCode?.identifier == languageCode }) {
                let matchID = bestMatch.identifier(.bcp47)
                Logger.info("SpeechAnalyzer: Locale \(localeID) not supported, using \(matchID) (same language)", subsystem: .transcription)
                return try await prepare(locale: bestMatch, progressHandler: progressHandler)
            }

            // No language match — give up with actionable error
            let available = supportedIDs.sorted().joined(separator: ", ")
            Logger.error("SpeechAnalyzer: No supported locale for language '\(languageCode)'. Available: \(available)", subsystem: .transcription)
            throw SpeechAnalyzerError.localeNotSupported(localeID)
        }

        // Always call assetInstallationRequest to allocate the locale for this transcriber.
        // Even when the model is already installed, this registers the locale with
        // AssetInventory — without it, Apple logs "Cannot use modules with unallocated locales".
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Logger.info("SpeechAnalyzer: Downloading model for locale \(localeID)...", subsystem: .model)
            let progress = downloader.progress
            Task { [weak progress] in
                while let p = progress, !p.isFinished, !p.isCancelled {
                    progressHandler?(p.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try await downloader.downloadAndInstall()
            Logger.info("SpeechAnalyzer: Model downloaded for locale \(localeID)", subsystem: .model)
        } else {
            Logger.debug("SpeechAnalyzer: Model already installed for \(localeID), locale allocated", subsystem: .model)
        }

        // Get the best available audio format
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let bridge = SpeechAnalyzerBridge(analyzerFormat: format, resolvedLocale: locale, supportedLocales: supportedLocales)
        bridge._cacheQueue.sync { bridge._modelsInstalledCache = true }
        Logger.info("SpeechAnalyzer bridge prepared (locale: \(localeID))", subsystem: .model)
        return bridge
    }

    /// Check if models are installed for a given locale
    static func isModelInstalled(for locale: Locale = .current) async -> Bool {
        let installedLocales = await SpeechTranscriber.installedLocales
        let localeID = locale.identifier(.bcp47)
        return installedLocales.map { $0.identifier(.bcp47) }.contains(localeID)
    }

    /// Check if a locale is supported by SpeechAnalyzer
    static func isLocaleSupported(_ locale: Locale) async -> Bool {
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let localeID = locale.identifier(.bcp47)
        return supportedLocales.map { $0.identifier(.bcp47) }.contains(localeID)
    }

    // MARK: - Model Management

    /// Synchronous check for model installation (returns cached value).
    /// Call `refreshModelsExistOnDiskAsync()` first to populate the cache.
    func modelsExistOnDisk() -> Bool {
        _cacheQueue.sync { _modelsInstalledCache }
    }

    /// Async check for model installation, updates the internal cache.
    @discardableResult
    func refreshModelsExistOnDiskAsync() async -> Bool {
        let installedLocales = await SpeechTranscriber.installedLocales
        let currentLocaleID = Locale.current.identifier(.bcp47)
        let isInstalled = installedLocales.map { $0.identifier(.bcp47) }.contains(currentLocaleID)
        _cacheQueue.sync { _modelsInstalledCache = isInstalled }
        Logger.debug("SpeechAnalyzer model installed check: locale=\(currentLocaleID), installed=\(isInstalled)", subsystem: .model)
        return isInstalled
    }

    /// Release reserved locales and reset state
    func clearCache() async {
        let reserved = await AssetInventory.reservedLocales
        for locale in reserved {
            await AssetInventory.release(reservedLocale: locale)
        }
        _cacheQueue.sync { _modelsInstalledCache = false }
        _isReady = false
        Logger.info("SpeechAnalyzer cache cleared, reserved locales released", subsystem: .model)
    }

    // MARK: - TranscriptionBackend

    /// Timeout for the entire transcription pipeline (seconds).
    /// Apple's SpeechAnalyzer should respond in 1-2s for short clips.
    /// 5s gives ample headroom while reducing max "stuck" duration.
    private static let transcriptionTimeout: TimeInterval = 5

    func transcribe(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32
    ) -> String {
        guard !_isShuttingDown else { return "" }
        guard _isReady else {
            Logger.warning("SpeechAnalyzer transcribe called before bridge is ready", subsystem: .transcription)
            return ""
        }
        guard !samples.isEmpty else { return "" }

        let outerSemaphore = DispatchSemaphore(value: 0)
        var result = ""

        queue.async { [weak self] in
            guard let self = self else {
                outerSemaphore.signal()
                return
            }
            result = self.performTranscription(samples: samples, language: language)
            outerSemaphore.signal()
        }

        let timeout = DispatchTime.now() + Self.transcriptionTimeout
        if outerSemaphore.wait(timeout: timeout) == .timedOut {
            Logger.error("SpeechAnalyzer: transcribe() timed out after \(Int(Self.transcriptionTimeout))s", subsystem: .transcription)
            return ""
        }
        return result
    }

    func transcribeAsync(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32,
        completion: @escaping (String) -> Void
    ) {
        guard !_isShuttingDown else {
            completion("")
            return
        }
        guard _isReady else {
            Logger.warning("SpeechAnalyzer transcribeAsync called before bridge is ready", subsystem: .transcription)
            completion("")
            return
        }
        guard !samples.isEmpty else {
            completion("")
            return
        }

        queue.async { [weak self] in
            guard let self = self else {
                completion("")
                return
            }
            let text = self.performTranscription(samples: samples, language: language)
            completion(text)
        }
    }

    func isContextHealthy() -> Bool {
        !_isShuttingDown && _isReady
    }

    func prepareForShutdown() {
        _isShuttingDown = true
        queue.sync { }
    }

    // MARK: - Async Transcription (for use from async contexts)

    /// Direct async transcription — bypasses the sync semaphore chain.
    /// Use this from async contexts (like stopAsync) to avoid cooperative thread pool starvation.
    /// The sync `transcribe()` path blocks a cooperative thread on DispatchSemaphore.wait(),
    /// starving the Task.detached inside performTranscription() that needs a cooperative thread
    /// to run runSpeechAnalyzer(). This method calls runSpeechAnalyzer() directly.
    func transcribeDirectAsync(samples: [Float], language: TranscriptionLanguage) async -> String {
        guard !_isShuttingDown, _isReady, !samples.isEmpty else { return "" }
        do {
            let result = try await runSpeechAnalyzer(samples: samples, language: language)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if !Task.isCancelled {
                Logger.error("SpeechAnalyzer async transcription failed: \(error)", subsystem: .transcription)
            }
            return ""
        }
    }

    // MARK: - Internal

    /// Runs transcription on the GCD queue. Must only be called from `queue`.
    /// Uses Task.detached(priority: .userInitiated) to avoid cooperative thread pool exhaustion
    /// and priority inversion with the userInteractive GCD queue.
    private func performTranscription(samples: [Float], language: TranscriptionLanguage) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            do {
                result = try await self.runSpeechAnalyzer(samples: samples, language: language)
            } catch {
                if !Task.isCancelled {
                    Logger.error("SpeechAnalyzer transcription failed: \(error)", subsystem: .transcription)
                }
            }
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + Self.transcriptionTimeout
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            Logger.error("SpeechAnalyzer: performTranscription timed out after \(Int(Self.transcriptionTimeout))s", subsystem: .transcription)
            return ""
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a TranscriptionLanguage to a supported Apple locale.
    /// Uses the cached supportedLocales snapshot from prepare() — no async needed.
    /// Falls back to resolvedLocale if the language can't be matched.
    private func resolveLocale(for language: TranscriptionLanguage) -> Locale {
        // Auto → use the locale from prepare() (guaranteed supported)
        guard language != .auto, let bareLocale = language.locale else {
            return resolvedLocale
        }

        let bareID = bareLocale.identifier(.bcp47)

        // Exact BCP47 match (e.g., "en-US" if user somehow selected a regional variant)
        if supportedLocalesSnapshot.contains(where: { $0.identifier(.bcp47) == bareID }) {
            return bareLocale
        }

        // Language-code match (e.g., "en" → "en-US", "fr" → "fr-FR")
        let languageCode = bareLocale.language.languageCode?.identifier
            ?? bareID.split(separator: "-").first.map(String.init)
            ?? bareID
        if let bestMatch = supportedLocalesSnapshot.first(where: { $0.language.languageCode?.identifier == languageCode }) {
            let matchID = bestMatch.identifier(.bcp47)
            if matchID != resolvedLocale.identifier(.bcp47) {
                Logger.debug("SpeechAnalyzer: Resolved \(bareID) → \(matchID)", subsystem: .transcription)
            }
            return bestMatch
        }

        // No match — fall back to prepared locale
        Logger.warning("SpeechAnalyzer: Language '\(language.displayName)' (\(bareID)) not supported, using \(resolvedLocale.identifier(.bcp47))", subsystem: .transcription)
        return resolvedLocale
    }

    /// Core async transcription using SpeechAnalyzer.
    /// Follows Apple's required pattern: fresh transcriber per call, results collector
    /// started before analyzer, feed audio, finalize, collect results.
    private func runSpeechAnalyzer(samples: [Float], language: TranscriptionLanguage) async throws -> String {
        // Resolve language to a supported Apple locale (handles bare codes like "en" → "en-US")
        let locale = resolveLocale(for: language)
        Logger.debug("SpeechAnalyzer: Starting transcription (\(samples.count) samples, locale: \(locale.identifier(.bcp47)))", subsystem: .transcription)

        // Create fresh transcriber (Apple requires a new instance per transcription)
        let freshTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // Create input stream
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Create analyzer with the transcriber module
        let analyzer = SpeechAnalyzer(modules: [freshTranscriber])

        // Convert samples to AVAudioPCMBuffer
        guard let buffer = createPCMBuffer(from: samples) else {
            throw SpeechAnalyzerError.bufferCreationFailed
        }

        // Convert to analyzer format if needed, with graceful fallback
        let convertedBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat, targetFormat != buffer.format {
            do {
                convertedBuffer = try convertBuffer(buffer, to: targetFormat)
            } catch {
                Logger.warning("SpeechAnalyzer: Buffer conversion failed, using original format: \(error.localizedDescription)", subsystem: .transcription)
                convertedBuffer = buffer
            }
        } else {
            convertedBuffer = buffer
        }

        // Set up results collector before starting analyzer (Apple's required pattern)
        var finalText = ""
        let resultsTask = Task {
            Logger.debug("SpeechAnalyzer: Results collector started", subsystem: .transcription)
            for try await case let result in freshTranscriber.results {
                let text = String(result.text.characters)
                Logger.debug("SpeechAnalyzer: Result received (isFinal: \(result.isFinal), text: '\(text)')", subsystem: .transcription)
                if result.isFinal {
                    // Accumulate all final results (don't break — multiple finals possible)
                    if !finalText.isEmpty && !text.isEmpty {
                        finalText += " "
                    }
                    finalText += text
                }
            }
            Logger.debug("SpeechAnalyzer: Results collection complete", subsystem: .transcription)
        }

        // Start the analyzer
        Logger.debug("SpeechAnalyzer: Starting analyzer...", subsystem: .transcription)
        try await analyzer.start(inputSequence: inputStream)
        Logger.debug("SpeechAnalyzer: Analyzer started", subsystem: .transcription)

        // Feed audio and signal end of input
        let input = AnalyzerInput(buffer: convertedBuffer)
        inputContinuation.yield(input)
        inputContinuation.finish()
        Logger.debug("SpeechAnalyzer: Audio fed, input finished", subsystem: .transcription)

        // Finalize — process remaining audio and close results stream
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            Logger.debug("SpeechAnalyzer: Analyzer finalized", subsystem: .transcription)
        } catch {
            Logger.warning("SpeechAnalyzer finalize error: \(error.localizedDescription)", subsystem: .transcription)
        }

        // Wait for results with timeout — Apple's results stream can hang indefinitely
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await resultsTask.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(4))
                    resultsTask.cancel()
                    Logger.warning("SpeechAnalyzer: Results collection timed out after 4s", subsystem: .transcription)
                }
                // First to finish wins — cancel the other
                try await group.next()
                group.cancelAll()
            }
        } catch {
            if !Task.isCancelled {
                Logger.warning("SpeechAnalyzer results error: \(error.localizedDescription)", subsystem: .transcription)
            }
        }

        Logger.debug("SpeechAnalyzer: Transcription complete ('\(finalText)')", subsystem: .transcription)
        return finalText
    }

    // MARK: - Audio Helpers

    /// Convert raw [Float] samples (16kHz mono) to AVAudioPCMBuffer
    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channelData = buffer.floatChannelData else { return nil }

        samples.withUnsafeBufferPointer { samplePtr in
            guard let baseAddress = samplePtr.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }

        return buffer
    }

    /// Convert buffer to target format using AVAudioConverter
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        // Short-circuit if formats already match
        guard buffer.format != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }

        guard let converter = converter else {
            throw SpeechAnalyzerError.converterCreationFailed
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledLength.rounded(.up))

        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw SpeechAnalyzerError.bufferCreationFailed
        }

        var nsError: NSError?
        var bufferProcessed = false

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            defer { bufferProcessed = true }
            inputStatusPointer.pointee = bufferProcessed ? .noDataNow : .haveData
            return bufferProcessed ? nil : buffer
        }

        guard status != .error else {
            throw SpeechAnalyzerError.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}

// MARK: - Error Types

@available(macOS 26.0, *)
enum SpeechAnalyzerError: Error, LocalizedError {
    case bufferCreationFailed
    case converterCreationFailed
    case conversionFailed(NSError?)
    case localeNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
            return "Failed to create audio buffer for SpeechAnalyzer"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .conversionFailed(let error):
            return "Audio format conversion failed: \(error?.localizedDescription ?? "unknown")"
        case .localeNotSupported(let locale):
            return "Locale '\(locale)' is not supported by SpeechAnalyzer"
        }
    }
}
#endif

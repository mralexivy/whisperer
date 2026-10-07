//
//  Qwen3ASRBridge.swift
//  Whisperer
//
//  TranscriptionBackend for Qwen3-ASR-1.7B on MLX. One engine serves committed chunks, the
//  stop-path tail and live preview; every inference runs on one serial queue because MLX graph
//  evaluation on a shared model is not re-entrant.
//

import Foundation

/// `@unchecked Sendable`: mutable state is either behind `stateLock` or confined to `queue`.
nonisolated final class Qwen3ASRBridge: TranscriptionBackend, @unchecked Sendable {

    /// Only ever touched on `queue` (and during init/teardown, when the queue is drained).
    private var engine: Qwen3ASREngine?

    private let queue = DispatchQueue(label: "qwen3asr.inference", qos: .userInteractive)
    private let stateLock = SafeLock()

    private var _isShuttingDown = false
    private var _shouldAbort = false
    private var _lastDetectedLanguage: String?
    /// Jobs submitted to `queue` that have not finished (chunks, tail, preview).
    private var _pendingJobs = 0
    /// Bumped by `requestAbort`. Async jobs capture it when queued and skip if it moved, so a
    /// preview queued just before key-up cannot run after the tail's `resetAbort` and delay it.
    private var _abortEpoch = 0
    private var _hasEngine = true
    /// Per-session language ratchet for `.auto` preview passes. A 1 s window is where detection
    /// is weakest (a real session flipped en → nl → en on consecutive passes), so once two passes
    /// in a row agree, later preview passes force that language. Reset by `requestAbort`, which
    /// every stop issues, so the next dictation detects afresh.
    private var _lastPreviewLanguage: String?
    private var _pinnedPreviewLanguage: String?

    private var isShuttingDown: Bool { (try? stateLock.withLock { _isShuttingDown }) ?? true }
    private var shouldAbort: Bool { (try? stateLock.withLock { _shouldAbort }) ?? false }

    var lastDetectedLanguage: String? { try? stateLock.withLock { _lastDetectedLanguage } }

    /// True when no inference is queued or running. The preview loop checks this before
    /// starting a pass: a pass started while another is in flight is superseded before it
    /// completes, so every result would be discarded as stale.
    var isIdle: Bool { ((try? stateLock.withLock { _pendingJobs }) ?? 1) == 0 }

    private var abortEpoch: Int { (try? stateLock.withLock { _abortEpoch }) ?? -1 }

    /// One-line snapshot for `StuckStateDumper`. Reads every field under one lock acquisition,
    /// so the fields are mutually consistent rather than sampled across a wedge.
    var debugStateDescription: String {
        guard let state = try? stateLock.withLock({
            (_pendingJobs, _abortEpoch, _shouldAbort, _isShuttingDown,
             _pinnedPreviewLanguage, _lastPreviewLanguage)
        }) else {
            return "pending=? (stateLock timed out — the lock itself is the stall)"
        }
        return "pending=\(state.0) abortEpoch=\(state.1) aborting=\(state.2) "
            + "shuttingDown=\(state.3) pinnedLang=\(state.4 ?? "-") lastLang=\(state.5 ?? "-")"
    }

    private init(engine: Qwen3ASREngine) {
        self.engine = engine
    }

    // MARK: - Model lifecycle

    static func isModelCached() -> Bool { Qwen3ASREngine.isModelCached() }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await Qwen3ASREngine.download(progress: progress)
    }

    /// Loads weights and compiles kernels. Blocking — call through `ModelWorkQueue.runBlocking`.
    static func loadFromCache() throws -> Qwen3ASRBridge {
        let t0 = CFAbsoluteTimeGetCurrent()
        let engine = try Qwen3ASREngine.load()
        let t1 = CFAbsoluteTimeGetCurrent()
        engine.warmUp()
        let t2 = CFAbsoluteTimeGetCurrent()
        Logger.info(
            String(format: "Qwen3ASR loaded in %.0fms, warm-up %.0fms", (t1 - t0) * 1000, (t2 - t1) * 1000),
            subsystem: .model)
        Logger.step(.modelLoad, .model, ["type": .string("qwen3asr")])
        return Qwen3ASRBridge(engine: engine)
    }

    // MARK: - TranscriptionBackend

    var streamingPolicy: BackendStreamingPolicy {
        BackendStreamingPolicy(
            supportsEagerWordStream: false,
            requiresEagerEngine: false,
            suppressesVADChunking: false,
            // Chunks commit at pauses (~6s) and are forced at 15s, so the preview window —
            // which re-decodes everything since the last commit — never has to slide.
            maxVADChunkDuration: 15.0,
            previewPollInterval: 0.25,
            previewSharesDecodeQueue: true,
            serializesInferenceWithPreview: false,
            previewWindowCap: 15.0
        )
    }

    func requestAbort() {
        try? stateLock.withLock {
            _shouldAbort = true
            _abortEpoch += 1
            _lastPreviewLanguage = nil
            _pinnedPreviewLanguage = nil
        }
        Logger.debug("Qwen3ASRBridge abort requested", subsystem: .transcription)
    }

    func resetAbort() {
        try? stateLock.withLock { _shouldAbort = false }
    }

    func transcribe(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32
    ) -> String {
        guard !isShuttingDown, !shouldAbort, !samples.isEmpty else { return "" }
        let done = DispatchSemaphore(value: 0)
        var text = ""
        enqueue(label: "final") { [weak self] in
            defer { done.signal() }
            text = self?.run(samples: samples, language: language, label: "final") ?? ""
        }
        // Polled rather than one 120 s wait. This is the stop-path tail decode and it blocks the
        // caller's thread; on a long meeting the audio is minutes rather than seconds, so the
        // ceiling is genuinely reachable. `run` already polls `shouldAbort` between tokens and
        // returns early, so once an abort lands the work finishes in tens of milliseconds —
        // waiting the full remaining window for a result that is already "" holds the stop path
        // open for no reason.
        let deadline = Date().addingTimeInterval(Self.transcribeTimeout)
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if isShuttingDown { return "" }
            if Date() >= deadline {
                Logger.error(
                    "Qwen3ASRBridge.transcribe timed out after \(Int(Self.transcribeTimeout))s "
                    + "(\(String(format: "%.1f", Double(samples.count) / 16_000))s of audio)",
                    subsystem: .transcription)
                return ""
            }
        }
        return text
    }

    /// Ceiling on a blocking final decode. Generous: at the ~4x realtime this model sustains it
    /// only binds on an hour of audio or a degenerate repetition loop, both of which are bugs
    /// worth surfacing rather than waiting out.
    private static let transcribeTimeout: TimeInterval = 120

    func transcribeAsync(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32,
        completion: @escaping (String) -> Void
    ) {
        guard !isShuttingDown, !shouldAbort, !samples.isEmpty else { completion(""); return }
        let epoch = abortEpoch
        enqueue(label: "chunk") { [weak self] in
            guard let self, self.abortEpoch == epoch else { completion(""); return }
            completion(self.run(samples: samples, language: language, label: "chunk"))
        }
    }

    /// Live preview. `onPartial` streams the transcript-so-far while tokens are generated;
    /// `completion` delivers the finished pass. Both run on the inference queue.
    func transcribePreviewAsync(
        samples: [Float],
        language: TranscriptionLanguage,
        onPartial: @escaping (String) -> Void,
        completion: @escaping (String) -> Void
    ) {
        guard !isShuttingDown, !shouldAbort, !samples.isEmpty else { completion(""); return }
        let epoch = abortEpoch
        enqueue(label: "preview") { [weak self] in
            guard let self, self.abortEpoch == epoch else { completion(""); return }
            completion(self.run(samples: samples, language: language, label: "preview",
                                onPartial: onPartial))
        }
    }

    func isContextHealthy() -> Bool {
        (try? stateLock.withLock { !_isShuttingDown && _hasEngine }) ?? false
    }

    /// Tears the engine down.
    ///
    /// **Must not be called from `queue`.** The `queue.sync` below would deadlock on itself.
    /// Every call site is off-queue today: `AppState.releaseCurrentBridge`,
    /// `releaseQwen3ASRAsync`, `releaseMeetingASRBridge` and `gracefulShutdown` all run on the
    /// main actor or a detached task, and `shutdownAsync` hops to a global queue first. Keep it
    /// that way — a future caller inside a `transcribe` completion would hang the app on quit
    /// with no log line to explain it.
    func prepareForShutdown() {
        try? stateLock.withLock {
            _isShuttingDown = true
            _shouldAbort = true
            _hasEngine = false
        }
        // Wait for the in-flight token step (≤ tens of ms after abort) so MLX buffers are not
        // released under a running command buffer.
        queue.sync { engine = nil }
        Logger.step(.modelFree, .model, ["type": .string("qwen3asr")])
    }

    func shutdownAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.prepareForShutdown()
                continuation.resume()
            }
        }
    }

    // MARK: - Private

    private func enqueue(label: String, _ work: @escaping () -> Void) {
        try? stateLock.withLock { _pendingJobs += 1 }
        queue.async { [weak self] in
            work()
            try? self?.stateLock.withLock { self?._pendingJobs -= 1 }
        }
    }

    /// Runs on `queue`.
    private func run(
        samples: [Float],
        language: TranscriptionLanguage,
        label: String,
        onPartial: ((String) -> Void)? = nil
    ) -> String {
        guard !isShuttingDown, !shouldAbort, let engine else { return "" }
        // Force the language only when the model knows it; otherwise let it detect.
        var code: String? = language == .auto
            ? nil
            : (Qwen3ASREngine.forcedLanguageTokens[language.rawValue] != nil ? language.rawValue : nil)
        let isPreview = onPartial != nil
        if code == nil, isPreview {
            code = try? stateLock.withLock { _pinnedPreviewLanguage }
        }
        // An unpinned auto-detect preview is shown only if its language matches the previous
        // pass. The first pass sees ~0.5 s of audio and regularly misdetects it (zh/yue on English
        // speech, answering "三。" or "嗯。"), and the live card never retracts a word it has shown —
        // so one bad pass left a stray first character for the whole dictation. Holding it back
        // costs one extra pass (~0.25 s) before the first word and no extra inference.
        let previousPreviewLanguage = try? stateLock.withLock { _lastPreviewLanguage }
        let needsConfirmation = isPreview && code == nil
        func confirmed(_ detected: String?) -> Bool {
            !needsConfirmation || (detected != nil && detected == previousPreviewLanguage)
        }
        do {
            let r = try engine.transcribe(
                samples: samples, languageCode: code,
                onPartial: onPartial.map { publish in
                    { text, detected in if confirmed(detected) { publish(text) } }
                },
                shouldAbort: { [weak self] in self?.shouldAbort ?? true })
            if let detected = r.languageCode {
                try? stateLock.withLock {
                    _lastDetectedLanguage = detected
                    if isPreview, code == nil {
                        if _lastPreviewLanguage == detected { _pinnedPreviewLanguage = detected }
                        _lastPreviewLanguage = detected
                    }
                }
            }
            Logger.debug(
                String(format: "Qwen3ASR %@: %.1fs audio → %d audio tok, %d gen tok | enc %.0fms prefill %.0fms decode %.0fms | lang=%@",
                       label, Double(samples.count) / 16_000, r.audioTokens, r.generatedTokens,
                       r.encodeMs, r.prefillMs, r.decodeMs, r.languageCode ?? "none"),
                subsystem: .transcription)
            if shouldAbort || !confirmed(r.languageCode) { return "" }
            return r.text
        } catch {
            Logger.event(.asrFail, .transcription,
                         ["err": .string(error.localizedDescription)], level: .error)
            return ""
        }
    }
}

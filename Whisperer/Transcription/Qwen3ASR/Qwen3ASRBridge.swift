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
    /// Language the last *committed* decode settled on, carried across recordings.
    ///
    /// Seeds the confirmation gate on a session's first preview pass. Without it that pass has
    /// nothing to compare against, is never confirmed, and is thrown away — so the first word
    /// could not appear before pass 3 (pass 1 discarded, pass 2 becomes the agreement reference,
    /// pass 3 agrees). Measured 2.23 s median to first word.
    ///
    /// Deliberately fed only from `chunk` and `final` passes, never from a preview. Those decode
    /// seconds of audio rather than the ~0.5 s a first preview sees, and short-window detection
    /// is exactly what the gate exists to catch — on one day the preview reported Hebrew 1,227
    /// times on audio the committed chunks read as English 601 times. Seeding from the reliable
    /// side means a user who keeps speaking the same language skips a pass, while a genuine
    /// switch still has to prove itself twice.
    ///
    /// Survives `requestAbort`, unlike the per-session ratchet above: it is a prior, not state.
    private var _committedLanguageMemory: String?
    /// Consecutive committed decodes that read a different language than the preview pin.
    private var _committedPinDisagreements = 0
    /// Preview passes this recording that decoded text but had it suppressed by the gate.
    private var _previewPassesWithheld = 0

    /// Shortest preview window allowed to establish the language pin.
    ///
    /// Detection on a sub-second window is close to a coin flip between acoustically similar
    /// languages, and the pin is sticky for the whole recording, so the two have to be decoupled.
    /// 2 s is where the preview's own detections start agreeing with the committed chunks'.
    private static let minimumPinWindowSeconds: Double = 2.0

    /// Committed decodes that must contradict the pin before it is dropped.
    private static let pinDisagreementsToUnpin = 2

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
        // Warm the shapes the live preview will actually hit, which means the engine needs this
        // bridge's `previewWindowCap`. The bridge does not exist yet — it is built from the
        // warmed engine below — so the value is read off a throwaway policy rather than
        // duplicated as a second constant that could drift from the real one.
        engine.warmUp(previewWindowCap: Self.previewWindowCapForWarmUp)
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
            // Both caps are sized from measured pass cost, not from how much context the model
            // could use. The preview re-decodes everything since the last commit, and that decode
            // is linear in window length — medians over 1,708 passes: 295ms at 0-2s, 598ms at
            // 6-8s, 1044ms at 14-16s. At the old 15s cap the live text lagged in a sawtooth from
            // 0.3s up to 1.9s and snapped back on each commit, which is what "sometimes fast,
            // sometimes slow" actually was.
            //
            // The two caps MUST stay equal. They look independent — `runLivePreviewPass` reads
            // only `previewWindowCap` — but Qwen3 takes the `usesAgreement` branch in
            // `StreamingTranscriber`, which accepts a pass only when it is *longer* than what is
            // already displayed. The window grows until a chunk commits, so a preview cap below
            // the chunk cap makes the window slide once the uncommitted tail passes it; the
            // decoded text then gets shorter, the monotonic guard rejects every pass, and the
            // live text freezes until the next commit. Measured at cap 6 / chunk 8: a ~2 s
            // freeze every cycle, update-gap max 3.06 s against 2.64 s before the change.
            //
            // Shortening the chunk is also not free on its own: it halves how long each preview
            // starvation lasts but doubles how often one happens, because previews and chunks
            // share one serial MLX queue and the `!isIdle` guard skips every poll for the whole
            // chunk decode. 8 s is the point where a chunk decode is ~700 ms — short enough that
            // a single starvation stays inside one poll-and-a-bit.
            maxVADChunkDuration: Self.previewWindowCapForWarmUp,
            previewPollInterval: 0.25,
            previewSharesDecodeQueue: true,
            serializesInferenceWithPreview: false,
            previewWindowCap: Self.previewWindowCapForWarmUp
        )
    }

    /// The single source of truth for both caps above and for what `warmUp` sweeps to.
    ///
    /// One constant rather than three literals because all three have to agree: the two policy
    /// fields must be equal (see the comment above), and the warm-up has to cover the top of the
    /// range or the first pass at the cap pays a cold Metal pipeline compile — measured once at
    /// `enc 3446ms prefill 11511ms`, 15.5 s during which an 18 s recording showed no text.
    static let previewWindowCapForWarmUp: Double = 5.0

    func requestAbort() {
        // A recording that never confirmed a language published nothing at all, and until now
        // that was indistinguishable from silence in the logs. It happens when detection flaps
        // (en → nl → en …): the ratchet never sees two passes agree, `confirmed()` is false on
        // every pass, and the live card stays empty for the whole dictation while the committed
        // chunks transcribe normally. Report it here, where the session's outcome is known.
        let flapped = (try? stateLock.withLock {
            _pinnedPreviewLanguage == nil && _lastPreviewLanguage != nil && _previewPassesWithheld > 2
        }) ?? false
        if flapped {
            let detail = (try? stateLock.withLock {
                "\(_previewPassesWithheld) passes withheld, last detection \(_lastPreviewLanguage ?? "-")"
            }) ?? ""
            Logger.warning(
                "Qwen3ASR preview never confirmed a language — live text stayed empty (\(detail))",
                subsystem: .transcription)
        }
        try? stateLock.withLock {
            _shouldAbort = true
            _abortEpoch += 1
            _lastPreviewLanguage = nil
            _pinnedPreviewLanguage = nil
            _committedPinDisagreements = 0
            _previewPassesWithheld = 0
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
        // The memory-pressure cache trim runs here, after the last decode of a recording, rather
        // than inside `transcribe` after every pass. Nothing the user is waiting on follows the
        // final pass, and the meeting-to-overview model hand-off it protects happens at exactly
        // this point. See `Qwen3ASREngine.releaseCachedBuffers()`.
        // Release the buffer cache after the last decode of a recording, then immediately rebuild
        // the allocator state. Releasing without re-warming simply moved the cost onto the next
        // dictation's first pass — measured 1315 ms against a warm 170 ms, which is what "the
        // first one was slow and the second was fine" looks like from the inside.
        defer {
            if label == "final", engine.releaseCachedBuffers() {
                engine.rewarmAfterCacheRelease()
            }
        }
        // Force the language only when the model knows it; otherwise let it detect.
        var code: String? = language == .auto
            ? nil
            : (Qwen3ASREngine.forcedLanguageTokens[language.rawValue] != nil ? language.rawValue : nil)
        let isPreview = onPartial != nil
        let windowSeconds = Double(samples.count) / 16_000
        if code == nil, isPreview {
            code = try? stateLock.withLock { _pinnedPreviewLanguage }
        }
        // An unpinned auto-detect preview is shown only if its language matches the previous
        // pass. The first pass sees ~0.5 s of audio and regularly misdetects it (zh/yue on English
        // speech, answering "三。" or "嗯。"), and the live card never retracts a word it has shown —
        // so one bad pass left a stray first character for the whole dictation. Holding it back
        // costs one extra pass (~0.25 s) before the first word and no extra inference.
        //
        // On the session's first pass there is no previous pass, so the comparison falls back to
        // the language the last committed decode settled on. See `_committedLanguageMemory`.
        let previousPreviewLanguage = try? stateLock.withLock {
            _lastPreviewLanguage ?? _committedLanguageMemory
        }
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
                        // Pin only from a window long enough for detection to mean something.
                        //
                        // The old rule was "two consecutive passes agree", with no length
                        // requirement, and the first two passes of a recording see 0.35-0.65 s
                        // each. Two short windows that agree on the wrong language are not rare;
                        // they are the common failure. Because `_pinnedPreviewLanguage` then
                        // forces the decode for the rest of the recording and is cleared only by
                        // `requestAbort`, one bad pair poisoned an entire dictation: on 2026-10-07
                        // the preview reported Hebrew 1,227 times against English 496, while the
                        // committed chunks on the *same audio* read English 601 to Hebrew 146.
                        if _lastPreviewLanguage == detected,
                           windowSeconds >= Self.minimumPinWindowSeconds {
                            _pinnedPreviewLanguage = detected
                        }
                        _lastPreviewLanguage = detected
                    } else if !isPreview {
                        // Committed decode: seconds of audio, not the ~0.5 s a first preview
                        // sees. This is the reliable signal, so it is the one that becomes the
                        // prior for the next recording's first pass.
                        _committedLanguageMemory = detected

                        // It is also the arbiter for a pin that has gone wrong. A pinned preview
                        // takes the forced-token branch and stops detecting entirely, so it can
                        // never correct itself — the only outside evidence is a committed chunk
                        // reading the same audio differently. Two in a row rather than one,
                        // because a single chunk landing on a genuinely code-switched sentence
                        // is not evidence the pin is wrong.
                        if let pinned = _pinnedPreviewLanguage, pinned != detected {
                            _committedPinDisagreements += 1
                            if _committedPinDisagreements >= Self.pinDisagreementsToUnpin {
                                Logger.warning(
                                    "Qwen3ASR preview language unpinned: \(pinned) contradicted by "
                                    + "\(_committedPinDisagreements) committed decodes reading \(detected)",
                                    subsystem: .transcription)
                                _pinnedPreviewLanguage = nil
                                _lastPreviewLanguage = detected
                                _committedPinDisagreements = 0
                            }
                        } else {
                            _committedPinDisagreements = 0
                        }
                    }
                }
            }
            Logger.debug(
                String(format: "Qwen3ASR %@: %.1fs audio → %d audio tok, %d gen tok | enc %.0fms prefill %.0fms decode %.0fms | lang=%@",
                       label, Double(samples.count) / 16_000, r.audioTokens, r.generatedTokens,
                       r.encodeMs, r.prefillMs, r.decodeMs, r.languageCode ?? "none"),
                subsystem: .transcription)
            if shouldAbort { return "" }
            if !confirmed(r.languageCode) {
                // Counted so `requestAbort` can tell "the gate suppressed everything" apart from
                // "the user said nothing". Only non-empty results count: an empty decode was
                // withholding nothing.
                if isPreview, !r.text.isEmpty {
                    try? stateLock.withLock { _previewPassesWithheld += 1 }
                }
                return ""
            }
            return r.text
        } catch {
            Logger.event(.asrFail, .transcription,
                         ["err": .string(error.localizedDescription)], level: .error)
            return ""
        }
    }
}

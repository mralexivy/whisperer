//
//  StreamingTranscriber.swift
//  Whisperer
//
//  VAD-chunked transcription pipeline. VAD pre-segments audio into speech regions,
//  merges into bounded chunks (~20s), transcribes each chunk exactly once, stitches results.
//  Replaces the O(n²) re-transcription-of-everything approach.
//

import Foundation
import AVFoundation
import Accelerate

// MARK: - NemotronPartialCounter

/// Thread-safe counter + deduplicator for Nemotron partial callbacks.
/// FluidAudio sometimes fires the callback twice for the same chunk (same text, ~1ms apart).
/// Uses a class so @Sendable closures can capture it without mutation warnings.
final class NemotronPartialCounter: @unchecked Sendable {
    private var _count = 0
    private var _lastText = ""
    private let lock = NSLock()

    /// Returns the new count if text is genuinely new, or nil if it's a duplicate.
    func incrementIfNew(_ text: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard text != _lastText else { return nil }
        _count += 1
        _lastText = text
        return _count
    }
}

// MARK: - NullTranscriptionBackend

/// Placeholder backend for the Nemotron path. Nemotron bypasses all TranscriptionBackend
/// calls — this struct satisfies the non-optional init requirement without doing any work.
final class NullTranscriptionBackend: TranscriptionBackend {
    func transcribe(samples: [Float], initialPrompt: String?, language: TranscriptionLanguage,
                    singleSegment: Bool, maxTokens: Int32) -> String { "" }
    func transcribeAsync(samples: [Float], initialPrompt: String?, language: TranscriptionLanguage,
                         singleSegment: Bool, maxTokens: Int32,
                         completion: @escaping (String) -> Void) { completion("") }
    func isContextHealthy() -> Bool { false }
    func prepareForShutdown() { }
}

// MARK: - TranscriptChunk

/// A committed piece of transcript together with the span of audio it covers.
///
/// `start`/`end` are seconds from the beginning of the recording measured on the **audio
/// clock** (`samplesReceived / sampleRate`), not wall-clock. Inference latency, model
/// promotion stalls and UI hitches therefore never skew them, and the gap between one
/// chunk's `end` and the next chunk's `start` is real silence for VAD-segmented backends.
struct TranscriptChunk {
    let text: String
    let start: Double
    let end: Double
    /// Total audio received when this chunk committed — for callers that need the session
    /// length rather than this chunk's own span.
    let recordedDuration: Double
}

// MARK: - StreamingTranscriber

class StreamingTranscriber {
    private var whisper: TranscriptionBackend

    private let sampleRate: Double = 16000.0

    // Feedback sound window — skip initial samples containing start sound
    // Sound plays at T=0, lasts ~100ms. Use 150ms margin for safety.
    private let feedbackSoundDuration: Double = 0.15  // 150ms
    private var feedbackSoundSamples: Int { Int(feedbackSoundDuration * sampleRate) }  // 2400 samples

    // Total samples ever received (monotonic counter — survives ring pruning)
    private var totalSamplesReceived: Int = 0

    // HealthReportable progress counter
    private(set) var transcriptionProgressCounter: UInt64 = 0
    private var stCurrentOp: String? = nil
    private var stOpStart: ContinuousClock.Instant = .now
    private var stOpDeadline: ContinuousClock.Instant = .now
    private var stOpID: UInt64 = 0

    // Ring buffer — holds recent audio only; pruned after each chunk to bound memory.
    // baseSampleIndex tracks absolute offset so all other indices remain absolute/monotonic.
    private struct RingBuffer {
        private var storage: [Float] = []
        private(set) var baseSampleIndex: Int = 0

        mutating func reset() { storage.removeAll(keepingCapacity: true); baseSampleIndex = 0 }
        mutating func append(_ s: [Float]) { storage.append(contentsOf: s) }
        mutating func dropFront(toAbsoluteIndex idx: Int) {
            let drop = max(0, idx - baseSampleIndex)
            guard drop > 0, drop <= storage.count else { return }
            storage.removeFirst(drop)
            baseSampleIndex += drop
        }
        func slice(fromAbsolute start: Int, toAbsolute end: Int) -> [Float] {
            let s = max(0, start - baseSampleIndex)
            let e = min(storage.count, end - baseSampleIndex)
            guard s < e else { return [] }
            return Array(storage[s..<e])
        }
        func toArray() -> [Float] { storage }
        var endAbsoluteIndex: Int { baseSampleIndex + storage.count }
        var inMemoryCount: Int { storage.count }
    }

    private var ring = RingBuffer()
    private let allSamplesLock = SafeLock()

    // VAD-chunked pipeline state
    private let vad: SileroVAD?  // Separate ref for language detection filtering
    private var vadSegmenter: VADSegmenter
    private var lastVADScanIndex: Int = 0
    private var lastTranscribedSampleIndex: Int = 0
    private var lastClaimedSampleIndex: Int = 0
    private var completedChunkTexts: [String] = []
    private var currentChunkLiveText: String = ""
    // WhisperKit snapshot path: each progress callback replaces this (never appended)
    private var provisionalChunkText: String = ""
    private var currentChunkGeneration: UInt64 = 0
    private var pendingChunks: [VADSegmenter.AudioChunk] = []
    private var isTranscribingChunk: Bool = false

    // Thread-safe processing flag
    private let processingLock = SafeLock()
    private var _isProcessing = false
    var isProcessing: Bool {
        get {
            do {
                return try processingLock.withLock(timeout: 1.0) { _isProcessing }
            } catch {
                Logger.error("Failed to get isProcessing: \(error.localizedDescription)", subsystem: .transcription)
                return false
            }
        }
        set {
            do {
                try processingLock.withLock(timeout: 1.0) { _isProcessing = newValue }
            } catch {
                Logger.error("Failed to set isProcessing: \(error.localizedDescription)", subsystem: .transcription)
            }
        }
    }

    /// Admission control for eager passes: exactly one may be outstanding.
    ///
    /// `isProcessing` cannot do this job. Reading it and later setting it are two separate
    /// locked operations, and `runEagerStreamPass` does real work between them — copying the
    /// ring, running VAD over the whole window, normalising. Two callers reach that function
    /// concurrently by design (the 150 ms heartbeat and the completion callback's
    /// self-schedule), so both can observe `false` and both submit.
    ///
    /// Nothing drains the resulting backlog, so the error accumulates for the whole recording.
    /// Measured on real recordings at a real-time feed: a 204s dictation reported a p50 pass
    /// latency of 12.2s and a max of 28.5s on a window capped at 8s — arithmetically impossible
    /// as decode time (155 passes × 12s ≫ 204s), because most of it was queue wait. The decode
    /// itself never stopped costing ~1.4s. The live preview ran 179s behind the speaker and the
    /// recording ended with no text at all.
    ///
    /// So the claim has to be taken atomically, before any of that work, and released on every
    /// path out — including the early returns.
    private let eagerPassLock = NSLock()
    private var eagerPassInFlight = false

    /// Incremental VAD gate state for the eager window.
    ///
    /// The gate asks "is there speech anywhere in the unconfirmed window", and the obvious
    /// implementation — scan the window every tick — is quadratic in the worst case and pays that
    /// worst case exactly when it hurts most. `hasSpeech` can return as soon as it finds a voiced
    /// frame, so a window full of speech is cheap; a window that is mostly silence has to be
    /// scanned to the end. That window is also the one pinned at the cap, because a boundary that
    /// is not advancing is what let it grow there.
    ///
    /// Measured on `05011586` (204s, silence-heavy): the 150 ms heartbeat was actually ticking
    /// every 565 ms — the scan was eating two ticks in three — and the recording produced 38
    /// passes and 10 committed words in three and a half minutes, lagging live audio by 40s.
    /// A dense-speech recording of the same length ticked at 140 ms as intended.
    ///
    /// So scan each sample once. The window's head only moves when a decode advances the
    /// boundary, and everything before `scannedEnd` has already been examined, so a tick need
    /// only look at the audio that arrived since the last one. A window already known to contain
    /// speech needs no scan at all.
    private var eagerVADWindowStart = -1
    private var eagerVADScannedEnd = 0
    private var eagerVADFoundSpeech = false

    /// - Parameter samples: the window, starting at absolute index `start`.
    private func eagerWindowHasSpeech(_ samples: [Float], start: Int, end: Int, vad: SileroVAD) -> Bool {
        if start != eagerVADWindowStart {
            eagerVADWindowStart = start
            eagerVADScannedEnd = start
            eagerVADFoundSpeech = false
        }
        if !eagerVADFoundSpeech {
            let offset = max(0, eagerVADScannedEnd - start)
            if offset < samples.count {
                eagerVADFoundSpeech = vad.hasSpeech(samples: Array(samples[offset...]))
            }
        }
        eagerVADScannedEnd = max(eagerVADScannedEnd, end)
        return eagerVADFoundSpeech
    }

    private func claimEagerPass() -> Bool {
        eagerPassLock.lock(); defer { eagerPassLock.unlock() }
        if eagerPassInFlight { return false }
        eagerPassInFlight = true
        return true
    }

    private func releaseEagerPass() {
        eagerPassLock.lock(); eagerPassInFlight = false; eagerPassLock.unlock()
    }

    private var onTranscription: ((String) -> Void)?
    // Fires with ONLY the live preview tail (previewAccumulatedText), not the full accumulated display.
    // Used by MeetingSession to avoid echoing already-committed chunk text.
    var onPreviewTail: ((String) -> Void)?
    var onLanguageDetected: ((TranscriptionLanguage) -> Void)?
    // Fires when the active model has no prompt for the selected language, so transcription runs
    // unforced. Reported by closure rather than read from AppState — services never reach back.
    var onLanguageForcingUnavailable: ((TranscriptionLanguage) -> Void)?

    // Thread-safe transcription state
    private let transcriptionLock = SafeLock()
    private var _fullTranscription: String = ""
    private var fullTranscription: String {
        get {
            do {
                return try transcriptionLock.withLock(timeout: 1.0) { _fullTranscription }
            } catch {
                Logger.error("Failed to get fullTranscription: \(error.localizedDescription)", subsystem: .transcription)
                return ""
            }
        }
        set {
            do {
                try transcriptionLock.withLock(timeout: 1.0) { _fullTranscription = newValue }
            } catch {
                Logger.error("Failed to set fullTranscription: \(error.localizedDescription)", subsystem: .transcription)
            }
        }
    }

    // Language for transcription
    private var language: TranscriptionLanguage

    // Prompt words for whisper.cpp initial_prompt
    private var initialPrompt: String?

    // VAD scan task
    private var vadScanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var isStopped: Bool = false
    private let stopGateLock = NSLock()
    private var _isPreparingToStop: Bool = false
    private var isPreparingToStop: Bool {
        stopGateLock.withLock { _isPreparingToStop }
    }
    // Set to true only after Nemotron beginSession + setPreviewCallback complete.
    // Samples arriving before the session is open are dropped rather than sent to
    // an uninitialised RNNT state machine.
    private var isNemotronSessionReady: Bool = false
    private var lastPreviewedSampleIndex: Int = 0
    private var previewAccumulatedText: String = ""
    private var previewPassID: Int = 0
    /// Word count of the last live string published on the eager path, within the current
    /// soft-commit epoch. Guards live text against shrinking — see `applyEagerOutcome`.
    private var lastPublishedEagerWordCount: Int = 0
    private var latestWhisperKitPreviewText: String = ""
    private var lastPreviewVADCheckEndIndex: Int = 0
    private var latestWhisperKitPreviewStartIndex: Int = 0
    private var latestWhisperKitPreviewEndIndex: Int = 0
    private var latestWhisperKitPreviewAverageLogProbability: Float?
    private var latestWhisperKitPreviewLanguageIsLocked: Bool = false
    private var activeWhisperKitPreviewStartIndex: Int = 0
    private var activeWhisperKitPreviewEndIndex: Int = 0
    private var whisperKitPreviewAnchoredAtTailStart: Bool = false

    #if canImport(WhisperKit)
    private enum WhisperKitInferenceOwner: Equatable {
        case none
        case preview
        case chunk
    }
    private let whisperKitInferenceLock = NSLock()
    private var whisperKitInferenceOwner: WhisperKitInferenceOwner = .none
    #endif

    private var eagerEngine: EagerStreamEngine?

    // Filler word removal (applied in final pass)
    private var fillerWordRemovalEnabled: Bool

    // VAD scan interval
    private let vadScanInterval: UInt64 = 500_000_000  // 500ms

    // MARK: - Language Routing

    private var modelPool: ModelPool?
    private var languageRouter: LanguageRouter?
    private var modelRouter: ModelRouter?
    private var previewBridge: TranscriptionBackend?  // CPU-only tiny model (WhisperBridge) or streaming backend (FluidAudioBridge) for live preview
    private var routeDecision: ModelRouteDecision?
    private var detectionAttempts: Int = 0
    private var lastDetectionSampleCount: Int = 0
    private var scriptMismatchCount: Int = 0
    private var chunkLangMismatchCount: Int = 0  // Weak signal from whisper_full_lang_id
    private var lastSilenceStart: Date?
    private var newUtteranceAfterSilence: Bool = false

    // Promotion state — serialized via promotionQueue
    private let promotionQueue = DispatchQueue(label: "streaming.promotion")
    private var pendingPromotion: (backend: TranscriptionBackend, profile: ModelProfile)?

    // Nemotron bridge — when set, bypasses VAD chunking, ring buffer, and preview polling.
    // Audio is fed directly; preview fires via push callback; final text via endSession().
    // Holds either NemotronBridge (multilingual) or NemotronHebrewBridge via NemotronBridging protocol.
    #if canImport(FluidAudio)
    private var nemotronBridge: (any NemotronBridging)?
    // Serializes bridge.feed() calls. Each addSamples Task chains onto this, preventing
    // concurrent process(samples:) on the same actor (Swift re-entrancy → heap corruption).
    private var nemotronFeedTask: Task<Void, Never>?
    #endif

    // Session audio file on disk (set by AppState after creation, used for saveRecording and tail)
    var sessionAudioURL: URL?

    /// Fired after each committed chunk (and tail).
    /// Used by AppState to incrementally persist text to CoreData for crash recovery,
    /// and by MeetingSession to place transcript segments on the audio timeline.
    var onChunkCompleted: ((TranscriptChunk) -> Void)?

    /// One eager decode pass, as measured. Exists so pass latency can be *measured against real
    /// recordings* rather than extrapolated from a synthetic benchmark — the mistake that shipped
    /// a window-sized `audio_ctx` tuned on 3–12s windows into a path whose windows are far
    /// longer than that benchmark assumed, where it made the decoder loop. See
    /// `EagerStreamProfileTests`.
    struct EagerPassSample {
        /// Length of the audio window handed to the decoder.
        let windowSeconds: Double
        /// How far this window's end sits behind the audio already captured. Non-zero only when
        /// the window cap bit — the price paid for bounding `windowSeconds`.
        let lagSeconds: Double
        /// Wall-clock from submitting the decode to its completion callback.
        let decodeMs: Double
        /// Wall-clock since the previous pass completed — the live-preview cadence.
        let sinceLastPassMs: Double
        /// Words in the raw hypothesis. Whether any of them reached the screen is a separate
        /// question — the test correlates this against the `onTranscription` display sequence.
        let wordCount: Int
        let averageLogProbability: Float
    }

    /// Test-only probe. nil in the app, so this costs one optional check per pass.
    var onEagerPassMeasured: ((EagerPassSample) -> Void)?
    private var lastEagerPassCompletedAt: CFAbsoluteTime?

    /// Why a scheduled eager pass decided not to decode.
    ///
    /// Every one of these is a *permanent* stall risk once the window is capped: the window is
    /// `[agreementStartIndex, +cap]`, and `agreementStartIndex` only ever advances inside
    /// `EagerStreamEngine.consume`. A pass that returns before decoding therefore leaves the next
    /// pass looking at byte-identical audio, and the heartbeat re-runs the same decision every
    /// 150 ms forever. Before the cap existed the window ran to the live edge and so changed on
    /// every tick, which hid this entirely.
    enum EagerPassSkip: String {
        case notEagerBackend
        case stopped
        /// A decode is already in flight.
        case busy
        case lockTimeout
        /// Fewer than 0.5 s of unconfirmed audio.
        case tooShort
        /// No speech anywhere in the unconfirmed window, and the window reached the live edge —
        /// everything spoken so far has been decoded and the speaker is not talking.
        case silent
        /// The window was capped and held nothing but silence; the boundary was seeked past it.
        /// Unlike the others this one is self-clearing, because the next window is new audio.
        case silentBacklog
    }

    /// Test-only probe, paired with `onEagerPassMeasured`. nil in the app.
    var onEagerPassSkipped: ((EagerPassSkip) -> Void)?

    /// Test-only probe for passes that decoded and were then discarded by the anchor/retraction
    /// guard. Distinct from `onEagerPassSkipped`, which fires for passes that never decoded at
    /// all — a hold has already paid the full GPU cost and additionally leaves the agreement
    /// boundary where it was, so the next pass re-decodes nearly the same window.
    var onEagerPassHeld: ((EagerHoldReason) -> Void)?

    /// Test-only probe: a pass whose leading words repeated the accounted-for tail and were
    /// dropped. Counts how often the seam re-decode overlaps; see
    /// `EagerStreamEngine.confirmedTailOverlap`, which now filters rather than only reporting.
    var onEagerRepeatedConfirmedTail: (() -> Void)?

    /// Effective language for transcription — driven by router or fallback to configured language
    var effectiveLanguage: TranscriptionLanguage {
        routeDecision?.lang ?? language
    }

    /// Whether this session drives the eager-agreement engine instead of VAD chunking plus a
    /// separate tiny preview model.
    ///
    /// Reads the `whisperCppEagerStreaming` rollback flag, **defaulting to on** when the key is
    /// absent — which is every real install, so shipping behaviour is the eager path exactly as
    /// before. The flag is not dead weight left over from the rollout: `EagerStreamRegressionTests`
    /// is an A/B in a single run and sets this key to produce its baseline arm. While this property
    /// was a bare `whisper is WhisperBridge`, that gate ran the eager path in *both* arms and
    /// compared it to itself — all ten fixtures reported `baseline=0.125 eager=0.125` and the three
    /// accuracy gates could not fail by construction. Its structural invariants still meant
    /// something; its comparisons did not.
    ///
    /// Resolved once in `init` rather than per read. Two reasons, and both rule out `lazy var`:
    /// a flag that changed halfway through a recording would switch pipelines mid-stream, which is
    /// the one behaviour neither path is written to survive; and this is read from the heartbeat's
    /// detached task, where a `lazy` read is a *mutating* access to main-actor state and a
    /// `let` of a `Sendable` type is not.
    private let usesEagerStream: Bool

    /// Longest audio window a single eager pass will decode.
    ///
    /// Set from measurement, not intuition — `EagerStreamProfileTests`, 536 passes over 12 real
    /// recordings fed at wall-clock real time. Pass latency is flat in window length across the
    /// whole capped range: p50 1350 ms at 0.5–1s, 1358 at 2–4s, 1366 at 4–6s, 1381 at 6–8s,
    /// 1341 at the cap itself, with a corpus max of 1888 ms. The decoder dominates, the encoder
    /// is noise, and so the cap costs nothing in latency while buying the most context per pass.
    /// See `runEagerStreamPass` for why a cap is needed at all.
    ///
    /// Two earlier versions of this comment quoted a curve that broke sharply above 8s. That
    /// curve came from a harness feeding audio at 8.5× real time, which let the decoder fall
    /// arbitrarily far behind and then attributed the resulting queue wait to window length. The
    /// break was queue backlog, not decode cost, and it disappeared entirely once admission
    /// control landed. `EagerStreamWindowSweepTests` re-elects this value against real
    /// recordings; the number above is only defensible for as long as that sweep keeps picking it.
    ///
    /// **Re-elected at 12s** by that sweep: 7 validated recordings × caps {4, 6, 8, 12, ∞} at
    /// real-time feed, with the uncapped arm measured twice as a noise floor.
    ///
    /// | cap | p50 ms | mean lag | worst lag | worst pass | mean WER |
    /// |-----|--------|----------|-----------|------------|----------|
    /// | 4   | 1563   | 4.4s     | 9.4s      | 2158 ms    | 0.206    |
    /// | 6   | 1576   | 0.6s     | 4.6s      | 1740 ms    | 0.186    |
    /// | 8   | 1498   | 0.1s     | 2.6s      | 1722 ms    | 0.181    |
    /// | 12  | 1357   | 0.0s     | 1.6s      | 1723 ms    | 0.198    |
    /// | ∞   | 1411   | 0.0s     | 0.0s      | 3433 ms    | 0.215    |
    ///
    /// Read it by what the numbers can and cannot resolve. **p50 cannot**: the uncapped arm
    /// repeated at 1411 and 1409, but cap 12 measured 1340 in one repeat and 1548 in the other,
    /// so the ~200 ms spread between caps is machine state, not window length. That is the
    /// expected result — with the ANE encoder the mel is padded to a fixed 30s whatever the
    /// window, so shrinking the window only removes decoder tokens. **WER cannot either**: the
    /// same fixture scored 0.136 and 0.245 across the two identical uncapped runs.
    ///
    /// What is monotonic, and therefore what decides it, is **lag** — how far behind live audio
    /// the decode ran. Small caps do not make passes faster, they make each pass cover less, and
    /// the window falls behind: 4.4s mean and 9.4s worst at cap 4. That is live text seconds
    /// stale on a long recording, and WER on the final text cannot see it.
    ///
    /// 12 rather than ∞ because the mean window is only 4.4s even uncapped (the agreement
    /// boundary keeps it short), so the cap almost never binds — but when it does, it is the
    /// pathological case: the uncapped arm's worst single pass was 3433 ms against 1723 ms at
    /// cap 12. It buys the tail bound for no measurable cost. 12 rather than 8 because 8 still
    /// showed 2.6s of worst-case lag with no latency advantage to pay for it.
    static let defaultEagerMaxWindowSeconds: Double = 12.0

    /// Settable so `EagerStreamWindowSweepTests` can sweep it against real recordings — the
    /// value above is only defensible for as long as a sweep keeps electing it. Nothing in the
    /// app writes to it.
    var eagerMaxWindowSeconds: Double = StreamingTranscriber.defaultEagerMaxWindowSeconds

    /// How far *before* the agreement boundary each window starts.
    ///
    /// The boundary is the reported onset of the first unconfirmed word, and cutting the audio
    /// exactly there cuts that word in half: whisper's word onsets are approximate, and a few tens
    /// of milliseconds late is enough to remove the consonant the decoder needs. The word is then
    /// lost outright, because no later window ever starts before the boundary either. Traced on
    /// `13B50271`: `confirmed: "I don't know if"` with `display: "…if you know"`, then the next
    /// window opened at "you"'s onset and came back "know, but data science" — "you" is absent
    /// from the final text.
    ///
    /// **Off (0) pending a real A/B, and it should stay off until one runs.** It was set to 0.2
    /// on the strength of that one traced anecdote and never measured — it was *baseline* in the
    /// run that condemned `EagerStreamEngine.boundaryTrailSamples` (corpus mean 0.109 was the
    /// margin-on arm), so its own contribution has never been isolated. Meanwhile it is the same
    /// act rule 25 in `docs/knowledge/transcription/rules.md` prohibits on measured evidence —
    /// re-presenting seam audio to the decoder — and escaped that rule only by having a different
    /// name.
    ///
    /// The claim that used to sit here, that "the re-decoded words are dropped again by
    /// `EagerStreamEngine.confirmedTailOverlap`, so the margin costs decode time, not
    /// duplicates", is false in both halves. `confirmedTailOverlap` drops a run-up word only on
    /// an **exact** normalized text match, and the whole premise of the margin is that whisper
    /// renders the re-cut seam *differently*. When it does — "want" coming back as "wanna" — the
    /// word is not dropped, `commonPrefixCount` against the previous hypothesis collapses to 0,
    /// the anchor guard holds the pass and a completed GPU decode is discarded; and because the
    /// held pass still stores the polluted hypothesis, the following pass agrees with itself and
    /// **confirms the duplicate**. Cost: a wasted decode *and* the duplicated boundary word the
    /// docstring promised could not happen.
    ///
    /// The A/B that would settle it is three arms — 0.2, 0 with the `endIndex` entry filter, 0
    /// with the `startIndex` filter — on the golden-set gate, reported with
    /// `unanchoredAfterBoundaryMove` hold counts alongside WER.
    var eagerSeamMarginSeconds: Double = 0.2

    /// Whether live text includes the speculative hypothesis tail, or only confirmed words.
    ///
    /// The tail is one pass ahead — roughly 1.4s of extra responsiveness — and it is the only
    /// part of the string the decoder is still allowed to rewrite. Publishing it is why live text
    /// is not append-only in practice: `EagerStreamProfileTests` counted 138 revisions across 12
    /// real recordings, up to 41 on a single one.
    ///
    /// A word-count floor already blocks the tail from making the text *shorter*
    /// (`lastPublishedEagerWordCount`), but that cannot see a same-length rewrite, which is the
    /// common case. Only dropping the tail removes the class.
    ///
    /// Left settable rather than decided here because the trade is responsiveness against
    /// stability and both sides are measurable. The profile runs it both ways.
    var eagerPublishesSpeculativeTail: Bool = true

    /// See `EagerStreamEngine.Config.skipsAnchorCheckAfterBoundaryMove`. Must be set before
    /// `start()`, which is where the engine is built.
    var eagerSkipsAnchorCheckAfterBoundaryMove: Bool = false

    /// See `EagerStreamEngine.Config.suppressesRepetitionLoops`. Must be set before `start()`,
    /// which is where the engine is built.
    var eagerSuppressesRepetitionLoops: Bool = true

    /// Initialize with a pre-loaded backend
    init(
        backend: TranscriptionBackend,
        vad: SileroVAD? = nil,
        language: TranscriptionLanguage = .english,
        initialPrompt: String? = nil,
        fillerWordRemovalEnabled: Bool = false,
        firstRetranscriptionDelay: UInt64 = 1_000_000_000,
        retranscriptionInterval: UInt64 = 1_500_000_000,
        modelPool: ModelPool? = nil,
        languageRouter: LanguageRouter? = nil,
        modelRouter: ModelRouter? = nil,
        previewBridge: TranscriptionBackend? = nil,
        nemotronBridge: (any AnyObject)? = nil,  // NemotronBridge — typed as AnyObject to avoid #if at call sites
        eagerStreamOverride: Bool? = nil
    ) {
        self.whisper = backend
        self.usesEagerStream = {
            guard backend is WhisperBridge else { return false }
            // Tests pass the arm explicitly. They must NOT write the rollback flag to
            // `UserDefaults.standard`, because the test host shares the shipping app's
            // preferences domain: a gate run that was killed or crashed mid-fixture left
            // `whisperCppEagerStreaming = 0` behind, and the app then launched with the eager
            // path off *and* no tiny preview bridge (see `AppState.livePreviewBridge`) — live
            // preview dead, with nothing in the log to say why.
            if let eagerStreamOverride { return eagerStreamOverride }
            let key = "whisperCppEagerStreaming"
            guard UserDefaults.standard.object(forKey: key) != nil else { return true }
            return UserDefaults.standard.bool(forKey: key)
        }()
        self.vad = vad
        self.language = language
        self.initialPrompt = initialPrompt
        self.fillerWordRemovalEnabled = fillerWordRemovalEnabled
        self.modelPool = modelPool
        self.languageRouter = languageRouter
        self.previewBridge = previewBridge
        self.modelRouter = modelRouter
        #if canImport(WhisperKit)
        let maxChunkDuration = backend is WhisperKitBridge ? 6.0 : 10.0
        #else
        let maxChunkDuration = 10.0
        #endif
        self.vadSegmenter = VADSegmenter(
            vad: vad,
            targetChunkDuration: 6.0,
            silenceForFinalization: 0.5,
            maxChunkDuration: maxChunkDuration
        )
        #if canImport(FluidAudio)
        self.nemotronBridge = nemotronBridge as? any NemotronBridging
        #endif
    }

    /// Start streaming transcription with VAD-chunked pipeline
    func start(onTranscription: @escaping (String) -> Void) {
        self.onTranscription = onTranscription

        do {
            try allSamplesLock.withLock {
                ring.reset()
            }
        } catch {
            Logger.error("Failed to acquire lock in start(): \(error.localizedDescription)", subsystem: .transcription)
        }

        totalSamplesReceived = 0
        fullTranscription = ""
        isProcessing = false
        isStopped = false
        stopGateLock.withLock { _isPreparingToStop = false }
        isNemotronSessionReady = false
        #if canImport(FluidAudio)
        nemotronFeedTask = nil
        #endif
        routeDecision = nil
        detectionAttempts = 0
        lastDetectionSampleCount = 0
        scriptMismatchCount = 0
        chunkLangMismatchCount = 0
        lastSilenceStart = nil
        newUtteranceAfterSilence = false
        pendingPromotion = nil
        languageRouter?.reset()
        // Start indices after feedback sound window to skip start sound capture
        lastVADScanIndex = feedbackSoundSamples
        lastTranscribedSampleIndex = feedbackSoundSamples
        lastClaimedSampleIndex = feedbackSoundSamples
        completedChunkTexts = []
        currentChunkLiveText = ""
        pendingChunks = []
        isTranscribingChunk = false
        lastPreviewedSampleIndex = feedbackSoundSamples  // Skip feedback sound window
        lastPreviewVADCheckEndIndex = feedbackSoundSamples
        previewAccumulatedText = ""
        previewPassID = 0
        lastPublishedEagerWordCount = 0
        eagerVADWindowStart = -1
        eagerVADScannedEnd = 0
        eagerVADFoundSpeech = false
        latestWhisperKitPreviewText = ""
        latestWhisperKitPreviewStartIndex = 0
        latestWhisperKitPreviewEndIndex = 0
        latestWhisperKitPreviewAverageLogProbability = nil
        latestWhisperKitPreviewLanguageIsLocked = false
        activeWhisperKitPreviewStartIndex = 0
        activeWhisperKitPreviewEndIndex = 0
        whisperKitPreviewAnchoredAtTailStart = false
        #if canImport(WhisperKit)
        whisperKitInferenceLock.lock()
        whisperKitInferenceOwner = .none
        whisperKitInferenceLock.unlock()
        resetWhisperKitStreamingState(at: feedbackSoundSamples)
        #endif

        // Eager engine: used by both WhisperKit (always) and whisper.cpp (when flag on)
        #if canImport(WhisperKit)
        let needsEagerEngine = (whisper is WhisperKitBridge) || usesEagerStream
        #else
        let needsEagerEngine = usesEagerStream
        #endif
        eagerEngine = needsEagerEngine
            ? EagerStreamEngine(config: EagerStreamEngine.Config.default
                .with(skipsAnchorCheckAfterBoundaryMove: eagerSkipsAnchorCheckAfterBoundaryMove,
              suppressesRepetitionLoops: eagerSuppressesRepetitionLoops))
            : nil
        eagerEngine?.reset(at: feedbackSoundSamples)

        // Nemotron path: preview is push-based; no VAD chunking needed.
        #if canImport(FluidAudio)
        if let nemotron = nemotronBridge {
            Task { [weak self] in
                guard let self else { return }
                let lang = self.language
                let partialCounter = NemotronPartialCounter()
                let callback: @Sendable (String) -> Void = { [weak self] accumulatedText in
                    // Guard: empty string means silence/no speech — never reset the live display.
                    guard let self, !accumulatedText.isEmpty else { return }
                    // Deduplicate: FluidAudio sometimes fires the callback twice for the
                    // same chunk result (same text, ~1ms apart). Skip the duplicate.
                    guard partialCounter.incrementIfNew(accumulatedText) != nil else { return }
                    self.previewAccumulatedText = accumulatedText
                    DispatchQueue.main.async {
                        self.onTranscription?(accumulatedText)
                        self.onPreviewTail?(accumulatedText)
                    }
                }
                // Forcing a language the model has no prompt for is a silent no-op inside
                // FluidAudio: setLanguage falls back to the "auto" prompt and the forced-prefix
                // seed is skipped, so the session runs unconditioned while every log line reads
                // like success. Report it instead of pretending the language was applied.
                if let support = await nemotron.forcedLanguageSupport(for: lang), !support.isSupported {
                    Logger.warning("[Nemotron] Model has no prompt for '\(support.code)' (\(lang.displayName)) — transcribing unforced; accuracy will suffer", subsystem: .transcription)
                    DispatchQueue.main.async { [weak self] in
                        self?.onLanguageForcingUnavailable?(lang)
                    }
                }
                await nemotron.beginSession(language: lang)
                await nemotron.setPreviewCallback(callback)
                self.isNemotronSessionReady = true
            }
            return
        }
        #endif

        // Start VAD scan task
        vadScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for initial audio to accumulate
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s

            while !Task.isCancelled {
                guard let self = self, !self.isStopped else { break }
                self.scanAndProcessChunks()
                do {
                    try await Task.sleep(nanoseconds: self.vadScanInterval)
                } catch {
                    break
                }
            }
        }

        // Start preview after language detection resolves (state-machine gate)
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            // The eager stream decodes with `auto-detect` on every pass — whisper.cpp re-detects
            // per window, so it needs no route decision to start. Waiting here would cost up to
            // the full 5s timeout whenever detection stays undecided (three sub-threshold
            // attempts leave routeDecision nil, and the gate then never opens), which reads as a
            // dead live preview for the first five seconds of every recording. The gate exists
            // for the tiny preview model, which must be told a language up front.
            if self?.usesEagerStream != true {
                // Wait for language detection or 5s timeout
                for _ in 0..<50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms poll
                    guard let self, !self.isStopped else { return }
                    if self.routeDecision != nil || self.modelPool == nil ||
                        self.languageRouter == nil || self.modelRouter == nil { break }
                }
            }

            // WhisperKit is a batch decoder. Start the next timestamped pass promptly
            // after completion so there is no extra dead period between hypotheses.
            // 40 ms balances responsiveness against the ~600-700 ms inference budget.
            #if canImport(WhisperKit)
            let previewInterval: UInt64 = self?.previewBridge is WhisperKitBridge
                ? 40_000_000
                : (self?.usesEagerStream == true ? 150_000_000 : 500_000_000)
            #else
            let previewInterval: UInt64 = self?.usesEagerStream == true ? 150_000_000 : 500_000_000
            #endif
            while !Task.isCancelled {
                guard let self, !self.isStopped, !self.isPreparingToStop else { break }
                self.runLivePreviewPass()
                do {
                    try await Task.sleep(nanoseconds: previewInterval)
                } catch {
                    break
                }
            }
        }

        let previewName = previewBridge.map { String(describing: type(of: $0)) } ?? "none"
        Logger.step(.asrStart, .transcription, ["preview": .string(previewName)])
    }

    /// Add audio samples from microphone
    func addSamples(_ samples: [Float]) {
        guard !samples.isEmpty, !isStopped else { return }

        #if canImport(FluidAudio)
        // Nemotron: feed directly, bypass ring buffer. Duration tracking still needs updating.
        if nemotronBridge != nil {
            do {
                try allSamplesLock.withLock { totalSamplesReceived += samples.count }
            } catch {}
            // Drop samples until beginSession + setPreviewCallback have completed.
            // beginSession typically takes 1-8ms while audio engine setup takes 80-200ms,
            // so this guard only triggers if ANE is contended at session start.
            guard isNemotronSessionReady else { return }
            // Chain onto the previous feed task to serialize bridge.feed() calls.
            // Spawning independent Tasks causes concurrent process(samples:) on the same
            // actor (Swift re-entrancy via ANE encoder await) → shared-buffer heap corruption.
            let capturedSamples = samples
            nemotronFeedTask = Task { [weak self, prev = nemotronFeedTask] in
                _ = await prev?.value  // wait for previous feed to finish
                // No isStopped check here — pending tasks must complete their feed()
                // before endSession(). stopAsync() awaits this chain first.
                guard let self else { return }
                await self.nemotronBridge?.feed(samples: capturedSamples)
            }
            return
        }
        #endif

        do {
            try allSamplesLock.withLock {
                ring.append(samples)
                totalSamplesReceived += samples.count
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock: \(error.localizedDescription)", subsystem: .transcription)
        }
    }

    // MARK: - VAD Scan & Chunk Processing

    /// Scan new audio with VAD, emit chunks, transcribe them
    private func scanAndProcessChunks() {
        // Snapshot ring content + base for index mapping
        var ringContent: [Float] = []
        var ringBase: Int = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in scanAndProcessChunks", subsystem: .transcription)
            return
        }

        // Map absolute indices to ring-relative for VADSegmenter (indexes into ringContent)
        let allSamples = ringContent
        guard allSamples.count > Int(0.5 * sampleRate) else { return }

        let fromRel = max(0, lastVADScanIndex - ringBase)
        let claimedRel = max(0, lastClaimedSampleIndex - ringBase)

        // Language detection — detect before first chunk, retry if undecided
        if routeDecision == nil,
           detectionAttempts < RoutingThresholds.maxDetectionAttempts,
           let pool = modelPool, let langRouter = languageRouter, let mdlRouter = modelRouter {
            let targetSamples = RoutingThresholds.targetDetectionSamples
                + (detectionAttempts * RoutingThresholds.retryGrowth)
            // Compare against total received so detection window grows monotonically
            let totalInRing = ringBase + allSamples.count
            if totalInRing >= targetSamples, totalInRing > lastDetectionSampleCount {
                lastDetectionSampleCount = totalInRing
                let windowSize = min(allSamples.count, RoutingThresholds.targetDetectionSamples)
                let wasAttempted = performLanguageDetection(
                    samples: Array(allSamples.suffix(windowSize)),
                    pool: pool,
                    langRouter: langRouter,
                    mdlRouter: mdlRouter
                )
                if wasAttempted { detectionAttempts += 1 }
                if routeDecision == nil {
                    EventRingBuffer.shared.record(
                        component: "StreamingTranscriber",
                        operation: "detectionUndecided",
                        kind: .state,
                        metadata: ["attempt": .int(detectionAttempts), "max": .int(RoutingThresholds.maxDetectionAttempts)]
                    )
                }
            }
        }

        #if canImport(WhisperKit)
        // WhisperKit has one serial Core ML runtime. Its eager word-agreement stream
        // is already the committed path, so scheduling a second VAD chunk decode here
        // would transcribe the same audio twice and stall live preview.
        if whisper is WhisperKitBridge {
            lastVADScanIndex = ringBase + allSamples.count
            return
        }
        #endif

        if usesEagerStream {
            lastVADScanIndex = ringBase + allSamples.count
            return
        }

        // Run VAD scan with ring-relative indices
        let result = vadSegmenter.scanAndEmitChunks(
            allSamples: allSamples,
            fromIndex: fromRel,
            lastTranscribedIndex: claimedRel
        )
        // Rebase newScanIndex back to absolute
        lastVADScanIndex = ringBase + result.newScanIndex

        // Rebase chunk indices to absolute and queue
        if !result.chunks.isEmpty {
            let absoluteChunks = result.chunks.map { chunk in
                VADSegmenter.AudioChunk(
                    startSample: chunk.startSample + ringBase,
                    endSample: chunk.endSample + ringBase,
                    samples: chunk.samples,
                    overlapPrefixSamples: chunk.overlapPrefixSamples
                )
            }
            pendingChunks.append(contentsOf: absoluteChunks)
            if let lastChunk = absoluteChunks.last {
                lastClaimedSampleIndex = max(lastClaimedSampleIndex, lastChunk.endSample)
            }
            EventRingBuffer.shared.record(
                component: "StreamingTranscriber",
                operation: "vadEmitted",
                kind: .progress,
                metadata: ["chunks": .int(result.chunks.count), "pending": .int(pendingChunks.count)]
            )
        }

        // Process next pending chunk if not busy
        processNextChunk()
    }

    /// Transcribe the next pending chunk
    private func processNextChunk() {
        guard !isStopped, !isTranscribingChunk, !pendingChunks.isEmpty else { return }
        guard !usesEagerStream else { return }

        #if canImport(WhisperKit)
        let usesWhisperKit = whisper is WhisperKitBridge
        // Preview and committed-chunk decodes share one WhisperKit runtime. Claim it
        // atomically so Core ML never receives overlapping decoder work.
        if usesWhisperKit, !claimWhisperKitInference(.chunk) { return }
        #endif

        // Check for deferred model promotion at chunk boundary
        drainPromotionQueue()

        let chunk = pendingChunks.removeFirst()
        isTranscribingChunk = true
        isProcessing = true

        let chunkDuration = Double(chunk.endSample - chunk.startSample) / sampleRate
        stOpID &+= 1
        stOpStart = .now
        stOpDeadline = .now + .milliseconds(Int(chunkDuration * 1000.0 * 2))
        stCurrentOp = "processingChunk"
        EventRingBuffer.shared.record(
            component: "StreamingTranscriber",
            operation: "chunkQueued",
            kind: .progress,
            metadata: ["durationSec": .double(chunkDuration), "samples": .int(chunk.samples.count), "backlog": .int(pendingChunks.count)]
        )

        // Context from previous chunk
        let prevText = completedChunkTexts.last
        let prompt: String?
        if let prev = prevText, !prev.isEmpty {
            // Combine user's initial prompt words with context from previous chunk
            var combinedPrompt = ""
            if let ip = initialPrompt, !ip.isEmpty {
                combinedPrompt = ip + " "
            }
            combinedPrompt += String(prev.suffix(100))
            prompt = combinedPrompt
        } else {
            prompt = initialPrompt
        }

        // Reset abort flag on all backends before each chunk
        whisper.resetAbort()

        // Set up live text callback on WhisperBridge if available
        if let bridge = whisper as? WhisperBridge {
            currentChunkLiveText = ""
            bridge.onNewSegment = { [weak self] segmentText in
                guard let self = self else { return }
                self.currentChunkLiveText += (self.currentChunkLiveText.isEmpty ? "" : " ") + segmentText
                self.updateLivePreview()
            }
        }

        // WhisperKit snapshot path: each callback completely replaces provisional text
        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            provisionalChunkText = ""
            if initialPrompt?.isEmpty ?? true {
                currentChunkGeneration &+= 1
                let gen = currentChunkGeneration
                wkBridge.setChunkCallback({ [weak self] snapshot in
                    guard let self else { return }
                    guard snapshot.chunkGeneration == gen else { return }
                    let guarded = self.guardedWhisperKitPrefix(snapshot.text)
                    guard !guarded.isEmpty, !self.isHallucination(guarded),
                          guarded != self.provisionalChunkText else { return }
                    self.provisionalChunkText = guarded
                    self.updateProvisionalPreview()
                }, chunkGeneration: gen)
            } else {
                // The committed decode may use Prompt Words for proper-name accuracy,
                // but its intermediate tokens are prompt-biased and must never reach UI.
                wkBridge.clearCallbacks()
            }
        }
        #endif

        let normalizedSamples = normalizeSamples(chunk.samples)

        whisper.transcribeAsync(
            samples: normalizedSamples,
            initialPrompt: prompt,
            language: effectiveLanguage,
            singleSegment: true
        ) { [weak self] text in
            guard let self = self else { return }

            // Clear live segment callback
            if let bridge = self.whisper as? WhisperBridge {
                bridge.onNewSegment = nil
            }
            #if canImport(WhisperKit)
            if usesWhisperKit {
                (self.whisper as? WhisperKitBridge)?.clearCallbacks()
            }
            #endif

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmed.isEmpty && !self.isHallucination(trimmed) {
                // Post-chunk script stabilizer — check for language mismatches
                self.checkScriptStability(chunkText: trimmed)

                // Weak reinforcement from whisper_full_lang_id (decoder state, not independent detection)
                if let bridge = self.whisper as? WhisperBridge,
                   let detectedCode = bridge.lastDetectedLanguage,
                   let detectedLang = TranscriptionLanguage(rawValue: detectedCode),
                   let langRouter = self.languageRouter,
                   case .locked(let lockedLang) = langRouter.state {
                    if detectedLang != lockedLang {
                        self.chunkLangMismatchCount += 1
                    } else {
                        self.chunkLangMismatchCount = max(0, self.chunkLangMismatchCount - 1)
                    }
                }

                // Deduplicate overlap with previous chunk
                let deduped: String
                if let prevText = self.completedChunkTexts.last, !prevText.isEmpty {
                    deduped = VADSegmenter.deduplicateOverlap(previousText: prevText, newText: trimmed)
                } else {
                    deduped = trimmed
                }

                if !deduped.isEmpty {
                    self.completedChunkTexts.append(deduped)
                    // VAD chunk boundaries are the exact voiced span, so the gap to the
                    // next chunk's start is genuine silence.
                    self.onChunkCompleted?(TranscriptChunk(
                        text: deduped,
                        start: Double(chunk.startSample) / self.sampleRate,
                        end: Double(chunk.endSample) / self.sampleRate,
                        recordedDuration: self.recordedDuration
                    ))
                }
            }

            // Only advance past this chunk when transcription produced text.
            // Empty results (abort or timeout) must NOT advance the index — the tail pass
            // will re-transcribe that audio. This is safe for all backends: Whisper's
            // abort fires with isStopped=true (tail covers it); Parakeet timeouts during
            // recording previously advanced the index incorrectly, losing audio.
            if !trimmed.isEmpty {
                self.lastTranscribedSampleIndex = chunk.endSample
                // Clear preview accumulated text — chunk covers this audio now
                self.previewAccumulatedText = ""
                self.lastPreviewedSampleIndex = chunk.endSample
                self.latestWhisperKitPreviewText = ""
                self.latestWhisperKitPreviewStartIndex = chunk.endSample
                self.latestWhisperKitPreviewEndIndex = chunk.endSample
                self.latestWhisperKitPreviewAverageLogProbability = nil
                self.latestWhisperKitPreviewLanguageIsLocked = false
                self.whisperKitPreviewAnchoredAtTailStart = false
                #if canImport(WhisperKit)
                self.resetWhisperKitStreamingState(at: chunk.endSample)
                #endif
            }
            self.currentChunkLiveText = ""
            self.provisionalChunkText = ""
            self.isTranscribingChunk = false
            self.isProcessing = false
            self.stCurrentOp = nil
            self.transcriptionProgressCounter &+= 1

            // Trim ring: drop samples safely before both transcribed and previewed positions.
            // Keep 1s overlap for chunk boundary quality on next chunk.
            let overlapSamples = Int(1.0 * self.sampleRate)
            let safeDrop = min(self.lastTranscribedSampleIndex, self.lastPreviewedSampleIndex) - overlapSamples
            if safeDrop > 0 {
                do {
                    try self.allSamplesLock.withLock {
                        self.ring.dropFront(toAbsoluteIndex: safeDrop)
                    }
                    EventRingBuffer.shared.record(
                        component: "StreamingTranscriber",
                        operation: "ringTrimmed",
                        kind: .state,
                        metadata: ["inMemory": .int(self.ring.inMemoryCount)]
                    )
                } catch {
                    Logger.error("Failed to trim ring: \(error.localizedDescription)", subsystem: .transcription)
                }
            }

            // Update live preview with completed chunks
            self.updateLivePreview()

            #if canImport(WhisperKit)
            if usesWhisperKit {
                self.releaseWhisperKitInference(.chunk)
            }
            #endif

            // Process next pending chunk
            self.processNextChunk()
        }
    }

    /// Compose live preview from completed chunks + current chunk text
    private func updateLivePreview() {
        var preview = completedChunkTexts.joined(separator: " ")
        if !currentChunkLiveText.isEmpty {
            if !preview.isEmpty { preview += " " }
            preview += currentChunkLiveText
        }

        fullTranscription = preview

        let text = preview
        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(text)
        }
    }

    // WhisperKit snapshot path: provisional text completely replaces (never appended)
    private func updateProvisionalPreview() {
        var display = completedChunkTexts.joined(separator: " ")
        if !provisionalChunkText.isEmpty {
            if !display.isEmpty { display += " " }
            display += provisionalChunkText
        }
        fullTranscription = display
        let text = display
        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(text)
        }
    }

    /// WhisperKit's newest words are frequently revised while the decoder is still
    /// receiving context. Hold back that unstable edge, but publish the older words
    /// from token-progress callbacks so the overlay still advances continuously.
    private func guardedWhisperKitPrefix(_ hypothesis: String) -> String {
        let words = hypothesis.split(whereSeparator: { $0.isWhitespace })
        let unstableWordCount = 2
        guard words.count > unstableWordCount else { return "" }
        return words.dropLast(unstableWordCount).joined(separator: " ")
    }

    private func publishWhisperKitPreview(_ hypothesis: String, through sampleIndex: Int) {
        guard !isStopped else { return }
        let guarded = guardedWhisperKitPrefix(hypothesis)
        guard !guarded.isEmpty, !isHallucination(guarded) else { return }
        guard guarded != previewAccumulatedText else { return }

        previewAccumulatedText = guarded
        lastPreviewedSampleIndex = sampleIndex

        var display = completedChunkTexts.joined(separator: " ")
        if !display.isEmpty { display += " " }
        display += guarded
        fullTranscription = display

        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(display)
            self?.onPreviewTail?(guarded)
        }
        transcriptionProgressCounter &+= 1
    }

    // MARK: - Live Preview Pass

    /// Live preview pass. Two modes depending on backend:
    /// - FluidAudio: growing tail with replace semantics (runs even during chunk transcription — separate queue).
    /// - WhisperKit: growing tail from the last committed chunk with replace semantics.
    /// - whisper.cpp: append-only from last previewed position with 0.5s overlap.
    private func runLivePreviewPass() {
        guard !isStopped, !isPreparingToStop else { return }
        if usesEagerStream {
            runEagerStreamPass()
            return
        }
        guard let preview = previewBridge else { return }
        #if canImport(WhisperKit)
        let isWhisperKitPreview = preview is WhisperKitBridge
        // Avoid repeatedly copying, VAD-checking, and normalizing the same window while
        // the previous Core ML pass is still running.
        if isWhisperKitPreview, !isWhisperKitInferenceIdle() { return }
        #else
        let isWhisperKitPreview = false
        #endif
        #if canImport(FluidAudio)
        let isFluidAudio = preview is FluidAudioBridge
        #else
        let isFluidAudio = false
        #endif
        // Whisper shares the same queue as chunk transcription — block preview during chunks to avoid contention.
        // FluidAudio has a dedicated preview queue and triple-manager, so it can run concurrently.
        if !isFluidAudio, isTranscribingChunk { return }

        // Skip preview if main pipeline has a large backlog (>10s) — drop preview before dropping chunks
        let chunkBacklogSamples = lastClaimedSampleIndex - lastTranscribedSampleIndex
        guard chunkBacklogSamples <= Int(10.0 * sampleRate) else { return }

        var ringContent: [Float] = []
        var ringBase: Int = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch { return }

        let ringEnd = ringBase + ringContent.count

        // Window computation differs by backend:
        // - FluidAudio: growing tail from the last committed chunk, replace semantics, low minimum guard (0.3s).
        // - WhisperKit: re-decode the uncommitted tail and replace the previous snapshot.
        //   This lets provisional words be corrected without appending overlapping rewrites.
        // - whisper.cpp: append from lastPreviewedSampleIndex with 0.5s overlap. 1s minimum guard.
        let tailStartAbs: Int
        let endAbsIndex: Int
        if isFluidAudio {
            // Growing window from last committed chunk to now, capped at 8s.
            // Replace semantics: each pass retranscribes the full tail so the model gets growing context
            // and text accumulates naturally without append/dedup heuristics.
            let maxGrowingSamples = Int(8.0 * sampleRate)
            tailStartAbs = max(lastTranscribedSampleIndex, ringEnd - maxGrowingSamples)
            guard ringEnd > tailStartAbs + Int(0.3 * sampleRate) else { return }
            endAbsIndex = ringEnd
        } else if isWhisperKitPreview {
            // Pass the complete uncommitted recording, but ask WhisperKit to seek to
            // the cross-window agreement point. This preserves file-relative word
            // timestamps while the encoder only processes the uncertain suffix.
            tailStartAbs = max(lastTranscribedSampleIndex, ringBase)
            // WhisperKit does not produce a usable timestamped result below roughly
            // one second. Starting sooner created a 40ms retry storm without improving
            // actual time-to-first-text.
            guard ringEnd > tailStartAbs + Int(1.0 * sampleRate) else { return }
            endAbsIndex = ringEnd
        } else {
            let overlapSamples = Int(0.5 * sampleRate)
            tailStartAbs = max(lastTranscribedSampleIndex,
                               lastPreviewedSampleIndex > overlapSamples ? lastPreviewedSampleIndex - overlapSamples : 0)
            guard ringEnd > tailStartAbs + Int(1.0 * sampleRate) else { return }
            let maxWindowSamples = Int(2.0 * sampleRate)
            endAbsIndex = min(ringEnd, tailStartAbs + maxWindowSamples)
        }
        let windowSamples = ring.slice(fromAbsolute: tailStartAbs, toAbsolute: endAbsIndex)
        guard !windowSamples.isEmpty else { return }
        let candidateEndIndex = endAbsIndex

        // Incremental VAD: only check new audio since the last pass (max 3 s).
        // Full-window VAD grew O(n) with recording length; now O(1) per pass.
        if let vad = vad {
            let vadStart = max(lastPreviewVADCheckEndIndex, ringEnd - Int(3.0 * sampleRate))
            if vadStart < ringEnd {
                let vadSamples = ring.slice(fromAbsolute: vadStart, toAbsolute: ringEnd)
                if !vadSamples.isEmpty {
                    lastPreviewVADCheckEndIndex = ringEnd
                    if !vad.hasSpeech(samples: vadSamples) { return }
                }
            }
        }

        let normalizedSamples = normalizeSamples(windowSamples)
        let lang = effectiveLanguage

        // Never feed WhisperKit provisional text or vocabulary prompt words into a
        // short preview window. Both strongly bias ambiguous audio. Only actual,
        // previously committed speech is safe context for provisional decoding.
        let prompt: String?
        if isWhisperKitPreview {
            if let prev = completedChunkTexts.last, !prev.isEmpty {
                prompt = String(prev.suffix(50))
            } else {
                prompt = nil
            }
        } else if !previewAccumulatedText.isEmpty {
            var combined = ""
            if let ip = initialPrompt, !ip.isEmpty { combined = ip + " " }
            combined += String(previewAccumulatedText.suffix(50))
            prompt = combined
        } else if let prev = completedChunkTexts.last, !prev.isEmpty {
            var combined = ""
            if let ip = initialPrompt, !ip.isEmpty { combined = ip + " " }
            combined += String(prev.suffix(50))
            prompt = combined
        } else {
            prompt = initialPrompt
        }

        #if canImport(WhisperKit)
        if isWhisperKitPreview, !pendingChunks.isEmpty { return }
        // Admission is atomic with the release gate: either this pass owns the
        // runtime before stop preparation starts, or it cannot start at all.
        if isWhisperKitPreview, !claimWhisperKitPreviewInferenceUnlessStopping() { return }
        if isWhisperKitPreview {
            activeWhisperKitPreviewStartIndex = tailStartAbs
            activeWhisperKitPreviewEndIndex = candidateEndIndex
        }
        #endif

        // Assign the ordering ID only after claiming WhisperKit. Incrementing it for
        // skipped busy passes would make every slower Core ML callback look stale.
        previewPassID += 1
        let currentPassID = previewPassID

        let windowSecs = String(format: "%.2f", Double(windowSamples.count) / sampleRate)
        Logger.debug("Preview pass \(currentPassID): \(windowSamples.count) samples (\(windowSecs)s), backend=\(String(describing: type(of: preview)))", subsystem: .transcription)

        var doPreviewTranscribe: (@escaping (String) -> Void) -> Void = { cb in
            preview.transcribeAsync(samples: normalizedSamples, initialPrompt: prompt,
                language: lang, singleSegment: true, maxTokens: 0, completion: cb)
        }
        #if canImport(FluidAudio)
        if let fluidBridge = preview as? FluidAudioBridge {
            doPreviewTranscribe = { cb in fluidBridge.transcribePreviewAsync(samples: normalizedSamples, completion: cb) }
        }
        #endif
        #if canImport(WhisperKit)
        if let wkBridge = preview as? WhisperKitBridge {
            // Raw token callbacks are intentionally not shown: they are mutable beam
            // hypotheses and caused unrelated vocabulary to flash in the overlay.
            let agreementIndex = eagerEngine?.agreementStartIndex ?? tailStartAbs
            let clipSeconds = Float(max(0, agreementIndex - tailStartAbs)) / Float(sampleRate)
            // prefixTokens are NOT passed in preview passes: forced tokens receive
            // timestamp 0.0 rather than their acoustic position, which breaks the
            // agreement state machine (anchor=0 on every pass after first confirmation).
            // clipTimestamps alone is sufficient to advance the encoder to the
            // agreement boundary; the decoder then produces correct file-relative timestamps.
            // eagerEngine?.prefixTokens is still updated on each confirmation
            // and is used only on the stop-path tail reconciliation decode.
            wkBridge.clearCallbacks()
            wkBridge.transcribeStreamingAsync(
                samples: normalizedSamples,
                language: lang,
                clipSeconds: clipSeconds,
                prefixTokens: nil,
                maxTokens: 96
            ) { [weak self, weak wkBridge] result in
                guard let self else { return }
                defer {
                    wkBridge?.clearCallbacks()
                    self.activeWhisperKitPreviewStartIndex = 0
                    self.activeWhisperKitPreviewEndIndex = 0
                    self.releaseWhisperKitInference(.preview)
                }
                guard !self.isStopped,
                      currentPassID == self.previewPassID,
                      let result else { return }
                guard let text = self.consumeWhisperKitStreamingResult(
                    result, audioBaseIndex: tailStartAbs,
                    through: candidateEndIndex
                ) else { return }
                let latency = String(format: "%.0f", result.pipelineDuration * 1000)
                Logger.debug(
                    "WhisperKit eager preview \(currentPassID): \(result.words.count) words, " +
                    "pipeline=\(latency)ms clip=\(String(format: "%.2f", clipSeconds))s " +
                    "language=\(result.language ?? "unknown") locked=\(result.languageIsLocked)",
                    subsystem: .transcription
                )
                self.publishWhisperKitStreamingPreview(text, through: candidateEndIndex)
            }
            return
        }
        #endif

        doPreviewTranscribe { [weak self] text in
            guard let self else { return }
            #if canImport(WhisperKit)
            defer {
                if isWhisperKitPreview {
                    (preview as? WhisperKitBridge)?.clearCallbacks()
                    self.activeWhisperKitPreviewStartIndex = 0
                    self.activeWhisperKitPreviewEndIndex = 0
                    self.releaseWhisperKitInference(.preview)
                }
            }
            #endif
            guard !self.isStopped else { return }

            // Discard out-of-order callbacks
            guard currentPassID == self.previewPassID else {
                Logger.debug("Preview \(currentPassID) discarded (stale, current=\(self.previewPassID))", subsystem: .transcription)
                return
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hallucination = !trimmed.isEmpty && self.isHallucination(trimmed)
            Logger.debug("Preview \(currentPassID) cb: '\(trimmed.prefix(50))' hallucination=\(hallucination)", subsystem: .transcription)
            if trimmed.isEmpty {
                if isWhisperKitPreview {
                    Logger.debug("WhisperKit preview empty; keeping previous provisional text", subsystem: .transcription)
                }
                return
            }
            guard !hallucination else { return }

            if isWhisperKitPreview {
                var cachedText = trimmed
                var cachedStartIndex = tailStartAbs
                if tailStartAbs > self.lastTranscribedSampleIndex,
                   self.whisperKitPreviewAnchoredAtTailStart,
                   self.latestWhisperKitPreviewStartIndex <= self.lastTranscribedSampleIndex,
                   let merged = self.mergeWhisperKitRollingPreview(
                       previous: self.latestWhisperKitPreviewText,
                       newWindow: trimmed
                   ) {
                    cachedText = merged
                    cachedStartIndex = self.latestWhisperKitPreviewStartIndex
                    Logger.debug("WhisperKit rolling preview preserved decoded prefix", subsystem: .transcription)
                }
                if tailStartAbs <= self.lastTranscribedSampleIndex,
                   candidateEndIndex - self.lastTranscribedSampleIndex <= Int(3.5 * self.sampleRate) {
                    self.whisperKitPreviewAnchoredAtTailStart = true
                }
                self.latestWhisperKitPreviewText = cachedText
                self.latestWhisperKitPreviewStartIndex = cachedStartIndex
                self.latestWhisperKitPreviewEndIndex = candidateEndIndex
                self.latestWhisperKitPreviewAverageLogProbability =
                    (preview as? WhisperKitBridge)?.lastAverageLogProbability
                // The progress callback has already exposed the safe prefix. Apply the
                // same edge guard to the completed hypothesis; never flash raw tail words.
                self.publishWhisperKitPreview(cachedText, through: candidateEndIndex)
                return
            }

            if isFluidAudio {
                // Replace semantics: the latest pass owns the whole provisional tail.
                // This allows normal decoder revisions without overlap/dedup drift.
                self.previewAccumulatedText = trimmed
            } else {
                // whisper.cpp append-only: dedup overlap and grow monotonically
                let deduped = self.deduplicateOverlap(existing: self.previewAccumulatedText, new: trimmed)
                if !deduped.isEmpty {
                    if self.previewAccumulatedText.isEmpty {
                        self.previewAccumulatedText = deduped
                    } else {
                        self.previewAccumulatedText += " " + deduped
                    }
                }
                self.lastPreviewedSampleIndex = candidateEndIndex
            }

            // Build display: completed chunks + accumulated preview
            var display = self.completedChunkTexts.joined(separator: " ")
            if !display.isEmpty && !self.previewAccumulatedText.isEmpty {
                display += " "
            }
            display += self.previewAccumulatedText

            self.fullTranscription = display
            let tail = self.previewAccumulatedText

            DispatchQueue.main.async { [weak self] in
                self?.onTranscription?(display)
                self?.onPreviewTail?(tail)
            }

            EventRingBuffer.shared.record(
                component: "StreamingTranscriber",
                operation: "previewWords",
                kind: .progress,
                metadata: ["words": .int(trimmed.split(separator: " ").count), "totalChars": .int(display.count)]
            )
            transcriptionProgressCounter &+= 1
        }
    }

    #if canImport(WhisperKit)
    private func resetWhisperKitStreamingState(at sampleIndex: Int) {
        eagerEngine?.reset(at: sampleIndex)
    }

    /// Converts a completed timestamped decode into an eager-streaming snapshot.
    /// Words agreed by two consecutive windows become immutable. The last two agreed
    /// words remain revisable and are also reused as decoder prefix tokens.
    private func consumeWhisperKitStreamingResult(
        _ result: WhisperKitStreamingResult,
        audioBaseIndex: Int,
        through candidateEndIndex: Int
    ) -> String? {
        guard var engine = eagerEngine else { return nil }
        let hypothesis = result.words.map { word -> EagerStreamWord in
            EagerStreamWord(
                text: word.text, tokens: word.tokens,
                startIndex: audioBaseIndex + Int(Double(word.start) * sampleRate),
                endIndex: audioBaseIndex + Int(Double(word.end) * sampleRate),
                probability: word.probability
            )
        }
        let outcome = engine.consume(hypothesis: hypothesis, audioBaseIndex: audioBaseIndex,
            languageIsLocked: result.languageIsLocked, lastCommittedIndex: lastTranscribedSampleIndex,
            windowEndIndex: candidateEndIndex)
        eagerEngine = engine
        if let commit = outcome.softCommit, !commit.text.isEmpty {
            completedChunkTexts.append(commit.text)
            onChunkCompleted?(TranscriptChunk(text: commit.text,
                start: Double(commit.startIndex) / sampleRate,
                end: Double(commit.endIndex) / sampleRate,
                recordedDuration: recordedDuration))
            lastTranscribedSampleIndex = commit.endIndex
            lastClaimedSampleIndex = commit.endIndex
            do { try allSamplesLock.withLock { ring.dropFront(toAbsoluteIndex: commit.endIndex) } }
            catch { Logger.warning("WhisperKit eager stream could not prune committed audio", subsystem: .transcription) }
            lastPreviewVADCheckEndIndex = max(lastPreviewVADCheckEndIndex, commit.endIndex)
        }
        guard let displayText = outcome.displayText else { return nil }
        guard !isHallucination(displayText) else { return nil }
        latestWhisperKitPreviewText = displayText
        latestWhisperKitPreviewStartIndex = lastTranscribedSampleIndex
        latestWhisperKitPreviewEndIndex = candidateEndIndex
        latestWhisperKitPreviewAverageLogProbability = result.averageLogProbability
        latestWhisperKitPreviewLanguageIsLocked = result.languageIsLocked
        whisperKitPreviewAnchoredAtTailStart = true
        return displayText
    }

    private func publishWhisperKitStreamingPreview(_ text: String, through sampleIndex: Int) {
        guard !isStopped, !text.isEmpty, text != previewAccumulatedText else { return }
        previewAccumulatedText = text
        lastPreviewedSampleIndex = sampleIndex
        var display = completedChunkTexts.joined(separator: " ")
        if !display.isEmpty { display += " " }
        display += text
        fullTranscription = display
        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(display)
            self?.onPreviewTail?(text)
        }
        transcriptionProgressCounter &+= 1
    }

    private func claimWhisperKitInference(_ owner: WhisperKitInferenceOwner) -> Bool {
        whisperKitInferenceLock.lock()
        defer { whisperKitInferenceLock.unlock() }
        guard whisperKitInferenceOwner == .none else { return false }
        whisperKitInferenceOwner = owner
        return true
    }

    private func claimWhisperKitPreviewInferenceUnlessStopping() -> Bool {
        stopGateLock.lock()
        defer { stopGateLock.unlock() }
        guard !_isPreparingToStop else { return false }
        return claimWhisperKitInference(.preview)
    }

    private func isWhisperKitInferenceIdle() -> Bool {
        whisperKitInferenceLock.lock()
        defer { whisperKitInferenceLock.unlock() }
        return whisperKitInferenceOwner == .none
    }

    private func releaseWhisperKitInference(_ owner: WhisperKitInferenceOwner) {
        whisperKitInferenceLock.lock()
        defer { whisperKitInferenceLock.unlock() }
        guard whisperKitInferenceOwner == owner else { return }
        whisperKitInferenceOwner = .none
    }
    #endif

    // MARK: - Eager Streaming (whisper.cpp main model)

    /// One live-preview pass for the whisper.cpp eager-streaming path.
    /// Called from `runLivePreviewPass` (as a heartbeat) and self-schedules from
    /// the decode callback so passes run back-to-back as fast as the model allows.
    // Deliberately no `audio_ctx` here — the eager pass encodes the full 1500 frames.
    //
    // Shrinking it looked compelling in isolation: a `largeTurboQ5` pass costs 0.18s at ctx=256
    // and 0.26s at 512 against 0.57s at 1500. Shipped at a fixed small value it made the decoder
    // loop — live text came back as "Let me try to see it one one Let Let me", and that garbage
    // then propagated into the next pass's `initial_prompt`.
    //
    // The reason is NOT that the windows are short. `EagerStreamProfileTests` measured 76 passes
    // over 12 real recordings: 62 of them decode a window of 8s or more, and the very-long
    // fixtures average 38–48s per window. The failure was a fixed `audio_ctx` applied to a window
    // whose length varies by two orders of magnitude — mostly padding on the rare short window,
    // and truncation on the common long one.
    //
    // Latency does scale with the window, steeply: under 8s a pass is a flat ~1.4–1.5s; at 8s+ it
    // is p50 2.3s, p90 8.8s, max 13.2s. So a *window-proportional* `audio_ctx` is still on the
    // table. It is not the first fix, because the windows should not be 38s in the first place —
    // see the note on window growth in `runEagerStreamPass`. Reintroduce only with a fresh
    // profile run showing both the latency win and no looping.

    private func runEagerStreamPass() {
        guard let bridge = whisper as? WhisperBridge else {
            onEagerPassSkipped?(.notEagerBackend); return
        }
        guard !isStopped else { onEagerPassSkipped?(.stopped); return }

        // One decode outstanding at a time. Claimed atomically before any work, because two
        // callers race here — see `claimEagerPass`. Released on every path out; `handedOff`
        // transfers ownership of the release to the completion callback.
        guard claimEagerPass() else { onEagerPassSkipped?(.busy); return }
        var handedOff = false
        defer { if !handedOff { releaseEagerPass() } }

        var samples: [Float] = []
        var audioBaseIndex = 0
        var candidateEndIndex = 0
        var liveEndIndex = 0
        do {
            try allSamplesLock.withLock {
                let ringBase = ring.baseSampleIndex
                let allSamples = ring.toArray()
                let ringEnd = ringBase + allSamples.count
                candidateEndIndex = ringEnd
                liveEndIndex = ringEnd

                // Clip to agreement boundary so we only decode unconfirmed audio.
                // Smaller window = faster decode = more updates per second.
                //
                // Then CAP the window. Without a cap it runs away: the agreement boundary needs
                // two consecutive passes to confirm anything, a pass over an 8s+ window costs
                // p50 2.3s, and audio keeps arriving the whole time — so the window grows faster
                // than agreement advances, which makes the next pass slower, which lets the
                // window grow further. `EagerStreamProfileTests` measured the end state on real
                // recordings: mean window 38s and 48s on the very-long fixtures, passes up to
                // 13.2s, and half the speech never transcribed (WER 0.50). One 204s recording
                // produced the two words "be different".
                //
                // The cap takes the HEAD of the unconfirmed region, not the tail. Tail-capping
                // would be cheaper to reason about but silently discards the audio between the
                // agreement boundary and the window start — those words are never decoded by any
                // pass. Head-capping only delays them: this pass decodes `[agreementStart,
                // agreementStart + cap]`, agreement advances into it, and the next pass picks up
                // where it left off. Falling behind live audio is self-correcting because a
                // capped pass consumes far more audio than it costs in wall-clock; falling behind
                // permanently is not possible unless a single pass takes longer than the cap.
                // Start a short run-up before the boundary so the first unconfirmed word is not
                // cut in half — see `eagerSeamMarginSeconds`. The engine still filters the
                // hypothesis against its own boundary, so the extra audio adds context, not text.
                let boundary = max(eagerEngine?.agreementStartIndex ?? ringBase, ringBase)
                let agreementStart = max(ringBase,
                                         boundary - Int(eagerSeamMarginSeconds * sampleRate))
                let clipOffset = agreementStart - ringBase
                let unconfirmed = clipOffset < allSamples.count
                    ? Array(allSamples[clipOffset...])
                    : allSamples
                let cap = Int(eagerMaxWindowSeconds * sampleRate)
                if unconfirmed.count > cap {
                    samples = Array(unconfirmed.prefix(cap))
                    // candidateEndIndex must describe the audio this pass actually decoded, not
                    // the live end of the ring. It is what the stop path uses to decide whether
                    // the preview already covers the tail; overstating it would reuse a
                    // hypothesis that never saw the last seconds of speech and drop them.
                    candidateEndIndex = agreementStart + cap
                } else {
                    samples = unconfirmed
                }
                audioBaseIndex = agreementStart
            }
        } catch { onEagerPassSkipped?(.lockTimeout); return }

        // Require at least 0.5s of audio in the unconfirmed window.
        guard samples.count >= Int(0.5 * sampleRate) else {
            onEagerPassSkipped?(.tooShort); return
        }

        // VAD gate — keeps the main model off the GPU while nobody is talking.
        //
        // The question is about the *whole* unconfirmed window, not its tail. An earlier version
        // gated on the last 2s, reasoning that silence there means the speaker has paused and
        // there is nothing new to say. That is wrong, and measurably so: the window starts at the
        // agreement boundary, so a pause routinely has several seconds of never-decoded speech
        // sitting behind it. Gating on the tail refuses to decode that speech until the speaker
        // happens to resume — and if they resume after the window has grown past the cap, the
        // frozen window makes the refusal permanent. `EagerStreamProfileTests` measured both
        // halves of that on the same fixture: `05011586`, 204s, 197 tail-gate skips against 12
        // actual passes, final WER 0.938 — one clause out of a four-minute recording.
        //
        // Asking about the whole window costs nothing when the speaker really has stopped: the
        // boundary keeps advancing as agreement confirms the backlog, the window shrinks, and the
        // `tooShort` guard above takes over within a pass or two. That terminates on the audio
        // being *decoded* rather than on it being ignored.
        //
        // The one case that still needs its own exit is a capped window holding nothing but
        // silence. The window is then frozen at `[agreementStart, +cap]` and the boundary only
        // moves as a *result* of a decode, so declining to decode it means presenting the
        // identical window every 150 ms for the rest of the recording. Seek past it instead, so
        // the next pass sees new audio.
        if let vad, !eagerWindowHasSpeech(samples, start: audioBaseIndex,
                                          end: candidateEndIndex, vad: vad) {
            if candidateEndIndex < liveEndIndex {
                eagerEngine?.seek(past: candidateEndIndex)
                onEagerPassSkipped?(.silentBacklog)
            } else {
                onEagerPassSkipped?(.silent)
            }
            return
        }

        let lang = effectiveLanguage
        let prompt = completedChunkTexts.last.map { String($0.suffix(100)) }
        let normalizedSamples = normalizeSamples(samples)
        let base = audioBaseIndex
        let endIdx = candidateEndIndex

        // Publish the in-flight window so stopAsync() can decide whether this decode is about
        // to cover the tail — if so it waits a few ms for it rather than paying for a full
        // tail decode of nearly the same audio.
        activeWhisperKitPreviewStartIndex = lastTranscribedSampleIndex
        activeWhisperKitPreviewEndIndex = endIdx

        isProcessing = true
        handedOff = true
        let passSubmittedAt = CFAbsoluteTimeGetCurrent()
        let passWindowSeconds = Double(normalizedSamples.count) / sampleRate
        // How far the decoded window ends behind the audio already captured. Zero before the cap
        // existed (the window always ran to the live edge); the cap trades this lag for bounded
        // pass latency, so it is the number that says whether the trade was worth making.
        let passLagSeconds = Double(max(0, liveEndIndex - endIdx)) / sampleRate
        bridge.transcribeStreamingAsync(
            samples: normalizedSamples,
            language: lang,
            initialPrompt: prompt
        ) { [weak self] result in
            guard let self else { return }
            self.isProcessing = false
            // Held until `applyEagerOutcome` has finished mutating the engine. Releasing at the
            // top of this callback would let the heartbeat start the next pass concurrently with
            // that mutation, and the engine is a plain struct with no locking of its own —
            // `runEagerStreamPass` reads `agreementStartIndex` while `consume` is writing it.
            //
            // Released explicitly before the self-schedule below, since that call re-claims;
            // the `defer` only covers the early returns.
            var released = false
            func releaseOnce() {
                guard !released else { return }
                released = true
                self.releaseEagerPass()
            }
            defer { releaseOnce() }
            if let probe = self.onEagerPassMeasured {
                let now = CFAbsoluteTimeGetCurrent()
                probe(EagerPassSample(
                    windowSeconds: passWindowSeconds,
                    lagSeconds: passLagSeconds,
                    decodeMs: (now - passSubmittedAt) * 1000,
                    sinceLastPassMs: self.lastEagerPassCompletedAt.map { (now - $0) * 1000 } ?? 0,
                    wordCount: result?.words.count ?? 0,
                    averageLogProbability: result?.averageLogProbability ?? 0
                ))
                self.lastEagerPassCompletedAt = now
            }
            self.activeWhisperKitPreviewStartIndex = 0
            self.activeWhisperKitPreviewEndIndex = 0
            // Stop self-scheduling if the transcriber was stopped while this decode was in flight.
            // Without this guard the in-flight completion callback re-enters runEagerStreamPass(),
            // bypassing the heartbeat's isStopped check and causing the old transcriber to keep
            // running after a new recording has started, leaking stale text into the new session.
            guard !self.isStopped else { return }
            if let result {
                Logger.debug("Eager pass: \(result.words.count) words, logProb=\(String(format: "%.2f", result.averageLogProbability))", subsystem: .transcription)
                self.applyEagerOutcome(result: result,
                                       audioBaseIndex: base,
                                       candidateEndIndex: endIdx)
            } else {
                // Distinguish the benign case. Every recording ends with one nil pass a few
                // tens of ms before `Transcribing tail:` — the stop path takes `ctxLock` out
                // from under the in-flight preview decode, which then times out on the lock.
                // That is expected once per recording; reporting it as "decode failed" sent a
                // debugging session looking for a decoder fault that was never there.
                if self.isPreparingToStop {
                    Logger.debug("Eager pass: cancelled by stop (ctxLock taken by tail decode)",
                                 subsystem: .transcription)
                } else {
                    Logger.warning("Eager pass: nil result mid-recording (decode failed or lock timeout)",
                                   subsystem: .transcription)
                }
            }
            // Self-schedule: start the next pass immediately without waiting for the
            // 500ms heartbeat timer. The timer remains to restart the chain if it breaks.
            // Stop the chain once a stop is underway — the outcome above has already been
            // applied, so stopAsync() has the freshest preview to reuse, and starting another
            // decode here would only hold the ctxLock the stop path may need.
            guard !self.isPreparingToStop else { return }
            releaseOnce()
            self.runEagerStreamPass()
        }
    }

    private func applyEagerOutcome(
        result: WhisperStreamResult,
        audioBaseIndex: Int,
        candidateEndIndex: Int
    ) {
        guard var engine = eagerEngine else { return }
        let hypothesis = result.words.map { word -> EagerStreamWord in
            EagerStreamWord(
                text: word.text, tokens: word.tokens,
                startIndex: audioBaseIndex + Int(Double(word.start) * sampleRate),
                endIndex: audioBaseIndex + Int(Double(word.end) * sampleRate),
                probability: word.probability
            )
        }
        // Language is always locked for whisper.cpp eager (single-language model, fixed language).
        let outcome = engine.consume(hypothesis: hypothesis, audioBaseIndex: audioBaseIndex,
            languageIsLocked: true, lastCommittedIndex: lastTranscribedSampleIndex,
            windowEndIndex: candidateEndIndex)
        eagerEngine = engine
        if let reason = outcome.holdReason { onEagerPassHeld?(reason) }
        if outcome.repeatedConfirmedTail { onEagerRepeatedConfirmedTail?() }
        // Full strings, not a 40-character prefix. Every seam defect this path has produced was
        // diagnosed by reading consecutive outcomes against each other, and a prefix truncates
        // exactly the end of the hypothesis — which is where the boundary, and the bug, live.
        Logger.debug("""
            Eager outcome: base=\(audioBaseIndex) end=\(candidateEndIndex) \
            held=\(outcome.wasHeld)\(outcome.holdReason.map { "(\($0))" } ?? "") \
            commit=\(outcome.softCommit.map { "[\($0.startIndex)-\($0.endIndex)] '\($0.text)'" } ?? "nil")
              confirmed: \(outcome.confirmedText ?? "-")
              display:   \(outcome.displayText ?? "-")
            """, subsystem: .transcription)
        if let commit = outcome.softCommit, !commit.text.isEmpty {
            // Dedup against the previous chunk, as every other commit path here already does
            // (`appendTailTranscription`, the VAD chunk path). This one appended raw, and the
            // seam it left is visible in the A/B gate's final text: `Let's do ⟦Let's do this.⟧`,
            // `if you know, but ⟦But⟧ data science`, `and like we ⟦We⟧ adjusted`. The engine
            // deliberately re-decodes the boundary words in the next window — that is how
            // LocalAgreement gets a second opinion on them — so the opening words of commit N+1
            // legitimately repeat the closing words of commit N, and something has to drop one
            // copy. Nothing did, on the one path where the repeat is by construction.
            let committedText: String
            if let previous = completedChunkTexts.last, !previous.isEmpty {
                committedText = VADSegmenter.deduplicateOverlap(previousText: previous,
                                                                newText: commit.text)
            } else {
                committedText = commit.text
            }
            if !committedText.isEmpty {
                completedChunkTexts.append(committedText)
                onChunkCompleted?(TranscriptChunk(text: committedText,
                    start: Double(commit.startIndex) / sampleRate,
                    end: Double(commit.endIndex) / sampleRate,
                    recordedDuration: recordedDuration))
            }
            // The audio boundary advances either way: the text was either committed or was a
            // duplicate of text already committed, and re-decoding it would only produce the
            // duplicate again.
            lastTranscribedSampleIndex = commit.endIndex
            lastClaimedSampleIndex = commit.endIndex
            do { try allSamplesLock.withLock { ring.dropFront(toAbsoluteIndex: commit.endIndex) } }
            catch { Logger.warning("Eager stream (whisper.cpp) could not prune committed audio",
                subsystem: .transcription) }
            lastPreviewVADCheckEndIndex = max(lastPreviewVADCheckEndIndex, commit.endIndex)
            // A soft-commit empties `confirmedWords`, so the next display legitimately restarts
            // from the unconfirmed tail. Reset the monotonicity floor with it.
            lastPublishedEagerWordCount = 0
        }
        guard let displayText = outcome.displayText, !displayText.isEmpty else { return }
        guard !isHallucination(displayText) else { return }

        // Live text must never shrink. `displayText` is `confirmedWords + hyp`, and the
        // unconfirmed `hyp` is a fresh full-model decode of a *growing* window — whisper.cpp
        // routinely returns fewer words for more audio (observed 8 → 6 → 4 across consecutive
        // passes), so the raw string flickers and rewrites itself. That flicker is why the eager
        // preview read worse than the old tiny-model preview, which was append-only by
        // construction. Drop shrinking passes instead of publishing them: passes are ~0.6s apart,
        // so the worst case is one stale frame, and the next pass that actually extends the text
        // publishes normally. A shrunk hypothesis is also unfit to reuse at stop — it covers more
        // audio with fewer words — so this returns before touching the reuse fields too.
        let wordCount = displayText.split(separator: " ").count
        guard wordCount >= lastPublishedEagerWordCount else {
            Logger.debug("Eager pass dropped: \(wordCount) words would shrink live text from \(lastPublishedEagerWordCount)", subsystem: .transcription)
            return
        }
        lastPublishedEagerWordCount = wordCount

        // What goes on screen. `displayText` keeps the speculative tail and so can be rewritten;
        // `confirmedText` cannot. See `eagerPublishesSpeculativeTail`.
        //
        // Only the screen is affected. Everything below still records `displayText`, because the
        // stop path needs a hypothesis spanning the whole uncommitted region through
        // `candidateEndIndex` — reusing a confirmed-only string there would silently drop the
        // last words of the recording, which is the exact failure the tail decode exists to catch.
        let publishedText = eagerPublishesSpeculativeTail
            ? displayText
            : (outcome.confirmedText ?? "")
        guard !publishedText.isEmpty else { return }

        // Record this pass as a reusable final result. `displayText` is `confirmedWords + hyp`
        // (EagerStreamEngine), so it already spans the whole uncommitted region from
        // lastTranscribedSampleIndex through candidateEndIndex — nothing is held back for a
        // later pass. That is what lets canReuseEagerPreviewAtStop() skip the tail decode and
        // makes the stop insert immediate. Language is always locked here (fixed-language model).
        latestWhisperKitPreviewText = displayText
        latestWhisperKitPreviewStartIndex = lastTranscribedSampleIndex
        latestWhisperKitPreviewEndIndex = candidateEndIndex
        latestWhisperKitPreviewAverageLogProbability = result.averageLogProbability
        latestWhisperKitPreviewLanguageIsLocked = true
        whisperKitPreviewAnchoredAtTailStart = true

        let passID = previewPassID &+ 1
        previewPassID = passID
        previewAccumulatedText = displayText
        lastPreviewedSampleIndex = candidateEndIndex
        var display = completedChunkTexts.joined(separator: " ")
        if !display.isEmpty { display += " " }
        display += publishedText
        fullTranscription = display
        DispatchQueue.main.async { [weak self] in
            guard let self, self.previewPassID == passID else { return }
            self.onTranscription?(display)
            self.onPreviewTail?(publishedText)
        }
        transcriptionProgressCounter &+= 1
    }

    /// Dedup overlap words between existing accumulated text and new preview text
    private func deduplicateOverlap(existing: String, new: String) -> String {
        let existingWords = existing.split(separator: " ")
        let newWords = new.split(separator: " ")
        guard !existingWords.isEmpty, !newWords.isEmpty else { return new }

        let maxOverlap = min(5, min(existingWords.count, newWords.count))
        for len in stride(from: maxOverlap, through: 1, by: -1) {
            if existingWords.suffix(len).elementsEqual(newWords.prefix(len)) {
                let remaining = newWords.dropFirst(len).joined(separator: " ")
                return remaining
            }
        }
        return new
    }

    // MARK: - Hallucination Detection

    private static let hallucinationPatterns: [String] = [
        "thank you for watching",
        "thanks for watching",
        "subscribe",
        "like and subscribe",
        "please subscribe",
        "thank you for listening",
        "thanks for listening",
        "see you next time",
        "see you in the next",
        "bye bye",
        "goodbye",
    ]

    private func isHallucination(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }

        if lower.count <= 2 && !lower.contains(where: { $0.isLetter }) {
            return true
        }

        for pattern in Self.hallucinationPatterns {
            if lower == pattern || lower.hasPrefix(pattern) {
                Logger.debug("Hallucination detected: '\(text)' matches pattern '\(pattern)'", subsystem: .transcription)
                return true
            }
        }

        let words = lower.split(separator: " ")
        if words.count >= 3 {
            let uniqueWords = Set(words)
            if uniqueWords.count == 1 {
                return true
            }
        }

        let maxPhraseLen = words.count / 3
        if maxPhraseLen >= 3 {
            for phraseLen in 3...min(6, maxPhraseLen) {
                let phrase = words.prefix(phraseLen).joined(separator: " ")
                let phraseCount = lower.components(separatedBy: phrase).count - 1
                if phraseCount >= 3 {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Stop & Final Pass

    /// Stop streaming and return the best transcription.
    func stop(skipCorrections: Bool = false) -> String {
        isStopped = true
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil

        // Abort any in-flight transcription on all backends
        whisper.requestAbort()
        if let bridge = whisper as? WhisperBridge {
            bridge.onNewSegment = nil
        }
        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            wkBridge.clearCallbacks()
        }
        #endif
        provisionalChunkText = ""
        currentChunkGeneration &+= 1 // invalidate any in-flight snapshot deliveries

        // Discard any pending chunks — the tail pass will cover unprocessed audio
        pendingChunks.removeAll()

        // Transcribe tail audio (unprocessed samples after last chunk)
        transcribeTail()

        // Combine all chunks
        let rawText = completedChunkTexts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawText.isEmpty else {
            return clearAndReturn("")
        }

        // Skip dictionary correction when LLM post-processing is active — LLM handles
        // corrections, and CorrectionEngine can make wrong substitutions (e.g. "and it" → "audit")
        // that corrupt the text before the LLM sees it.
        var finalResult = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
        if fillerWordRemovalEnabled {
            finalResult = FillerWordFilter.removeFillers(from: finalResult)
        }

        return clearAndReturn(finalResult)
    }

    /// Transcribe remaining audio after the last completed chunk
    private func transcribeTail() {
        var ringContent: [Float] = []
        var ringBase: Int = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch {
            Logger.error("Failed to acquire lock for tail transcription", subsystem: .transcription)
            return
        }

        // Map absolute lastTranscribedSampleIndex to ring-relative
        let tailRelIndex = max(0, lastTranscribedSampleIndex - ringBase)

        guard let tailChunk = vadSegmenter.finalizeTail(
            allSamples: ringContent,
            lastTranscribedIndex: tailRelIndex
        ) else {
            Logger.debug("No tail audio to transcribe", subsystem: .transcription)
            return
        }

        // Energy check as secondary guard (when VAD is nil)
        if !hasEnergy(tailChunk.samples) {
            Logger.debug("Tail audio has no energy, skipping", subsystem: .transcription)
            return
        }

        // On the eager path the preview has usually already been credited through its own end
        // index, so what is left here is the sliver between that and key release — often a few
        // hundred milliseconds of room tone. Whisper does not return nothing for that; it returns
        // its training-set filler, and the regression gate caught it appended to the final text:
        // "…like everything in the frame. ⟨And I'll see you in the frames.⟩" and "…how it's
        // working ⟨you⟩". Energy alone does not screen it out — room tone has energy. Ask the VAD,
        // which is the same question the eager pass gate asks before every decode.
        if usesEagerStream, let vad, !vad.hasSpeech(samples: tailChunk.samples) {
            Logger.debug("Eager tail has no speech, skipping", subsystem: .transcription)
            return
        }

        let tailDuration = Double(tailChunk.endSample - tailChunk.startSample) / sampleRate
        Logger.debug("Transcribing tail: \(String(format: "%.1f", tailDuration))s", subsystem: .transcription)

        // Context from last chunk
        let prompt: String?
        if let prev = completedChunkTexts.last, !prev.isEmpty {
            var combinedPrompt = ""
            if let ip = initialPrompt, !ip.isEmpty {
                combinedPrompt = ip + " "
            }
            combinedPrompt += String(prev.suffix(100))
            prompt = combinedPrompt
        } else {
            prompt = initialPrompt
        }

        // Reset abort for tail transcription (unconditional — works for WhisperBridge and FluidAudioBridge)
        whisper.resetAbort()

        // Synchronous transcription for the tail
        let normalizedSamples = normalizeSamples(tailChunk.samples)

        // Deliberately NO `audio_ctx` here — the tail encodes the full 1500 frames.
        //
        // This was tried, measured, and reverted on 2026-08-17. The motivating observation was
        // real: over five stops the tail decode cost ~687ms *flat*, 0.60s of audio costing 675ms
        // and 3.30s costing 698ms, which looks exactly like a fixed 30s mel encode. It is not.
        //
        // `TailAudioCtxTests.testSizedTailMatchesFullContextTextAndIsFaster` decoded 32 real tail
        // segments from history both ways. Sizing `audio_ctx` to the tail was **not faster at
        // all** — median 897ms → 938ms, i.e. 5% *slower* — and it destroyed the transcript:
        // mean WER 19.1 against the full-context output, individual tails as high as 147, which
        // is the insertion-heavy decoder-looping signature already documented above
        // `runEagerStreamPass`. The full-context arm ran first in every pair, so cold-cache bias
        // favored the sized arm; it still lost.
        //
        // The conclusion that matters for whoever optimizes this next: the flat ~687ms is NOT
        // encoder work, so shrinking the mel window cannot reclaim it. Look elsewhere — the
        // decoder loop and Metal graph setup are the remaining candidates. `audioCtxForSamples`
        // and the `audioCtx:` parameter are kept only so that test still compiles and runs as a
        // standing disproof; nothing on the production path passes a non-zero value.
        let text = whisper.transcribe(
            samples: normalizedSamples,
            initialPrompt: prompt,
            language: effectiveLanguage,
            singleSegment: false,
            maxTokens: 0
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty && !isHallucination(text) {
            let deduped: String
            if let prevText = completedChunkTexts.last, !prevText.isEmpty {
                deduped = VADSegmenter.deduplicateOverlap(previousText: prevText, newText: text)
            } else {
                deduped = text
            }
            if !deduped.isEmpty {
                completedChunkTexts.append(deduped)
                // `finalizeTail` works in ring-relative coordinates — `tailRelIndex` above is
                // `lastTranscribedSampleIndex - ringBase` — so the span it returns must be mapped
                // back before it is published on the audio clock. Stamping it raw made the final
                // chunk of every eager recording restart near zero and overlap everything before
                // it (`3.92s starts before prev end 19.11s` in the regression gate); the ring is
                // pruned at each soft-commit, so the error is exactly the audio already committed.
                onChunkCompleted?(TranscriptChunk(
                    text: deduped,
                    start: Double(ringBase + tailChunk.startSample) / sampleRate,
                    end: Double(ringBase + tailChunk.endSample) / sampleRate,
                    recordedDuration: recordedDuration
                ))
            }
        }
    }

    private func clearAndReturn(_ result: String) -> String {
        Logger.event(.recStop, .transcription, ["chars": .int(result.count)])
        return result
    }

    /// Cancel without final transcription. This must terminate the detached preview
    /// loop as well as audio capture; otherwise it keeps decoding a frozen ring buffer.
    func cancelAsync() async {
        guard !isStopped else { return }
        stopGateLock.withLock { _isPreparingToStop = true }
        isStopped = true
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil
        pendingChunks.removeAll()
        previewPassID &+= 1
        currentChunkGeneration &+= 1
        provisionalChunkText = ""
        previewAccumulatedText = ""

        whisper.requestAbort()
        if let bridge = whisper as? WhisperBridge {
            bridge.onNewSegment = nil
        }
        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            wkBridge.clearCallbacks()
            await wkBridge.cancelActiveTranscription()
        }
        #endif
    }

    /// Begin non-destructive stop work while AudioRecorder drains its final hardware
    /// buffer. A stale WhisperKit pass can be cancelled in parallel with that drain;
    /// a pass close enough to the release boundary is preserved for hybrid reuse.
    func prepareForStopAsync() async {
        // Close the preview admission gate before the audio drain begins. Task
        // cancellation alone is insufficient because an interrupted sleep used to
        // fall through and launch one final, immediately-cancelled model pass.
        stopGateLock.withLock { _isPreparingToStop = true }
        #if canImport(WhisperKit)
        guard let wkBridge = whisper as? WhisperKitBridge else { return }
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil

        guard !isWhisperKitInferenceIdle() else { return }
        guard !shouldWaitForActiveEagerPreviewAtStop() else {
            Logger.debug("Hybrid pre-stop preserved near-boundary WhisperKit preview", subsystem: .transcription)
            return
        }
        await wkBridge.cancelActiveTranscription()
        Logger.debug("Hybrid pre-stop cancelled stale WhisperKit preview", subsystem: .transcription)
        #endif
    }

    /// Stop asynchronously with proper cleanup
    func stopAsync(skipCorrections: Bool = false) async -> String {
        Logger.debug("Stopping StreamingTranscriber (async)...", subsystem: .transcription)

        stopGateLock.withLock { _isPreparingToStop = true }
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil

        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            // A decode often starts just before Fn is released and already includes the
            // complete spoken tail. Give it a short chance to finish rather than canceling
            // it and paying for an almost identical final Core ML pass.
            var waitIterations = 0
            let shouldWaitForPreview = shouldWaitForActiveEagerPreviewAtStop()
            while shouldWaitForPreview, !isWhisperKitInferenceIdle(), waitIterations < 100 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waitIterations += 1
            }
            if waitIterations > 0 {
                Logger.debug("Hybrid stop waited \(waitIterations * 10)ms for active WhisperKit decode", subsystem: .transcription)
            }

            if canReuseEagerPreviewAtStop() {
                isStopped = true
                wkBridge.clearCallbacks()
                pendingChunks.removeAll()
                provisionalChunkText = ""
                appendTailTranscription(latestWhisperKitPreviewText)
                Logger.info("Hybrid stop reused high-confidence WhisperKit preview", subsystem: .transcription)
                return finalizeCompletedChunks(skipCorrections: skipCorrections)
            }
        }
        #endif

        // whisper.cpp eager stream: same trade as WhisperKit above. The eager pass already
        // decoded the full uncommitted region with the same model that the tail decode would
        // use, so re-decoding it costs ~1s and returns the text we already have. Wait briefly
        // for a decode that is about to land, then reuse it and skip the tail entirely.
        if usesEagerStream {
            var waitIterations = 0
            let shouldWaitForPreview = shouldWaitForActiveEagerPreviewAtStop()
            while shouldWaitForPreview, isProcessing, waitIterations < 60 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waitIterations += 1
            }
            if waitIterations > 0 {
                Logger.debug("Eager stop waited \(waitIterations * 10)ms for active whisper.cpp decode", subsystem: .transcription)
            }

            if canReuseEagerPreviewAtStop() {
                isStopped = true
                pendingChunks.removeAll()
                provisionalChunkText = ""
                appendTailTranscription(latestWhisperKitPreviewText)
                await drainInFlightEagerPass()
                Logger.info("Eager stop reused high-confidence whisper.cpp preview", subsystem: .transcription)
                return finalizeCompletedChunks(skipCorrections: skipCorrections)
            }

            // Reuse was rejected — normally because the key was released mid-word, so the gap
            // after the last preview contains speech that must be decoded. Credit the preview
            // anyway and advance the commit boundary to its end, so the tail decode below covers
            // only that uncovered remainder (typically well under a second) instead of
            // re-decoding everything back to the last 6s soft-commit.
            if !latestWhisperKitPreviewText.isEmpty,
               latestWhisperKitPreviewStartIndex <= lastTranscribedSampleIndex,
               latestWhisperKitPreviewEndIndex > lastTranscribedSampleIndex,
               whisperKitPreviewAnchoredAtTailStart,
               let confidence = latestWhisperKitPreviewAverageLogProbability,
               confidence >= -0.65 {
                let skippedSeconds = Double(latestWhisperKitPreviewEndIndex - lastTranscribedSampleIndex) / sampleRate
                appendTailTranscription(latestWhisperKitPreviewText,
                                        endIndex: latestWhisperKitPreviewEndIndex)
                lastTranscribedSampleIndex = latestWhisperKitPreviewEndIndex
                lastClaimedSampleIndex = max(lastClaimedSampleIndex, latestWhisperKitPreviewEndIndex)
                Logger.info(
                    "Eager stop reused preview for \(String(format: "%.1f", skippedSeconds))s; tail decodes remainder only",
                    subsystem: .transcription
                )
            }

            // Reuse was rejected, so a tail decode follows. It shares the bridge with whatever
            // eager pass is still running, so drain that first rather than queueing the tail
            // behind a decode whose result is now worthless.
            await drainInFlightEagerPass()
        }

        isStopped = true

        // Abort in-flight chunk transcription on all backends
        whisper.requestAbort()

        #if canImport(WhisperKit)
        // WhisperKit cancellation must be a barrier. Its previous fire-and-forget actor
        // hop could race with resetAbort() and cancel the newly-started tail decode.
        if let wkBridge = whisper as? WhisperKitBridge {
            await wkBridge.cancelActiveTranscription()
        }
        #endif

        // Wait for in-flight chunk to complete (abort fires within ms)
        var waitCount = 0
        while isTranscribingChunk && waitCount < 40 {  // Max 400ms
            try? await Task.sleep(nanoseconds: 10_000_000)
            waitCount += 1
        }

        if isTranscribingChunk {
            Logger.warning("In-flight chunk still transcribing after 400ms, proceeding anyway", subsystem: .transcription)
        } else if waitCount > 0 {
            Logger.debug("In-flight chunk completed after \(waitCount * 10)ms", subsystem: .transcription)
        }

        // Nemotron: get complete transcript from finish(), skip tail transcription.
        #if canImport(FluidAudio)
        if let nemotron = nemotronBridge {
            // Wait for all pending feed() calls to complete before ending the session.
            // Without this, endSession() could race with in-flight feeds.
            await nemotronFeedTask?.value
            nemotronFeedTask = nil
            let durationSec = Double(totalSamplesReceived) / sampleRate
            var text = await nemotron.endSession()
            if text.isEmpty {
                // finish() threw or returned nothing. Keep previewAccumulatedText so AppState's
                // fallback (currentTranscription) can recover partial results from streaming.
                Logger.event(.asrFail, .transcription, ["reason": .string("empty_finish")], level: .warning)
            } else {
                previewAccumulatedText = ""
                if !skipCorrections {
                    text = DictionaryManager.shared.correctText(text)
                    if fillerWordRemovalEnabled { text = FillerWordFilter.removeFillers(from: text) }
                }
                completedChunkTexts = [text]
                // Nemotron returns the whole session in one blob at stop, so the span is
                // the entire recording. Consumers that need finer granularity subdivide it.
                onChunkCompleted?(TranscriptChunk(
                    text: text,
                    start: 0,
                    end: durationSec,
                    recordedDuration: durationSec
                ))
            }
            return clearAndReturn(text)
        }
        #endif

        // SpeechAnalyzer: use direct async path
        if #available(macOS 26.0, *), let speechBridge = whisper as? SpeechAnalyzerBridge {
            return await stopWithSpeechAnalyzer(speechBridge, skipCorrections: skipCorrections)
        }

        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            return await stopWithWhisperKit(wkBridge, skipCorrections: skipCorrections)
        }
        #endif

        // Dispatch stop() — which runs synchronous whisper.cpp tail inference — off the main actor.
        // By this point all in-flight chunks are done, so completedChunkTexts/allSamplesLock are stable.
        return await withCheckedContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(returning: "")
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: self.stop(skipCorrections: skipCorrections))
            }
        }
    }

    #if canImport(WhisperKit)
    private func currentRingEndIndex() -> Int? {
        do {
            return try allSamplesLock.withLock {
                ring.baseSampleIndex + ring.inMemoryCount
            }
        } catch {
            return nil
        }
    }

    /// How far the newest preview may trail the end of captured audio and still be reusable.
    ///
    /// WhisperKit re-decodes every 40ms, so its preview is never more than a hair behind and
    /// 0.40s is generous. whisper.cpp eager passes are a full-model decode of the unconfirmed
    /// window — 0.5-1s apart — so the newest preview routinely trails by more than 0.40s and
    /// that ceiling would reject nearly every V3 stop, falling back to the tail decode every
    /// time. The speech check at each call site is the real safety net: a wider *silent* gap is
    /// safe to discard, a gap containing speech is not, regardless of its length.
    private var maximumUncoveredReuseSamples: Int {
        Int((usesEagerStream ? 1.5 : 0.40) * sampleRate)
    }

    /// Wait for an eager pass that is still decoding to actually finish, after asking it to stop.
    ///
    /// `requestAbort()` is not a barrier — whisper.cpp only checks the abort callback between
    /// decoder steps, so `whisper_full` keeps running for some tens of milliseconds after the
    /// flag is set. The stop path used to set the flag and return, which left a decode live on
    /// the bridge while the caller went on to tear this transcriber down and start the next
    /// recording. A sweep of back-to-back fixtures aborted the process on a malloc free.
    ///
    /// The cost is not the latency it looks like: this only waits when a pass is genuinely in
    /// flight, and an aborting decode returns in tens of ms rather than the ~1.4s a full pass
    /// takes. The 400ms ceiling matches the in-flight-chunk drain below it.
    ///
    /// `resetAbort()` at the end matters as much as the wait — the flag is bridge state, and
    /// leaving it set would make the *next* session's first decode return -9 immediately.
    private func drainInFlightEagerPass() async {
        whisper.requestAbort()
        var waited = 0
        while isProcessing, waited < 40 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        if isProcessing {
            Logger.warning("Eager pass still decoding after 400ms at stop, proceeding anyway",
                           subsystem: .transcription)
        } else if waited > 0 {
            Logger.debug("Eager stop drained in-flight pass in \(waited * 10)ms", subsystem: .transcription)
        }
        whisper.resetAbort()
    }

    private func shouldWaitForActiveEagerPreviewAtStop() -> Bool {
        guard activeWhisperKitPreviewEndIndex > 0,
              activeWhisperKitPreviewStartIndex <= lastTranscribedSampleIndex,
              let ringEnd = currentRingEndIndex() else { return false }
        let uncoveredSamples = max(0, ringEnd - activeWhisperKitPreviewEndIndex)
        return uncoveredSamples <= maximumUncoveredReuseSamples &&
            !containsSpeech(from: activeWhisperKitPreviewEndIndex, until: ringEnd)
    }

    private func canReuseEagerPreviewAtStop() -> Bool {
        guard !latestWhisperKitPreviewText.isEmpty,
              let averageLogProbability = latestWhisperKitPreviewAverageLogProbability else {
            return false
        }

        guard let ringEnd = currentRingEndIndex() else { return false }

        let maximumUncoveredSamples = maximumUncoveredReuseSamples
        let uncoveredSamples = max(0, ringEnd - latestWhisperKitPreviewEndIndex)
        let coversUncommittedStart = latestWhisperKitPreviewStartIndex <= lastTranscribedSampleIndex
        let hasStrongConfidence = averageLogProbability >= -0.65
        let uncoveredContainsSpeech = containsSpeech(
            from: latestWhisperKitPreviewEndIndex,
            until: ringEnd
        )
        let canReuse = coversUncommittedStart &&
            whisperKitPreviewAnchoredAtTailStart &&
            (effectiveLanguage != .auto || latestWhisperKitPreviewLanguageIsLocked) &&
            uncoveredSamples <= maximumUncoveredSamples && hasStrongConfidence &&
            !uncoveredContainsSpeech

        let gapSeconds = String(format: "%.2f", Double(uncoveredSamples) / sampleRate)
        let confidence = String(format: "%.2f", averageLogProbability)
        Logger.debug(
            "Hybrid preview check: gap=\(gapSeconds)s avgLogProb=\(confidence) " +
            "gapSpeech=\(uncoveredContainsSpeech) reuse=\(canReuse)",
            subsystem: .transcription
        )
        return canReuse
    }

    private func containsSpeech(from startIndex: Int, until endIndex: Int) -> Bool {
        guard endIndex > startIndex else { return false }
        let samples: [Float]
        do {
            samples = try allSamplesLock.withLock {
                ring.slice(fromAbsolute: startIndex, toAbsolute: endIndex)
            }
        } catch {
            return true
        }
        guard !samples.isEmpty else { return false }
        if let vad {
            return vad.hasSpeech(samples: samples)
        }
        return hasEnergy(samples)
    }

    /// WhisperKit-specific final pass stays async end-to-end. This avoids the synchronous
    /// TranscriptionBackend semaphore and guarantees the cancelled chunk is fully drained
    /// before the tail decode starts.
    private func stopWithWhisperKit(
        _ wkBridge: WhisperKitBridge,
        skipCorrections: Bool
    ) async -> String {
        wkBridge.clearCallbacks()
        provisionalChunkText = ""
        currentChunkGeneration &+= 1
        pendingChunks.removeAll()

        // The rolling preview has already paid for the expensive high-quality decode
        // of most of the uncommitted tail. Reconcile only the audio that arrived after
        // that snapshot (plus a short word-boundary overlap) instead of decoding the
        // complete tail again. Both pieces come from the same WhisperKit model.
        if let reconciliation = await prepareWhisperKitTailReconciliation(bridge: wkBridge) {
            wkBridge.resetAbort()
            let suffix = await wkBridge.transcribeStreamingAsync(
                samples: reconciliation.samples,
                language: effectiveLanguage,
                clipSeconds: 0,
                prefixTokens: reconciliation.prefixTokens,
                maxTokens: 64
            )
            if let suffix,
               let stitched = stitchWhisperKitTimestampedTail(
                prefix: reconciliation.prefix,
                suffix: suffix,
                boundarySeconds: reconciliation.boundarySeconds
            ) {
                Logger.info(
                    "Hybrid stop timestamp-reconciled \(String(format: "%.1f", reconciliation.duration))s " +
                    "of the release tail (saved \(String(format: "%.1f", reconciliation.savedDuration))s)",
                    subsystem: .transcription
                )
                appendTailTranscription(stitched)
                return finalizeCompletedChunks(skipCorrections: skipCorrections)
            }
            Logger.debug("Hybrid tail reconciliation returned no usable suffix; using full tail", subsystem: .transcription)
        }

        guard let input = prepareTailTranscription() else {
            return finalizeCompletedChunks(skipCorrections: skipCorrections)
        }

        wkBridge.resetAbort()
        let text = await wkBridge.transcribeDirectAsync(
            samples: input.samples,
            initialPrompt: input.prompt,
            language: effectiveLanguage
        )
        Logger.debug("WhisperKit tail transcription returned \(text.count) chars", subsystem: .transcription)
        appendTailTranscription(text)
        return finalizeCompletedChunks(skipCorrections: skipCorrections)
    }

    private func prepareWhisperKitTailReconciliation(bridge: WhisperKitBridge) async -> (
        samples: [Float], prefix: String, prefixTokens: [Int]?,
        boundarySeconds: Float, duration: Double, savedDuration: Double
    )? {
        guard !latestWhisperKitPreviewText.isEmpty,
              let confidence = latestWhisperKitPreviewAverageLogProbability,
              confidence >= -0.65,
              whisperKitPreviewAnchoredAtTailStart,
              (effectiveLanguage != .auto || latestWhisperKitPreviewLanguageIsLocked),
              latestWhisperKitPreviewStartIndex <= lastTranscribedSampleIndex else {
            return nil
        }

        let overlapSamples = Int(0.8 * sampleRate)
        let maximumGapSamples = Int(2.0 * sampleRate)
        var samples: [Float] = []
        var ringEnd = 0
        var reconciliationStart = 0
        do {
            try allSamplesLock.withLock {
                ringEnd = ring.baseSampleIndex + ring.inMemoryCount
                let gap = max(0, ringEnd - latestWhisperKitPreviewEndIndex)
                guard gap > Int(0.20 * sampleRate), gap <= maximumGapSamples else { return }
                reconciliationStart = max(
                    lastTranscribedSampleIndex,
                    latestWhisperKitPreviewEndIndex - overlapSamples
                )
                samples = ring.slice(fromAbsolute: reconciliationStart, toAbsolute: ringEnd)
            }
        } catch {
            return nil
        }
        guard !samples.isEmpty, ringEnd > reconciliationStart, hasEnergy(samples) else { return nil }

        let fullTailDuration = Double(ringEnd - lastTranscribedSampleIndex) / sampleRate
        let duration = Double(samples.count) / sampleRate
        let boundarySeconds = Float(latestWhisperKitPreviewEndIndex - reconciliationStart) /
            Float(sampleRate)
        // Encode last 10 confirmed words for richer decoder context (30-50 tokens).
        // Falls back to the 2-word boundary tokens if encoding fails or produces nothing.
        let contextWords = latestWhisperKitPreviewText
            .split(whereSeparator: { $0.isWhitespace }).suffix(10).joined(separator: " ")
        let prefixTokens: [Int]?
        if !contextWords.isEmpty,
           let encoded = await bridge.encodeText(contextWords), !encoded.isEmpty {
            prefixTokens = encoded
        } else {
            let stored = eagerEngine?.prefixTokens ?? []
            prefixTokens = stored.isEmpty ? nil : stored
        }
        Logger.debug(
            "Hybrid tail reconciliation: gap=" +
            "\(String(format: "%.2f", Double(ringEnd - latestWhisperKitPreviewEndIndex) / sampleRate))s " +
            "decode=\(String(format: "%.2f", duration))s " +
            "boundary=\(String(format: "%.2f", boundarySeconds))s",
            subsystem: .transcription
        )
        return (
            normalizeSamples(samples), latestWhisperKitPreviewText, prefixTokens,
            boundarySeconds,
            duration, max(0, fullTailDuration - duration)
        )
    }

    /// Join by acoustic time, not by an assumed text match. The suffix decode includes
    /// 800ms of overlap, so only words beginning at/after the cached preview boundary
    /// are new. Text overlap is still removed when present, but is never required.
    private func stitchWhisperKitTimestampedTail(
        prefix: String,
        suffix: WhisperKitStreamingResult,
        boundarySeconds: Float
    ) -> String? {
        guard suffix.averageLogProbability.map({ $0 >= -0.8 }) ?? false else {
            Logger.debug("Hybrid timestamped suffix rejected for low confidence", subsystem: .transcription)
            return nil
        }

        let prefixWords = prefix.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let suffixWords = suffix.words.map(\.text)
        guard !prefixWords.isEmpty, !suffixWords.isEmpty else { return nil }

        func normalized(_ word: String) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        let maximumOverlap = min(15, prefixWords.count, suffixWords.count)
        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            let left = prefixWords.suffix(count).map(normalized)
            let right = suffixWords.prefix(count).map(normalized)
            guard !left.contains(where: { $0.isEmpty }) else { continue }
            if left == right {
                // Replace the acoustic overlap with the final suffix decode instead
                // of retaining provisional punctuation at the seam.
                let stablePrefix = prefixWords.dropLast(count).joined(separator: " ")
                let replacement = suffixWords.joined()
                let combined = joinWhisperKitText(stablePrefix, replacement)
                guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !isHallucination(combined) else { return nil }
                Logger.debug(
                    "Hybrid timestamped suffix replaced \(count)-word acoustic overlap",
                    subsystem: .transcription
                )
                return combined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Word timestamps are relative to the reconciliation audio. A word spoken
        // across the cached-preview boundary is new final evidence even though its
        // start timestamp belongs to the overlap. Using only `start` discarded that
        // word and unnecessarily triggered a second full-tail decode at release.
        let boundaryTolerance: Float = 0.05
        var newWords = suffix.words.filter {
            $0.end > boundarySeconds + boundaryTolerance
        }

        // If the first retained word crosses the boundary, replace the provisional
        // final prefix word with the final decode. This avoids both duplicating it
        // and preserving stale punctuation. Keep the conservative append behavior
        // for scripts without whitespace-delimited words.
        var stablePrefix = prefix
        if let firstNew = newWords.first,
           firstNew.start < boundarySeconds - boundaryTolerance,
           prefixWords.count > 1 {
            stablePrefix = prefixWords.dropLast().joined(separator: " ")
        }
        if let lastPrefix = prefixWords.last, let firstNew = newWords.first,
           normalized(lastPrefix) == normalized(firstNew.text) {
            newWords.removeFirst()
            stablePrefix = prefix
        }
        let addition = newWords.map(\.text).joined()
        guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.debug("Hybrid timestamped suffix had no words beyond boundary", subsystem: .transcription)
            return nil
        }
        let combined = joinWhisperKitText(stablePrefix, addition)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isHallucination(combined) else { return nil }
        Logger.debug(
            "Hybrid timestamped suffix reconciled \(newWords.count) boundary/post-boundary words",
            subsystem: .transcription
        )
        return combined
    }

    private func joinWhisperKitText(_ prefix: String, _ addition: String) -> String {
        guard !prefix.isEmpty else { return addition }
        guard !addition.isEmpty else { return prefix }
        if prefix.last?.isWhitespace == true || addition.first?.isWhitespace == true {
            return prefix + addition
        }
        // Whisper word timings normally preserve their leading whitespace. If a model
        // omits it, add a separator only for adjacent ASCII word characters; CJK and
        // punctuation must retain their native no-space formatting.
        if let left = prefix.unicodeScalars.last,
           let right = addition.unicodeScalars.first,
           left.value < 128, right.value < 128,
           CharacterSet.alphanumerics.contains(left),
           CharacterSet.alphanumerics.contains(right) {
            return prefix + " " + addition
        }
        return prefix + addition
    }

    /// Preserve text that falls off the front of WhisperKit's capped rolling window.
    /// Finds a stable word sequence shared by the previous hypothesis and the new
    /// shifted window, then replaces the overlapping region with the newer decode.
    private func mergeWhisperKitRollingPreview(previous: String, newWindow: String) -> String? {
        let previousWords = previous.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newWords = newWindow.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !previousWords.isEmpty, !newWords.isEmpty else { return nil }

        func normalized(_ word: String) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        let previousSearchStart = max(0, previousWords.count - 40)
        let newSearchEnd = min(newWords.count, 40)
        let normalizedPrevious = previousWords.map(normalized)
        let normalizedNew = newWords.map(normalized)
        var bestPreviousIndex = 0
        var bestNewIndex = 0
        var bestLength = 0

        // Prefer an anchor nearest the beginning of the new window. Choosing a later,
        // longer match can align to a repeated phrase (for example "it should be") and
        // accidentally discard valid words immediately before it.
        for newIndex in 0..<newSearchEnd {
            var bestLengthAtThisOffset = 0
            var bestPreviousAtThisOffset = 0
            for previousIndex in previousSearchStart..<previousWords.count {
                var length = 0
                while previousIndex + length < normalizedPrevious.count,
                      newIndex + length < normalizedNew.count,
                      !normalizedPrevious[previousIndex + length].isEmpty,
                      normalizedPrevious[previousIndex + length] == normalizedNew[newIndex + length] {
                    length += 1
                }
                if length > bestLengthAtThisOffset {
                    bestPreviousAtThisOffset = previousIndex
                    bestLengthAtThisOffset = length
                }
            }
            if bestLengthAtThisOffset >= 2 {
                bestPreviousIndex = bestPreviousAtThisOffset
                bestNewIndex = newIndex
                bestLength = bestLengthAtThisOffset
                break
            }
        }

        // Two matching consecutive words are enough to establish the time-shifted
        // window boundary while avoiding accidental one-word joins.
        guard bestLength >= 2 else { return nil }
        let estimatedNewStart = max(0, bestPreviousIndex - bestNewIndex)
        return (Array(previousWords.prefix(estimatedNewStart)) + newWords).joined(separator: " ")
    }

    private func prepareTailTranscription() -> (samples: [Float], prompt: String?)? {
        var ringContent: [Float] = []
        var ringBase = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch {
            Logger.error("Failed to acquire lock for tail transcription", subsystem: .transcription)
            return nil
        }

        let tailRelIndex = max(0, lastTranscribedSampleIndex - ringBase)
        guard let tailChunk = vadSegmenter.finalizeTail(
            allSamples: ringContent,
            lastTranscribedIndex: tailRelIndex
        ) else {
            Logger.debug("No tail audio to transcribe", subsystem: .transcription)
            return nil
        }
        guard hasEnergy(tailChunk.samples) else {
            Logger.debug("Tail audio has no energy, skipping", subsystem: .transcription)
            return nil
        }
        // Same hallucinated-filler screen as `transcribeTail` — see the comment there.
        if usesEagerStream, let vad, !vad.hasSpeech(samples: tailChunk.samples) {
            Logger.debug("Eager tail has no speech, skipping", subsystem: .transcription)
            return nil
        }

        let duration = Double(tailChunk.endSample - tailChunk.startSample) / sampleRate
        Logger.debug("Transcribing tail asynchronously: \(String(format: "%.1f", duration))s", subsystem: .transcription)

        let prompt: String?
        if let previous = completedChunkTexts.last, !previous.isEmpty {
            let prefix = initialPrompt.map { $0.isEmpty ? "" : $0 + " " } ?? ""
            prompt = prefix + String(previous.suffix(100))
        } else {
            prompt = initialPrompt
        }
        return (normalizeSamples(tailChunk.samples), prompt)
    }

    /// Append a decoded span to the committed chunk list and publish it.
    ///
    /// - Parameter endIndex: absolute sample index this text runs to. Defaults to `nil`, meaning
    ///   the end of the captured audio, which is right for the genuine tail — the tail is by
    ///   definition everything not yet committed. It is *wrong* for the partial-reuse branch of
    ///   the eager stop, which credits a preview covering only part of the remainder and then
    ///   decodes the rest as a second chunk. Passing the default there stamped the preview chunk
    ///   as `[lastCommitted, recordedDuration]` and the following tail as
    ///   `[previewEnd, recordedDuration]`, so the two overlapped by everything between them.
    ///   The regression gate caught this on four of eight fixtures once it was feeding correctly
    ///   — `4.30s starts before prev end 19.97s`, where 4.3s is exactly the reuse boundary the
    ///   log reports as "reused preview for 4.3s". Overlapping spans are what meeting transcript
    ///   cards and scroll-to-timestamp read, so this was wrong on screen, not only in the test.
    private func appendTailTranscription(_ result: String, endIndex: Int? = nil) {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isHallucination(text) else { return }

        let deduped: String
        if let previous = completedChunkTexts.last, !previous.isEmpty {
            deduped = VADSegmenter.deduplicateOverlap(previousText: previous, newText: text)
        } else {
            deduped = text
        }
        guard !deduped.isEmpty else { return }
        completedChunkTexts.append(deduped)
        // Spans from the last commit boundary to `endIndex`, or to the end of the captured audio
        // when the caller did not narrow it. Clamped below the recording end and above the start
        // so a stale index can never produce an inverted span.
        let startSeconds = Double(lastTranscribedSampleIndex) / sampleRate
        let endSeconds = endIndex.map {
            min(recordedDuration, max(startSeconds, Double($0) / sampleRate))
        } ?? recordedDuration
        onChunkCompleted?(TranscriptChunk(
            text: deduped,
            start: startSeconds,
            end: endSeconds,
            recordedDuration: recordedDuration
        ))
    }

    private func finalizeCompletedChunks(skipCorrections: Bool) -> String {
        var rawText = completedChunkTexts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Never return empty while live text is on screen.
        //
        // On the eager path the committed chunks only exist once a soft-commit has fired, which
        // needs the agreement boundary to run 6s past the last commit. A recording where that
        // never happened — because the decoder fell behind, or the tail decode came back with
        // nothing — reaches here with no chunks at all, and the user watches a screenful of live
        // text vanish on key release. Measured: a 204s dictation that published 143 display
        // updates returned the empty string (`EagerStreamProfileTests`, WER 1.000).
        //
        // `previewAccumulatedText` is the last full hypothesis — what is on screen, or a superset
        // of it when `eagerPublishesSpeculativeTail` is off. Either way it is append-only, so falling
        // back to it cannot duplicate anything already in `rawText` — this only runs when
        // `rawText` is empty.
        if rawText.isEmpty {
            let live = previewAccumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !live.isEmpty {
                Logger.warning("No committed chunks at stop — falling back to live preview text (\(live.count) chars)",
                               subsystem: .transcription)
                rawText = live
            }
        }
        guard !rawText.isEmpty else { return clearAndReturn("") }

        var result = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
        if fillerWordRemovalEnabled {
            result = FillerWordFilter.removeFillers(from: result)
        }
        return clearAndReturn(result)
    }
    #endif

    /// SpeechAnalyzer-specific async final pass
    @available(macOS 26.0, *)
    private func stopWithSpeechAnalyzer(_ speechBridge: SpeechAnalyzerBridge, skipCorrections: Bool = false) async -> String {
        isProcessing = false

        // If samples were pruned (long recording), the ring only holds the recent tail.
        // SpeechAnalyzer can't re-transcribe the full session — fall through to chunk-based text.
        var wasPruned: Bool = false
        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                wasPruned = totalSamplesReceived > ring.inMemoryCount
                allSamples = ring.toArray()
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in stopWithSpeechAnalyzer", subsystem: .transcription)
        }

        if wasPruned {
            Logger.info("SpeechAnalyzer skipped — audio was pruned during long recording; using chunk-based text", subsystem: .transcription)
            transcribeTail()
            let rawText = fullTranscription
            guard !rawText.isEmpty else { return clearAndReturn("") }
            var result = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
            if fillerWordRemovalEnabled {
                result = FillerWordFilter.removeFillers(from: result)
            }
            return clearAndReturn(result)
        }

        let totalDuration = Double(allSamples.count) / sampleRate
        Logger.debug("SpeechAnalyzer final pass (async): \(String(format: "%.1f", totalDuration))s of audio", subsystem: .transcription)

        let minSamples = Int(0.3 * sampleRate)
        guard allSamples.count >= minSamples else {
            return clearAndReturn("")
        }

        if !hasEnergy(allSamples) {
            return clearAndReturn("")
        }

        let finalPassResult = await speechBridge.transcribeDirectAsync(
            samples: allSamples,
            language: language
        )

        let rawText: String
        if !finalPassResult.isEmpty {
            rawText = finalPassResult
        } else {
            rawText = fullTranscription
        }

        var finalResult: String
        if !rawText.isEmpty {
            finalResult = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
            if fillerWordRemovalEnabled {
                finalResult = FillerWordFilter.removeFillers(from: finalResult)
            }
        } else {
            finalResult = ""
        }

        return clearAndReturn(finalResult)
    }

    // MARK: - Audio Normalization

    /// Peak-normalize samples to target amplitude for consistent Whisper input levels.
    /// Quiet recordings benefit significantly from normalization — Whisper's encoder
    /// produces stronger activations with higher-amplitude input.
    private func normalizeSamples(_ samples: [Float], targetPeak: Float = 0.707) -> [Float] {
        guard !samples.isEmpty else { return samples }

        var maxVal: Float = 0
        vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))

        // Skip if effectively silent (below noise floor)
        guard maxVal > 0.001 else { return samples }
        // Skip if already near target level
        guard maxVal < targetPeak * 0.9 else { return samples }

        let gain = targetPeak / maxVal
        // Cap gain to prevent amplifying noise in very quiet recordings
        let cappedGain = min(gain, 20.0)  // Max 20x boost (~26dB)

        var result = [Float](repeating: 0, count: samples.count)
        var gainVar = cappedGain
        vDSP_vsmul(samples, 1, &gainVar, &result, 1, vDSP_Length(samples.count))

        Logger.debug("Audio normalized: peak \(String(format: "%.4f", maxVal)) → \(String(format: "%.4f", maxVal * cappedGain)), gain \(String(format: "%.1f", cappedGain))x", subsystem: .transcription)

        return result
    }

    // MARK: - Energy Detection

    private func hasEnergy(_ samples: [Float], threshold: Float = 0.003) -> Bool {
        guard !samples.isEmpty else { return false }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        let rms = sqrt(meanSquare)
        return rms > threshold
    }

    // MARK: - Public Properties

    var currentTranscription: String {
        #if canImport(FluidAudio)
        // For Nemotron, fullTranscription is only populated after finish() in stopAsync().
        // previewAccumulatedText holds the last partial pushed by the callback — use it
        // as fallback so AppState's empty-result path can recover streaming text.
        if nemotronBridge != nil && !previewAccumulatedText.isEmpty {
            return previewAccumulatedText
        }
        #endif
        return fullTranscription
    }

    var recordedDuration: Double {
        // totalSamplesReceived is written only in addSamples under allSamplesLock,
        // but reading a single Int is safe without locking here.
        return Double(totalSamplesReceived) / sampleRate
    }

    /// Trim non-speech prefix from audio samples (removes feedback sound capture)
    /// Uses VAD to find first speech onset and trims everything before it
    private func trimLeadingNonSpeech(_ samples: [Float]) -> [Float] {
        guard let vad = vad else { return samples }  // No VAD = no trim

        // Only analyze first 300ms (4800 samples at 16kHz)
        let analysisWindow = min(samples.count, Int(0.3 * sampleRate))
        guard analysisWindow > Int(0.1 * sampleRate) else { return samples }  // Too short to trim

        let windowSamples = Array(samples.prefix(analysisWindow))
        let segments = vad.detectSpeechSegments(samples: windowSamples)

        guard let firstSegment = segments.first else {
            // No speech in first 300ms — trim the feedback sound window
            if samples.count > feedbackSoundSamples {
                Logger.debug("No speech in first 300ms, trimming \(feedbackSoundSamples) samples", subsystem: .transcription)
                return Array(samples.dropFirst(feedbackSoundSamples))
            }
            return samples
        }

        // Find first speech onset sample
        let speechStartSample = firstSegment.startSample

        // Apply 50ms lookback for natural speech attack
        let lookbackSamples = Int(0.05 * sampleRate)  // 800 samples
        let trimPoint = max(0, speechStartSample - lookbackSamples)

        if trimPoint > 0 {
            Logger.debug("Trimming \(trimPoint) samples (\(Int(Double(trimPoint) / sampleRate * 1000))ms) of leading non-speech", subsystem: .transcription)
            return Array(samples.dropFirst(trimPoint))
        }

        return samples
    }

    /// Save the recorded audio to `url`.
    ///
    /// The session file is already written in the archive format, so this is a copy —
    /// there is no transcode step and no second encode of the same audio. Falls back to
    /// writing the in-memory ring buffer for very short recordings that were never pruned.
    func saveRecording(to url: URL) -> Bool {
        // Prefer the complete disk-backed session file
        if let srcURL = sessionAudioURL, FileManager.default.fileExists(atPath: srcURL.path) {
            do {
                if AudioArchiveFormat.isAlreadyArchived(srcURL) {
                    try FileManager.default.copyItem(at: srcURL, to: url)
                    Logger.step(.recStop, .transcription, ["via": .string("copy")])
                    return true
                }
                // A session file left over from a pre-Opus build — encode it once on the way out.
                try AudioArchiveFormat.transcode(from: srcURL, to: url)
                Logger.step(.recStop, .transcription, ["via": .string("transcode")])
                return true
            } catch {
                Logger.error("Failed to save recording from disk: \(error.localizedDescription)", subsystem: .transcription)
                return false
            }
        }

        // Fallback: write ring buffer (short recordings not yet pruned)
        var samples: [Float] = []
        do {
            try allSamplesLock.withLock {
                samples = ring.toArray()
            }
        } catch {
            Logger.error("Failed to acquire lock for saveRecording: \(error.localizedDescription)", subsystem: .transcription)
            return false
        }

        guard !samples.isEmpty else {
            Logger.warning("No audio samples to save", subsystem: .transcription)
            return false
        }

        samples = trimLeadingNonSpeech(samples)

        let format = AudioArchiveFormat.pcmFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            Logger.error("Failed to create audio buffer", subsystem: .transcription)
            return false
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }

        do {
            let writer = try AudioArchiveFormat.makeWriter(at: url)
            try writer.write(buffer)
            writer.close()
            Logger.step(.recStop, .transcription, ["via": .string("ring_buffer")])
            return true
        } catch {
            Logger.error("Failed to save recording: \(error.localizedDescription)", subsystem: .transcription)
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    // MARK: - Language Routing

    /// Perform initial language detection and model routing.
    /// Returns true if detection was actually attempted (voiced audio sufficient).
    @discardableResult
    private func performLanguageDetection(
        samples: [Float],
        pool: ModelPool,
        langRouter: LanguageRouter,
        mdlRouter: ModelRouter
    ) -> Bool {
        // VAD-filter detection audio — extract voiced segments only (single allocation)
        var detectionSamples = samples
        let isShortWindow: Bool
        if let vad = vad {
            let segments = vad.detectSpeechSegments(samples: samples)
            let totalVoiced = segments.reduce(0) { acc, seg in
                acc + min(seg.endSample, samples.count) - min(seg.startSample, samples.count)
            }
            let minVoiced = RoutingThresholds.minVoicedDetectionSamples
            guard totalVoiced >= minVoiced else {
                Logger.debug("Detection skipped: \(totalVoiced) voiced samples < \(minVoiced) required", subsystem: .transcription)
                return false
            }
            var voiced = [Float]()
            voiced.reserveCapacity(totalVoiced)
            for seg in segments {
                let start = min(seg.startSample, samples.count)
                let end = min(seg.endSample, samples.count)
                voiced.append(contentsOf: samples[start..<end])
            }
            detectionSamples = voiced
            isShortWindow = totalVoiced < RoutingThresholds.targetDetectionSamples
        } else {
            isShortWindow = samples.count < RoutingThresholds.targetDetectionSamples
        }

        // Detect language from audio
        guard let allProbs = pool.detectLanguage(samples: detectionSamples) else {
            Logger.warning("Language detection returned nil, using configured language", subsystem: .transcription)
            return true  // Detection was attempted but failed
        }

        // Route through language classifier (no transcript yet — initial routing)
        guard let langDecision = langRouter.decide(allProbs: allProbs, transcriptText: "", shortWindow: isShortWindow) else {
            Logger.debug("Language router undecided, using configured language", subsystem: .transcription)
            return true  // Detection was attempted
        }

        // Resolve to model profile
        let modelDecision = mdlRouter.resolve(decision: langDecision, warmProfiles: pool.warmProfiles)
        routeDecision = modelDecision

        // Notify live preview of detected language
        let detectedLang = langDecision.lang
        DispatchQueue.main.async { [weak self] in
            self?.onLanguageDetected?(detectedLang)
        }

        // Apply routing decision
        let activation = pool.routeTarget(for: modelDecision.profile)
        switch activation {
        case .warm(let backend):
            self.whisper = backend
            Logger.info("Routed to \(modelDecision.profile.model.displayName) for \(modelDecision.lang.displayName) (warm)", subsystem: .transcription)

        case .fallback(let fallbackBackend, let loadingTask):
            self.whisper = fallbackBackend
            Logger.info("Using fallback, loading \(modelDecision.profile.model.displayName) for \(modelDecision.lang.displayName)", subsystem: .transcription)

            // Deliver promotion result via serial promotionQueue
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let backend = try await loadingTask.value
                    self.promotionQueue.sync {
                        self.pendingPromotion = (backend, modelDecision.profile)
                    }
                } catch {
                    Logger.error("Failed to load target model: \(error)", subsystem: .transcription)
                }
            }
        }
        return true
    }

    /// Drain promotion queue and swap backend if promotion is ready
    private func drainPromotionQueue() {
        var promotion: (backend: TranscriptionBackend, profile: ModelProfile)?
        promotionQueue.sync { [self] in
            promotion = pendingPromotion
            pendingPromotion = nil
        }
        guard let promotion else { return }

        self.whisper = promotion.backend
        if var decision = routeDecision {
            // Update decision to reflect non-fallback status
            routeDecision = ModelRouteDecision(
                lang: decision.lang,
                profile: promotion.profile,
                confidence: decision.confidence,
                isFallback: false
            )
        }
        Logger.info("Promoted to \(promotion.profile.model.displayName) at chunk boundary", subsystem: .transcription)
    }

    /// Post-chunk script stabilizer — check if transcript script matches locked language
    private func checkScriptStability(chunkText: String) {
        guard let langRouter = languageRouter,
              let pool = modelPool,
              let mdlRouter = modelRouter,
              case .locked(let lockedLang) = langRouter.state else { return }

        let scriptHints = ScriptAnalyzer.dominantScript(in: chunkText, allowedLanguages: langRouter.allowedLanguages)
        guard !scriptHints.isEmpty else { return }

        // Check if dominant script disagrees with locked language
        let topScript = scriptHints.max(by: { $0.value < $1.value })
        if let top = topScript, top.key != lockedLang, top.value > 0.5 {
            scriptMismatchCount += 1
            Logger.debug("Script mismatch \(scriptMismatchCount): \(top.key.displayName) script vs locked \(lockedLang.displayName)", subsystem: .transcription)
        } else {
            // Reset on match
            scriptMismatchCount = 0
        }

        // Combine script + chunk-lang evidence (chunk-lang is weak — needs 5+ to trigger alone)
        let combinedMismatches = scriptMismatchCount + (chunkLangMismatchCount / 2)
        if langRouter.shouldRedetect(scriptMismatches: combinedMismatches, newUtteranceAfterSilence: newUtteranceAfterSilence) {
            newUtteranceAfterSilence = false  // Consume the signal
            scriptMismatchCount = 0
            chunkLangMismatchCount = 0

            // Get latest audio for re-detection (2s window from ring)
            var latestSamples: [Float] = []
            do {
                try allSamplesLock.withLock {
                    let targetSamples = 32000
                    let endIdx = ring.endAbsoluteIndex
                    let startIdx = max(ring.baseSampleIndex, endIdx - targetSamples)
                    if endIdx - startIdx >= targetSamples {
                        latestSamples = ring.slice(fromAbsolute: startIdx, toAbsolute: endIdx)
                    }
                }
            } catch { return }

            guard !latestSamples.isEmpty,
                  let allProbs = pool.detectLanguage(samples: latestSamples) else { return }

            let accumulatedText = completedChunkTexts.joined(separator: " ")
            if let newDecision = langRouter.decide(allProbs: allProbs, transcriptText: accumulatedText) {
                let modelDecision = mdlRouter.resolve(decision: newDecision, warmProfiles: pool.warmProfiles)

                // If language changed, schedule model swap
                if modelDecision.lang != routeDecision?.lang || modelDecision.profile != routeDecision?.profile {
                    routeDecision = modelDecision
                    let activation = pool.routeTarget(for: modelDecision.profile)
                    switch activation {
                    case .warm(let backend):
                        // Will swap at next chunk boundary via drainPromotionQueue
                        promotionQueue.sync { [self] in
                            pendingPromotion = (backend, modelDecision.profile)
                        }
                    case .fallback(_, let loadingTask):
                        Task.detached(priority: .userInitiated) { [weak self] in
                            guard let self else { return }
                            if let backend = try? await loadingTask.value {
                                self.promotionQueue.sync {
                                    self.pendingPromotion = (backend, modelDecision.profile)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - HealthReportable

extension StreamingTranscriber: HealthReportable {

    var componentName: String { "StreamingTranscriber" }

    var healthState: ComponentHealth {
        let seq = transcriptionProgressCounter
        let now = ContinuousClock.now

        guard let opName = stCurrentOp else {
            var h = ComponentHealth()
            h.progress = ProgressInfo(sequence: seq, completedWork: 1.0, lastUpdate: now)
            return h
        }

        let deadline = stOpDeadline
        let status: ComponentStatus
        if now < deadline {
            status = .healthy
        } else if isTranscribingChunk {
            status = .busy  // waiting on WhisperBridge
        } else {
            status = .stalled
        }

        var op = OperationInfo(
            id: stOpID,
            name: opName,
            started: stOpStart,
            deadline: deadline,
            queueBacklog: pendingChunks.count
        )
        op.deadline = deadline

        var h = ComponentHealth()
        h.status = status
        h.operation = op
        h.progress = ProgressInfo(sequence: seq, completedWork: isTranscribingChunk ? 0.5 : 1.0, lastUpdate: now)
        h.dependencies = isTranscribingChunk ? ["WhisperBridge"] : []
        h.metadata = ["backlog": .int(pendingChunks.count), "isStopped": .bool(isStopped)]
        return h
    }
}

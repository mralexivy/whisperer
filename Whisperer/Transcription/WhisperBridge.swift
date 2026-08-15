//
//  WhisperBridge.swift
//  Whisperer
//
//  Swift wrapper for whisper.cpp C library
//

import CryptoKit
import Foundation

// MARK: - Transcription Language

enum TranscriptionLanguage: String, CaseIterable, Codable {
    case auto = "auto"
    case afrikaans = "af"
    case albanian = "sq"
    case amharic = "am"
    case arabic = "ar"
    case armenian = "hy"
    case assamese = "as"
    case azerbaijani = "az"
    case bashkir = "ba"
    case basque = "eu"
    case belarusian = "be"
    case bengali = "bn"
    case bosnian = "bs"
    case breton = "br"
    case bulgarian = "bg"
    case burmese = "my"
    case catalan = "ca"
    case chinese = "zh"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case english = "en"
    case estonian = "et"
    case faroese = "fo"
    case finnish = "fi"
    case french = "fr"
    case galician = "gl"
    case georgian = "ka"
    case german = "de"
    case greek = "el"
    case gujarati = "gu"
    case haitian = "ht"
    case hausa = "ha"
    case hawaiian = "haw"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case icelandic = "is"
    case indonesian = "id"
    case irish = "ga"
    case italian = "it"
    case japanese = "ja"
    case javanese = "jw"
    case kannada = "kn"
    case kazakh = "kk"
    case khmer = "km"
    case korean = "ko"
    case lao = "lo"
    case latin = "la"
    case latvian = "lv"
    case lingala = "ln"
    case lithuanian = "lt"
    case luxembourgish = "lb"
    case macedonian = "mk"
    case malagasy = "mg"
    case malay = "ms"
    case malayalam = "ml"
    case maltese = "mt"
    case maori = "mi"
    case marathi = "mr"
    case mongolian = "mn"
    case nepali = "ne"
    case norwegian = "no"
    case nynorsk = "nn"
    case occitan = "oc"
    case pashto = "ps"
    case persian = "fa"
    case polish = "pl"
    case portuguese = "pt"
    case punjabi = "pa"
    case romanian = "ro"
    case russian = "ru"
    case sanskrit = "sa"
    case serbian = "sr"
    case shona = "sn"
    case sindhi = "sd"
    case sinhala = "si"
    case slovak = "sk"
    case slovenian = "sl"
    case somali = "so"
    case spanish = "es"
    case sundanese = "su"
    case swahili = "sw"
    case swedish = "sv"
    case tagalog = "tl"
    case tajik = "tg"
    case tamil = "ta"
    case tatar = "tt"
    case telugu = "te"
    case thai = "th"
    case tibetan = "bo"
    case turkish = "tr"
    case turkmen = "tk"
    case ukrainian = "uk"
    case urdu = "ur"
    case uzbek = "uz"
    case vietnamese = "vi"
    case welsh = "cy"
    case yiddish = "yi"
    case yoruba = "yo"

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .afrikaans: return "Afrikaans"
        case .albanian: return "Albanian"
        case .amharic: return "Amharic"
        case .arabic: return "Arabic"
        case .armenian: return "Armenian"
        case .assamese: return "Assamese"
        case .azerbaijani: return "Azerbaijani"
        case .bashkir: return "Bashkir"
        case .basque: return "Basque"
        case .belarusian: return "Belarusian"
        case .bengali: return "Bengali"
        case .bosnian: return "Bosnian"
        case .breton: return "Breton"
        case .bulgarian: return "Bulgarian"
        case .burmese: return "Burmese"
        case .catalan: return "Catalan"
        case .chinese: return "Chinese"
        case .croatian: return "Croatian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutch: return "Dutch"
        case .english: return "English"
        case .estonian: return "Estonian"
        case .faroese: return "Faroese"
        case .finnish: return "Finnish"
        case .french: return "French"
        case .galician: return "Galician"
        case .georgian: return "Georgian"
        case .german: return "German"
        case .greek: return "Greek"
        case .gujarati: return "Gujarati"
        case .haitian: return "Haitian Creole"
        case .hausa: return "Hausa"
        case .hawaiian: return "Hawaiian"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .icelandic: return "Icelandic"
        case .indonesian: return "Indonesian"
        case .irish: return "Irish"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .javanese: return "Javanese"
        case .kannada: return "Kannada"
        case .kazakh: return "Kazakh"
        case .khmer: return "Khmer"
        case .korean: return "Korean"
        case .lao: return "Lao"
        case .latin: return "Latin"
        case .latvian: return "Latvian"
        case .lingala: return "Lingala"
        case .lithuanian: return "Lithuanian"
        case .luxembourgish: return "Luxembourgish"
        case .macedonian: return "Macedonian"
        case .malagasy: return "Malagasy"
        case .malay: return "Malay"
        case .malayalam: return "Malayalam"
        case .maltese: return "Maltese"
        case .maori: return "Maori"
        case .marathi: return "Marathi"
        case .mongolian: return "Mongolian"
        case .nepali: return "Nepali"
        case .norwegian: return "Norwegian"
        case .nynorsk: return "Norwegian Nynorsk"
        case .occitan: return "Occitan"
        case .pashto: return "Pashto"
        case .persian: return "Persian"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .punjabi: return "Punjabi"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .sanskrit: return "Sanskrit"
        case .serbian: return "Serbian"
        case .shona: return "Shona"
        case .sindhi: return "Sindhi"
        case .sinhala: return "Sinhala"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .somali: return "Somali"
        case .spanish: return "Spanish"
        case .sundanese: return "Sundanese"
        case .swahili: return "Swahili"
        case .swedish: return "Swedish"
        case .tagalog: return "Tagalog"
        case .tajik: return "Tajik"
        case .tamil: return "Tamil"
        case .tatar: return "Tatar"
        case .telugu: return "Telugu"
        case .thai: return "Thai"
        case .tibetan: return "Tibetan"
        case .turkish: return "Turkish"
        case .turkmen: return "Turkmen"
        case .ukrainian: return "Ukrainian"
        case .urdu: return "Urdu"
        case .uzbek: return "Uzbek"
        case .vietnamese: return "Vietnamese"
        case .welsh: return "Welsh"
        case .yiddish: return "Yiddish"
        case .yoruba: return "Yoruba"
        }
    }

    /// Whether this language uses right-to-left script
    var isRTL: Bool {
        switch self {
        case .arabic, .hebrew, .persian, .urdu, .pashto, .sindhi, .yiddish:
            return true
        default:
            return false
        }
    }

    /// Convert to Locale for SpeechAnalyzer. Returns nil for .auto (use Locale.current).
    var locale: Locale? {
        guard self != .auto else { return nil }
        return Locale(identifier: rawValue)
    }
}

// MARK: - Whisper Error

enum WhisperError: Error, LocalizedError {
    case modelLoadFailed
    case transcriptionFailed
    case modelCorrupted

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load Whisper model"
        case .transcriptionFailed:
            return "Transcription failed"
        case .modelCorrupted:
            return "Model file corrupted — please re-download"
        }
    }
}

// MARK: - Timed segment

/// One whisper segment with its own timing, relative to the start of the decoded buffer.
/// Produced only by `WhisperBridge.transcribeTimestamped` — every other path discards timings.
struct WhisperTimedSegment {
    let text: String
    let start: Double   // seconds
    let end: Double     // seconds
}

// MARK: - Streaming word output

/// One word from the eager streaming decode path.
/// Field-for-field matches `WhisperKitStreamingWord` so `EagerStreamEngine` takes both.
struct WhisperStreamWord: Sendable {
    let text: String        // includes leading space when present in BPE output
    let tokens: [Int]
    let start: Double       // seconds, relative to decoded buffer start
    let end: Double         // seconds, relative to decoded buffer start
    let probability: Float
}

/// Result of one eager streaming decode pass over `WhisperBridge`.
struct WhisperStreamResult: Sendable {
    let words: [WhisperStreamWord]
    let averageLogProbability: Float
    let languageCode: String?
}

class WhisperBridge: TranscriptionBackend {
    private var ctx: OpaquePointer?
    private let modelPath: URL
    private let queue = DispatchQueue(label: "whisper.transcribe", qos: .userInteractive)
    private let ctxLock: SafeLock

    // Shutdown tracking to prevent operations during cleanup
    private var isShuttingDown = false
    private var isInitialized = false

    // Callbacks for chunked pipeline
    var onNewSegment: ((String) -> Void)?   // Live text from new_segment_callback
    private(set) var shouldAbort = false     // Checked by abort_callback
    private var lastSegmentTime: Date?       // For stuck detection

    func requestAbort() { shouldAbort = true }
    func resetAbort() { shouldAbort = false; lastSegmentTime = nil }

    // Transcription timeout (default 30 seconds, longer on Intel)
    var transcriptionTimeout: TimeInterval = 30.0

    // Consecutive transcription failure tracking — auto-recover after 2 failures
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 2

    // Language detected during the last transcription (from whisper_full_lang_id)
    private(set) var lastDetectedLanguage: String?

    // HealthReportable
    private(set) var whisperProgressCounter: UInt64 = 0
    private var whisperOperationID: UInt64 = 0
    private var whisperOperationStart: ContinuousClock.Instant = .now
    private var whisperOperationDeadline: ContinuousClock.Instant = .now
    private var whisperCurrentOp: String? = nil
    private var whisperSegmentCount: Int = 0
    private var expectedSegmentCount: Int = 1

    // Threshold for filtering segments based on no_speech probability.
    // Segments with no_speech_prob above this are considered non-speech hallucinations.
    // Set high (0.9) because without the logprob conjunction that whisper.cpp uses
    // internally, lower values aggressively filter legitimate speech.
    private let noSpeechProbThreshold: Float = 0.9

    // Lock timeout - longer on Intel Macs due to slower processing
    private let lockTimeout: TimeInterval

    // Machine architecture string (e.g. "arm64" or "x86_64")
    private static let machineArch: String = {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }()

    // Whether running on Apple Silicon
    private static let isAppleSilicon: Bool = machineArch.hasPrefix("arm64")

    // Optimal thread count: use performance cores only on Apple Silicon
    private static let optimalThreadCount: Int32 = {
        if isAppleSilicon {
            // Query actual performance core count via sysctl (hw.perflevel0 = P-cores)
            var count: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
                // Reserve 2 P-cores for audio capture, VAD, and UI
                return max(2, count - 2)
            }
            // Fallback: ~50% of total cores (excludes E-cores heuristically)
            return Int32(max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        } else {
            // Intel: no P/E split, cap at 8
            return Int32(min(ProcessInfo.processInfo.activeProcessorCount, 8))
        }
    }()

    // Whether this instance uses GPU acceleration (default true, false for CPU-only streaming)
    private let useGPU: Bool

    init(modelPath: URL, useGPU: Bool = true) throws {
        self.modelPath = modelPath
        self.useGPU = useGPU

        // Use longer timeouts on Intel Macs
        if WhisperBridge.isAppleSilicon {
            self.lockTimeout = 10.0  // 10 seconds for Apple Silicon
            self.ctxLock = SafeLock(defaultTimeout: 10.0)
        } else {
            self.lockTimeout = 60.0  // 60 seconds for Intel (much slower)
            self.ctxLock = SafeLock(defaultTimeout: 60.0)
            self.transcriptionTimeout = 120.0  // 2 minutes for Intel
        }

        Logger.info("Initializing WhisperBridge with model: \(modelPath.lastPathComponent) (GPU: \(useGPU))", subsystem: .transcription)
        try WhisperBridge.verifyModelIntegrity(at: modelPath)
        try loadModel()
        isInitialized = true

        // HealthManager registration is done by AppState after construction

        Logger.info("WhisperBridge initialized", subsystem: .transcription)
    }

    /// Compute SHA-256 of a file by streaming 4 MB chunks.
    /// Stores the hash on first encounter; on subsequent loads verifies against stored value.
    /// Throws `WhisperError.modelCorrupted` when the hash no longer matches.
    private static func verifyModelIntegrity(at url: URL) throws {
        let filename = url.lastPathComponent
        let userDefaultsKey = "modelSHA256_\(filename)"

        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024  // 4 MB

        guard let stream = InputStream(url: url) else {
            Logger.warning("Integrity check: cannot open stream for \(filename) — skipping", subsystem: .model)
            return
        }
        stream.open()
        defer { stream.close() }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: chunkSize)
            guard n > 0 else { break }
            hasher.update(data: Data(buffer[0..<n]))
        }
        let digest = hasher.finalize()
        let currentHash = digest.map { String(format: "%02x", $0) }.joined()

        let storedHash = UserDefaults.standard.string(forKey: userDefaultsKey)
        if let stored = storedHash {
            if stored != currentHash {
                Logger.error("Model integrity FAIL: \(filename) hash mismatch (expected \(stored.prefix(8))…, got \(currentHash.prefix(8))…)", subsystem: .model)
                throw WhisperError.modelCorrupted
            }
            Logger.debug("Model integrity OK: \(filename)", subsystem: .model)
        } else {
            UserDefaults.standard.set(currentHash, forKey: userDefaultsKey)
            Logger.info("Model hash stored for \(filename): \(currentHash.prefix(16))…", subsystem: .model)
        }
    }

    private func loadModel() throws {
        var cparams = whisper_context_default_params()

        cparams.use_gpu = useGPU

        if useGPU && WhisperBridge.isAppleSilicon {
            cparams.flash_attn = true
        } else {
            cparams.flash_attn = false
        }

        ctx = whisper_init_from_file_with_params(
            modelPath.path,
            cparams
        )

        // If GPU initialization failed, retry with CPU only
        if ctx == nil && useGPU {
            Logger.warning("GPU initialization failed, retrying with CPU only", subsystem: .transcription)
            cparams.use_gpu = false
            cparams.flash_attn = false
            ctx = whisper_init_from_file_with_params(
                modelPath.path,
                cparams
            )
        }

        guard ctx != nil else {
            throw WhisperError.modelLoadFailed
        }

        // Log acceleration summary
        let gpu = cparams.use_gpu
        let flashAttn = cparams.flash_attn
        let arch = WhisperBridge.isAppleSilicon ? "Apple Silicon" : "Intel"

        Logger.info("=== Whisper Acceleration Report ===", subsystem: .transcription)
        Logger.info("  Architecture: \(arch) (\(WhisperBridge.machineArch))", subsystem: .transcription)
        Logger.info("  Model: \(modelPath.lastPathComponent)", subsystem: .transcription)
        Logger.info("  GPU (Metal): \(gpu ? "YES" : "NO")", subsystem: .transcription)
        Logger.info("  Flash Attention: \(flashAttn ? "YES" : "NO")", subsystem: .transcription)
        Logger.info("===================================", subsystem: .transcription)
    }

    /// Transcribe audio samples (16kHz mono float32)
    /// - Parameters:
    ///   - samples: Audio samples in float32 format at 16kHz
    ///   - initialPrompt: Optional context from previous transcription to improve continuity
    ///   - language: Language for transcription (default: .auto for auto-detection)
    ///   - singleSegment: Force single-segment output (faster for short chunks)
    /// - Returns: Transcribed text
    func transcribe(samples: [Float], initialPrompt: String? = nil, language: TranscriptionLanguage = .auto, singleSegment: Bool = false, maxTokens: Int32 = 0) -> String {
        // Don't start new transcriptions if shutting down
        guard !isShuttingDown else {
            Logger.warning("Transcription skipped - WhisperBridge is shutting down", subsystem: .transcription)
            return ""
        }

        guard isInitialized else {
            Logger.warning("Transcription skipped - WhisperBridge not initialized", subsystem: .transcription)
            return ""
        }

        // Use SafeLock with timeout to prevent deadlocks
        // Timeout is longer on Intel Macs due to slower processing
        let result: String
        do {
            result = try ctxLock.withLock(timeout: lockTimeout) { [weak self] in
                guard let self = self else { return "" }
                return self.performTranscription(samples: samples, initialPrompt: initialPrompt, language: language, singleSegment: singleSegment, maxTokens: maxTokens)
            }
        } catch SafeLockError.timeout {
            Logger.error("Failed to acquire context lock within \(lockTimeout) seconds - possible deadlock", subsystem: .transcription)
            return ""
        } catch {
            Logger.error("Lock acquisition error: \(error.localizedDescription)", subsystem: .transcription)
            return ""
        }

        return result
    }

    /// Perform the actual transcription (must be called with lock held)
    private func performTranscription(samples: [Float], initialPrompt: String? = nil, language: TranscriptionLanguage = .auto, singleSegment: Bool = false, maxTokens: Int32 = 0) -> String {
        guard let ctx = ctx else {
            Logger.warning("Whisper context is nil, cannot transcribe", subsystem: .transcription)
            return ""
        }
        guard !samples.isEmpty else { return "" }

        // Track operation for HealthManager
        let opID = whisperOperationID &+ 1
        let duration = Double(samples.count) / 16000.0
        let estimatedMs = duration * 1000.0 * (WhisperBridge.isAppleSilicon ? 0.15 : 0.5)
        whisperOperationID = opID
        whisperOperationStart = .now
        whisperOperationDeadline = .now + .milliseconds(Int(estimatedMs * 2))
        whisperCurrentOp = "transcribing"
        whisperSegmentCount = 0
        expectedSegmentCount = max(1, Int(duration / 2.0))
        EventRingBuffer.shared.record(
            component: "WhisperBridge",
            operation: "transcribeStarted",
            kind: .progress,
            metadata: ["op": .int(Int(opID)), "durationSec": .double(duration)]
        )

        let wparams = makeFullParams(singleSegment: singleSegment, maxTokens: maxTokens, noTimestamps: true)
        let result = runWhisperFull(ctx: ctx, samples: samples, params: wparams,
                                    initialPrompt: initialPrompt, language: language)

        guard handleTranscriptionResult(result) else { return "" }

        // Extract detected language (useful when auto-detect is enabled)
        let langId = whisper_full_lang_id(ctx)
        if langId >= 0, let langStr = whisper_lang_str(langId) {
            lastDetectedLanguage = String(cString: langStr)
        }

        var text = ""
        let nSegments = whisper_full_n_segments(ctx)
        for i in 0..<nSegments {
            let noSpeechProb = whisper_full_get_segment_no_speech_prob(ctx, i)
            if noSpeechProb > noSpeechProbThreshold {
                if let segmentText = whisper_full_get_segment_text(ctx, i) {
                    EventRingBuffer.shared.record(
                        component: "WhisperBridge",
                        operation: "skipNonSpeech",
                        kind: .state,
                        metadata: ["prob": .double(Double(noSpeechProb))]
                    )
                }
                continue
            }
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segmentText)
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared decode plumbing
    //
    // performTranscription and performTimestampedTranscription differ only in whether
    // whisper keeps its segment timings. Everything else — the ~40-line params block,
    // the C-string lifetime dance around language/prompt, and the Metal-corruption
    // recovery path — is identical and lives here so the two cannot drift apart.

    /// Build the decode params. `noTimestamps: false` also implies multi-segment output,
    /// since a single forced segment carries a single useless span.
    /// `tokenTimestamps: true` enables per-token t0/t1 and probability from `whisper_full_get_token_data`.
    /// `audioCtx > 0` overrides the default 1500-frame (30s) context, scaling encoder cost to the window.
    private func makeFullParams(singleSegment: Bool, maxTokens: Int32, noTimestamps: Bool,
                                tokenTimestamps: Bool = false, audioCtx: Int32 = 0) -> whisper_full_params {
        var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        wparams.print_progress = false
        wparams.print_special = false
        wparams.print_realtime = false
        wparams.print_timestamps = false
        wparams.single_segment = singleSegment
        wparams.no_timestamps = noTimestamps
        wparams.n_threads = WhisperBridge.optimalThreadCount
        wparams.suppress_nst = true
        wparams.suppress_blank = true

        // Speed: deterministic greedy decoding, no temperature fallback ladder
        wparams.temperature = 0.0
        wparams.temperature_inc = 0.0

        // With temperature=0, all decoders produce identical output — only need 1 (default is 5)
        wparams.greedy.best_of = 1

        // Limit decoder prompt context to 128 tokens (~100 words) — sufficient for dictation
        wparams.n_max_text_ctx = 128

        // Explicit thresholds (match defaults, protect against future changes)
        wparams.no_speech_thold = 0.6
        wparams.logprob_thold = -1.0
        wparams.entropy_thold = 2.4

        // Limit decoder output length (0 = no limit, >0 = max tokens per segment)
        // Prevents hallucination spirals where whisper generates 100+ repeated tokens
        wparams.max_tokens = maxTokens

        // Set up callbacks for chunked pipeline
        let userData = Unmanaged.passUnretained(self).toOpaque()

        if onNewSegment != nil {
            wparams.new_segment_callback = { ctx, state, nNew, userData in
                guard let userData = userData, let ctx = ctx else { return }
                let bridge = Unmanaged<WhisperBridge>.fromOpaque(userData).takeUnretainedValue()
                bridge.lastSegmentTime = Date()
                bridge.whisperProgressCounter &+= 1
                bridge.whisperSegmentCount += 1
                // Extend deadline as progress arrives
                bridge.whisperOperationDeadline = .now + .seconds(4)

                // Read the latest segments
                let totalSegments = whisper_full_n_segments(ctx)
                var newText = ""
                for i in max(0, totalSegments - nNew)..<totalSegments {
                    if let segText = whisper_full_get_segment_text(ctx, i) {
                        newText += String(cString: segText)
                    }
                }
                let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    bridge.onNewSegment?(trimmed)
                }
            }
            wparams.new_segment_callback_user_data = userData
        }

        if shouldAbort == false {
            // Only set abort callback if we might want to abort
            wparams.abort_callback = { userData -> Bool in
                guard let userData = userData else { return false }
                let bridge = Unmanaged<WhisperBridge>.fromOpaque(userData).takeUnretainedValue()
                return bridge.shouldAbort
            }
            wparams.abort_callback_user_data = userData
        }

        // Always start fresh — streaming mode re-transcribes ALL audio each call,
        // so carrying decoder state between calls degrades quality.
        // initial_prompt (prompt words) still works with no_context=true because
        // whisper.cpp adds initial_prompt tokens AFTER clearing prompt_past.
        wparams.no_context = true

        wparams.token_timestamps = tokenTimestamps
        // audio_ctx > 0: scale the mel tensor to 2×audio_ctx instead of the default
        // 2×1500 (30s). Proportional to the window, so encoder cost shrinks with it.
        // Mutually exclusive with the Core ML/ANE encoder (which uses a fixed-shape
        // MLMultiArray); Phase 0b measures which configuration wins on this machine.
        wparams.audio_ctx = audioCtx

        return wparams
    }

    /// Run `whisper_full`, keeping the language and prompt C strings alive for its duration.
    private func runWhisperFull(ctx: OpaquePointer, samples: [Float], params: whisper_full_params,
                                initialPrompt: String?, language: TranscriptionLanguage) -> Int32 {
        var wparams = params

        if let prompt = initialPrompt, !prompt.isEmpty {
            Logger.debug("Initial prompt: '\(prompt.prefix(100))'", subsystem: .transcription)
        }

        func runTranscription() -> Int32 {
            samples.withUnsafeBufferPointer { ptr -> Int32 in
                whisper_full(ctx, wparams, ptr.baseAddress, Int32(samples.count))
            }
        }

        func runWithPrompt(_ prompt: String) -> Int32 {
            prompt.withCString { promptPtr in
                wparams.initial_prompt = promptPtr
                return runTranscription()
            }
        }

        if language == .auto {
            wparams.language = nil
            Logger.debug("Language: auto-detect", subsystem: .transcription)

            if let prompt = initialPrompt, !prompt.isEmpty {
                return runWithPrompt(prompt)
            }
            return runTranscription()
        }

        // Set specific language - C string must stay alive
        return language.rawValue.withCString { langPtr in
            wparams.language = langPtr
            wparams.detect_language = false
            Logger.debug("Language: \(language.displayName)", subsystem: .transcription)

            if let prompt = initialPrompt, !prompt.isEmpty {
                return runWithPrompt(prompt)
            }
            return runTranscription()
        }
    }

    /// Returns true when the decode succeeded. On failure, schedules context recovery
    /// once the Metal context has failed enough times to be presumed corrupt.
    private func handleTranscriptionResult(_ result: Int32) -> Bool {
        guard result != 0 else {
            consecutiveFailures = 0
            whisperCurrentOp = nil
            return true
        }

        consecutiveFailures += 1
        Logger.error("Whisper transcription failed with code: \(result) (failure \(consecutiveFailures)/\(maxConsecutiveFailures))", subsystem: .transcription)

        // After repeated failures (e.g., Metal encode errors), the GPU context
        // may be corrupted. Schedule async recovery to reload the model.
        if consecutiveFailures >= maxConsecutiveFailures {
            Logger.warning("Consecutive failures reached \(maxConsecutiveFailures), scheduling context recovery", subsystem: .transcription)
            let bridge = self
            queue.async {
                do {
                    try bridge.recoverContext()
                    bridge.consecutiveFailures = 0
                } catch {
                    Logger.error("Auto-recovery failed: \(error.localizedDescription)", subsystem: .transcription)
                }
            }
        }
        return false
    }

    // MARK: - Timestamped transcription

    /// Transcribe and keep whisper's own segment boundaries.
    ///
    /// Every other path in this class throws the timings away (`no_timestamps = true`) because
    /// dictation only ever needs the concatenated string. The meeting re-transcription pass does
    /// need them: it decodes a ~30s window covering several transcript cards and has to know
    /// which card each piece of the new text belongs to.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono float32 audio
    ///   - initialPrompt: context from the previous window, for boundary continuity
    ///   - language: fixed language, or `.auto` to detect (read back via `lastDetectedLanguage`)
    /// - Returns: Segments in decode order with start/end in seconds relative to `samples[0]`.
    ///            Empty on failure — callers keep their existing text.
    func transcribeTimestamped(samples: [Float], initialPrompt: String? = nil,
                               language: TranscriptionLanguage = .auto) -> [WhisperTimedSegment] {
        guard !isShuttingDown else {
            Logger.warning("Timestamped transcription skipped - WhisperBridge is shutting down", subsystem: .transcription)
            return []
        }
        guard isInitialized else {
            Logger.warning("Timestamped transcription skipped - WhisperBridge not initialized", subsystem: .transcription)
            return []
        }

        do {
            return try ctxLock.withLock(timeout: lockTimeout) { [weak self] in
                guard let self = self else { return [] }
                return self.performTimestampedTranscription(samples: samples, initialPrompt: initialPrompt, language: language)
            }
        } catch SafeLockError.timeout {
            Logger.error("Failed to acquire context lock within \(lockTimeout) seconds - possible deadlock", subsystem: .transcription)
            return []
        } catch {
            Logger.error("Lock acquisition error: \(error.localizedDescription)", subsystem: .transcription)
            return []
        }
    }

    /// Perform the timestamped transcription (must be called with lock held)
    private func performTimestampedTranscription(samples: [Float], initialPrompt: String?,
                                                 language: TranscriptionLanguage) -> [WhisperTimedSegment] {
        guard let ctx = ctx else {
            Logger.warning("Whisper context is nil, cannot transcribe", subsystem: .transcription)
            return []
        }
        guard !samples.isEmpty else { return [] }

        // Track operation for HealthManager
        let opID = whisperOperationID &+ 1
        let duration = Double(samples.count) / 16000.0
        let estimatedMs = duration * 1000.0 * (WhisperBridge.isAppleSilicon ? 0.15 : 0.5)
        whisperOperationID = opID
        whisperOperationStart = .now
        whisperOperationDeadline = .now + .milliseconds(Int(estimatedMs * 2))
        whisperCurrentOp = "transcribing"
        whisperSegmentCount = 0
        expectedSegmentCount = max(1, Int(duration / 2.0))

        let wparams = makeFullParams(singleSegment: false, maxTokens: 0, noTimestamps: false)
        let result = runWhisperFull(ctx: ctx, samples: samples, params: wparams,
                                    initialPrompt: initialPrompt, language: language)

        guard handleTranscriptionResult(result) else { return [] }

        let langId = whisper_full_lang_id(ctx)
        if langId >= 0, let langStr = whisper_lang_str(langId) {
            lastDetectedLanguage = String(cString: langStr)
        }

        var segments: [WhisperTimedSegment] = []
        let nSegments = whisper_full_n_segments(ctx)
        segments.reserveCapacity(Int(nSegments))
        for i in 0..<nSegments {
            if whisper_full_get_segment_no_speech_prob(ctx, i) > noSpeechProbThreshold { continue }
            guard let raw = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // whisper timestamps are centiseconds
            segments.append(WhisperTimedSegment(
                text: text,
                start: Double(whisper_full_get_segment_t0(ctx, i)) / 100.0,
                end: Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
            ))
        }
        return segments
    }

    /// Transcribe asynchronously with optional context prompt
    /// - Parameters:
    ///   - samples: Audio samples in float32 format at 16kHz
    ///   - initialPrompt: Optional context from previous transcription
    ///   - language: Language for transcription (default: .auto for auto-detection)
    ///   - singleSegment: Force single-segment output (faster for short chunks)
    ///   - completion: Called on background queue with transcription result
    func transcribeAsync(samples: [Float], initialPrompt: String? = nil, language: TranscriptionLanguage = .auto, singleSegment: Bool = false, maxTokens: Int32 = 0, completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let text = self.transcribe(samples: samples, initialPrompt: initialPrompt, language: language, singleSegment: singleSegment, maxTokens: maxTokens)
            // Call completion directly on background queue to avoid blocking main thread
            completion(text)
        }
    }

    // MARK: - Eager streaming decode

    /// Decode `samples` and return per-word text + timing + probability for the eager
    /// streaming engine. Runs on the serial `queue` under `ctxLock`, so it serializes
    /// with the regular `transcribeAsync` path — call only from the preview polling loop,
    /// never from the VAD-chunk path simultaneously.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono Float32, typically 1–12s uncommitted tail
    ///   - language: fixed language or `.auto`
    ///   - initialPrompt: last ~50 chars of committed text, for boundary continuity
    ///   - audioCtx: mel-context override (0 = default 30s). Use Phase 0b result.
    ///   - maxTokens: per-segment cap (96 is sufficient for rolling windows)
    ///   - completion: called on background queue with result, or nil on failure/shutdown
    func transcribeStreamingAsync(
        samples: [Float],
        language: TranscriptionLanguage,
        initialPrompt: String?,
        audioCtx: Int32 = 0,
        maxTokens: Int32 = 96,
        completion: @escaping (WhisperStreamResult?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            guard !self.isShuttingDown, self.isInitialized else { completion(nil); return }
            do {
                let result = try self.ctxLock.withLock(timeout: self.lockTimeout) { [self] in
                    self.performStreamingDecode(
                        samples: samples, language: language,
                        initialPrompt: initialPrompt, audioCtx: audioCtx, maxTokens: maxTokens
                    )
                }
                completion(result)
            } catch SafeLockError.timeout {
                Logger.error("Streaming decode lock timeout", subsystem: .transcription)
                completion(nil)
            } catch {
                Logger.error("Streaming decode lock error: \(error)", subsystem: .transcription)
                completion(nil)
            }
        }
    }

    /// Decode and return word-level results. Must be called with `ctxLock` held.
    private func performStreamingDecode(
        samples: [Float],
        language: TranscriptionLanguage,
        initialPrompt: String?,
        audioCtx: Int32,
        maxTokens: Int32
    ) -> WhisperStreamResult? {
        guard let ctx else { return nil }
        guard !samples.isEmpty else { return nil }

        let wparams = makeFullParams(
            singleSegment: false, maxTokens: maxTokens, noTimestamps: false,
            tokenTimestamps: true, audioCtx: audioCtx
        )
        let r = runWhisperFull(ctx: ctx, samples: samples, params: wparams,
                               initialPrompt: initialPrompt, language: language)
        guard handleTranscriptionResult(r) else { return nil }

        var langCode: String?
        let langId = whisper_full_lang_id(ctx)
        if langId >= 0, let ptr = whisper_lang_str(langId) {
            langCode = String(cString: ptr)
            lastDetectedLanguage = langCode ?? lastDetectedLanguage
        }

        let nSegments = whisper_full_n_segments(ctx)
        var words: [WhisperStreamWord] = []
        var logProbSum: Float = 0.0
        var logProbCount = 0

        Logger.debug("Streaming decode: \(nSegments) segments", subsystem: .transcription)
        for i in 0..<nSegments {
            let nsp = whisper_full_get_segment_no_speech_prob(ctx, i)
            if nsp > noSpeechProbThreshold {
                Logger.debug("Streaming decode: segment \(i) skipped (no_speech_prob=\(String(format: "%.2f", nsp)))", subsystem: .transcription)
                continue
            }
            let nTokens = whisper_full_n_tokens(ctx, i)
            guard nTokens > 0 else { continue }

            // Merge BPE tokens into words. A new word begins when a token's text has a
            // leading space (the BPE word-boundary marker in all whisper vocab variants).
            var wordText = ""
            var wordT0: Int64 = -1
            var wordT1: Int64 = 0
            var wordIds: [Int] = []
            var wordProbSum: Float = 0.0
            var wordProbCount = 0

            for j in 0..<nTokens {
                guard let rawPtr = whisper_full_get_token_text(ctx, i, j) else { continue }
                let tokenText = String(cString: rawPtr)
                // Skip special tokens: <|...|> timestamps/control tokens and [_BEG_]/[_TT_N] non-speech tokens
                guard !tokenText.hasPrefix("<|"), !tokenText.hasPrefix("[_"), !tokenText.isEmpty else { continue }

                let data = whisper_full_get_token_data(ctx, i, j)

                // Word boundary: token starts with a space (BPE leading-space convention)
                if tokenText.first == " ", !wordText.isEmpty {
                    // flush the accumulated word
                    let trimmed = wordText.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, wordT0 >= 0 {
                        let prob = wordProbCount > 0 ? wordProbSum / Float(wordProbCount) : 0.0
                        words.append(WhisperStreamWord(
                            text: wordText,
                            tokens: wordIds,
                            start: Double(wordT0) / 100.0,
                            end: Double(wordT1) / 100.0,
                            probability: prob
                        ))
                        if prob > 0 {
                            logProbSum += log(max(prob, 1e-7))
                            logProbCount += 1
                        }
                    }
                    wordText = ""
                    wordIds = []
                    wordProbSum = 0.0
                    wordProbCount = 0
                    wordT0 = -1
                }

                if wordT0 < 0 { wordT0 = data.t0 }
                wordT1 = data.t1
                wordText += tokenText
                wordIds.append(Int(data.id))
                if data.p > 0 {
                    wordProbSum += data.p
                    wordProbCount += 1
                }
            }

            // flush last word in segment
            let trimmed = wordText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, wordT0 >= 0 {
                let prob = wordProbCount > 0 ? wordProbSum / Float(wordProbCount) : 0.0
                words.append(WhisperStreamWord(
                    text: wordText,
                    tokens: wordIds,
                    start: Double(wordT0) / 100.0,
                    end: Double(wordT1) / 100.0,
                    probability: prob
                ))
                if prob > 0 {
                    logProbSum += log(max(prob, 1e-7))
                    logProbCount += 1
                }
            }
        }

        let avgLogProb = logProbCount > 0 ? logProbSum / Float(logProbCount) : -1.0
        return WhisperStreamResult(words: words, averageLogProbability: avgLogProb, languageCode: langCode)
    }

    /// Detect language from audio samples. Returns probabilities for all languages, or nil on failure. Returns probabilities for all languages, or nil on failure.
    /// Serialized with transcription via ctxLock — safe to call from any thread.
    func detectLanguage(samples: [Float]) -> [String: Float]? {
        guard !isShuttingDown, isInitialized else { return nil }
        guard !samples.isEmpty else { return nil }

        do {
            return try ctxLock.withLock(timeout: lockTimeout) { [self] in
                guard let ctx = ctx else { return nil }

                let melResult = samples.withUnsafeBufferPointer { ptr -> Int32 in
                    whisper_pcm_to_mel(ctx, ptr.baseAddress, Int32(ptr.count), 2)
                }
                guard melResult == 0 else {
                    Logger.error("whisper_pcm_to_mel failed with code \(melResult)", subsystem: .transcription)
                    return nil
                }

                let maxId = Int(whisper_lang_max_id())
                var probs = [Float](repeating: 0, count: maxId + 1)

                let topId = probs.withUnsafeMutableBufferPointer { p -> Int32 in
                    whisper_lang_auto_detect(ctx, 0, 2, p.baseAddress)
                }
                guard topId >= 0 else {
                    Logger.error("whisper_lang_auto_detect failed with code \(topId)", subsystem: .transcription)
                    return nil
                }

                var result: [String: Float] = [:]
                for i in 0...maxId {
                    if let langStr = whisper_lang_str(Int32(i)) {
                        let prob = probs[i]
                        if prob > 0.001 {
                            result[String(cString: langStr)] = prob
                        }
                    }
                }

                if let topLang = whisper_lang_str(topId) {
                    Logger.debug("Detection: top=\(String(cString: topLang)) (p=\(String(format: "%.3f", probs[Int(topId)])))", subsystem: .transcription)
                }

                return result.isEmpty ? nil : result
            }
        } catch SafeLockError.timeout {
            Logger.error("detectLanguage lock timeout", subsystem: .transcription)
            return nil
        } catch {
            Logger.error("detectLanguage lock error: \(error.localizedDescription)", subsystem: .transcription)
            return nil
        }
    }

    /// Check if whisper context is healthy
    /// - Returns: true if context appears valid, false otherwise
    func isContextHealthy() -> Bool {
        do {
            return try ctxLock.withLock(timeout: 1.0) { [weak self] in
                guard let self = self else { return false }
                guard let ctx = self.ctx else { return false }
                guard self.isInitialized && !self.isShuttingDown else { return false }

                // Verify context is valid by checking if we can get basic info
                // whisper_full_n_segments returns 0 for fresh context, which is valid
                _ = whisper_full_n_segments(ctx)
                return true
            }
        } catch {
            Logger.error("Health check failed: \(error.localizedDescription)", subsystem: .transcription)
            return false
        }
    }

    /// Attempt to recover the whisper context by reloading the model
    func recoverContext() throws {
        Logger.warning("Attempting to recover whisper context...", subsystem: .transcription)

        do {
            try ctxLock.withLock(timeout: 5.0) { [weak self] in
                guard let self = self else { return }

                // Free old context if it exists
                if let oldCtx = self.ctx {
                    whisper_free(oldCtx)
                    Logger.debug("Freed corrupted context", subsystem: .transcription)
                }

                // Reload model
                var cparams = whisper_context_default_params()
                cparams.use_gpu = true
                cparams.flash_attn = true

                self.ctx = whisper_init_from_file_with_params(
                    self.modelPath.path,
                    cparams
                )

                guard self.ctx != nil else {
                    throw WhisperError.modelLoadFailed
                }

                Logger.debug("Whisper context recovered successfully", subsystem: .transcription)
            }
        } catch {
            Logger.error("Context recovery failed: \(error.localizedDescription)", subsystem: .transcription)
            throw error
        }
    }

    /// Prepare for shutdown - prevents new transcriptions and waits for in-flight operations
    func prepareForShutdown() {
        Logger.debug("WhisperBridge preparing for shutdown...", subsystem: .transcription)
        isShuttingDown = true

        // Wait briefly for any in-flight queue operations
        queue.sync {
            Logger.debug("WhisperBridge queue drained", subsystem: .transcription)
        }
    }

    deinit {
        Logger.debug("WhisperBridge deinit - freeing context...", subsystem: .transcription)

        isShuttingDown = true

        // Use SafeLock with timeout for cleanup
        do {
            try ctxLock.withLock(timeout: 2.0) { [self] in
                if let ctx = ctx {
                    whisper_free(ctx)
                    Logger.debug("Whisper context freed successfully", subsystem: .transcription)
                }
            }
        } catch {
            Logger.error("Failed to acquire lock during deinit: \(error.localizedDescription)", subsystem: .transcription)
            // Force cleanup anyway - we're dying
            if let ctx = ctx {
                whisper_free(ctx)
                Logger.warning("Forced whisper context cleanup without lock", subsystem: .transcription)
            }
        }
    }
}

// MARK: - HealthReportable

extension WhisperBridge: HealthReportable {

    var componentName: String { "WhisperBridge" }

    var healthState: ComponentHealth {
        let seq = whisperProgressCounter
        let now = ContinuousClock.now

        guard let opName = whisperCurrentOp else {
            // Idle
            var h = ComponentHealth()
            h.progress = ProgressInfo(sequence: seq, completedWork: 1.0, lastUpdate: now)
            return h
        }

        let elapsed = now - whisperOperationStart
        let deadline = whisperOperationDeadline
        let pct = expectedSegmentCount > 0
            ? min(1.0, Double(whisperSegmentCount) / Double(expectedSegmentCount))
            : 0.0

        let status: ComponentStatus
        if now < deadline {
            status = .healthy
        } else if whisperSegmentCount > 0 && now < deadline + .seconds(4) {
            status = .busy  // making progress but past initial estimate
        } else if consecutiveFailures > 0 {
            status = .stalled
        } else if elapsed > .seconds(8) && whisperSegmentCount == 0 {
            status = .stalled
        } else {
            status = .busy
        }

        let op = OperationInfo(
            id: whisperOperationID,
            name: opName,
            started: whisperOperationStart,
            deadline: deadline,
            queueBacklog: 0
        )

        var h = ComponentHealth()
        h.status = status
        h.operation = op
        h.progress = ProgressInfo(sequence: seq, completedWork: pct, lastUpdate: now)
        h.dependencies = []
        h.metadata = [
            "segments": .int(whisperSegmentCount),
            "failures": .int(consecutiveFailures)
        ]
        return h
    }
}

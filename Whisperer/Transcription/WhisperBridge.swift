//
//  WhisperBridge.swift
//  Whisperer
//
//  Swift wrapper for whisper.cpp C library
//

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

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load Whisper model"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
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
        try loadModel()
        isInitialized = true

        // Register queue for health monitoring
        QueueHealthMonitor.shared.monitor(queue: queue, name: "whisper.transcribe")

        Logger.info("WhisperBridge initialized", subsystem: .transcription)
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

        var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        wparams.print_progress = false
        wparams.print_special = false
        wparams.print_realtime = false
        wparams.print_timestamps = false
        wparams.single_segment = singleSegment
        wparams.no_timestamps = true
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
        if let prompt = initialPrompt, !prompt.isEmpty {
            Logger.debug("Initial prompt: '\(prompt.prefix(100))'", subsystem: .transcription)
        }

        // Helper to run transcription with current wparams
        func runTranscription() -> Int32 {
            samples.withUnsafeBufferPointer { ptr -> Int32 in
                whisper_full(ctx, wparams, ptr.baseAddress, Int32(samples.count))
            }
        }

        // Helper to set prompt and run
        func runWithPrompt(_ prompt: String) -> Int32 {
            prompt.withCString { promptPtr in
                wparams.initial_prompt = promptPtr
                return runTranscription()
            }
        }

        // Perform transcription with language and prompt handling
        // Language C string must remain valid during whisper_full call
        let result: Int32
        if language == .auto {
            wparams.language = nil
            Logger.debug("Language: auto-detect", subsystem: .transcription)

            if let prompt = initialPrompt, !prompt.isEmpty {
                result = runWithPrompt(prompt)
            } else {
                result = runTranscription()
            }
        } else {
            // Set specific language - C string must stay alive
            result = language.rawValue.withCString { langPtr in
                wparams.language = langPtr
                wparams.detect_language = false
                Logger.debug("Language: \(language.displayName)", subsystem: .transcription)

                if let prompt = initialPrompt, !prompt.isEmpty {
                    return runWithPrompt(prompt)
                } else {
                    return runTranscription()
                }
            }
        }

        if result != 0 {
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
            return ""
        }

        // Reset failure counter on success
        consecutiveFailures = 0

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
                    Logger.debug("Skipping non-speech segment (prob=\(String(format: "%.3f", noSpeechProb))): '\(String(cString: segmentText))'", subsystem: .transcription)
                }
                continue
            }
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segmentText)
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Detect language from audio samples. Returns probabilities for all languages, or nil on failure.
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

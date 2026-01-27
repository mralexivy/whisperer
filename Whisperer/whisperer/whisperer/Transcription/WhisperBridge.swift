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

class WhisperBridge {
    private var ctx: OpaquePointer?
    private let modelPath: URL
    private let queue = DispatchQueue(label: "whisper.transcribe", qos: .userInteractive)
    private let ctxLock = NSLock()

    init(modelPath: URL) throws {
        self.modelPath = modelPath
        try loadModel()
    }

    private func loadModel() throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true

        ctx = whisper_init_from_file_with_params(
            modelPath.path,
            cparams
        )

        guard ctx != nil else {
            throw WhisperError.modelLoadFailed
        }

        print("Whisper model loaded: \(modelPath.lastPathComponent)")
    }

    /// Transcribe audio samples (16kHz mono float32)
    /// - Parameters:
    ///   - samples: Audio samples in float32 format at 16kHz
    ///   - initialPrompt: Optional context from previous transcription to improve continuity
    ///   - language: Language for transcription (default: .auto for auto-detection)
    /// - Returns: Transcribed text
    func transcribe(samples: [Float], initialPrompt: String? = nil, language: TranscriptionLanguage = .auto) -> String {
        ctxLock.lock()
        defer { ctxLock.unlock() }

        guard let ctx = ctx else {
            print("⚠️ Whisper context is nil, cannot transcribe")
            return ""
        }
        guard !samples.isEmpty else { return "" }

        var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        wparams.print_progress = false
        wparams.print_special = false
        wparams.print_realtime = false
        wparams.print_timestamps = false
        wparams.single_segment = false  // Allow multiple segments for full transcription
        wparams.no_timestamps = true
        wparams.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

        // Context carrying: use previous transcription as prompt for better continuity
        if let prompt = initialPrompt, !prompt.isEmpty {
            wparams.no_context = false  // Enable context usage
        } else {
            wparams.no_context = true
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
            print("🌐 Language: auto-detect")

            if let prompt = initialPrompt, !prompt.isEmpty {
                result = runWithPrompt(prompt)
            } else {
                result = runTranscription()
            }
        } else {
            // Set specific language - C string must stay alive
            result = language.rawValue.withCString { langPtr in
                wparams.language = langPtr
                print("🌐 Language: \(language.displayName)")

                if let prompt = initialPrompt, !prompt.isEmpty {
                    return runWithPrompt(prompt)
                } else {
                    return runTranscription()
                }
            }
        }

        if result != 0 {
            print("Whisper transcription failed with code: \(result)")
            return ""
        }

        var text = ""
        let nSegments = whisper_full_n_segments(ctx)
        for i in 0..<nSegments {
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
    ///   - completion: Called on background queue with transcription result
    func transcribeAsync(samples: [Float], initialPrompt: String? = nil, language: TranscriptionLanguage = .auto, completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let text = self.transcribe(samples: samples, initialPrompt: initialPrompt, language: language)
            // Call completion directly on background queue to avoid blocking main thread
            completion(text)
        }
    }

    deinit {
        ctxLock.lock()
        defer { ctxLock.unlock() }

        if let ctx = ctx {
            whisper_free(ctx)
            print("Whisper context freed")
        }
    }
}

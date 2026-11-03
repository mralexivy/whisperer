//
//  TranscriptionBackend.swift
//  Whisperer
//
//  Protocol abstraction for transcription backends (whisper.cpp, Parakeet, Apple Speech)
//

import Foundation

// MARK: - Backend Type

/// Declaration order is picker order — `allCases` is the source for the engine segmented
/// control in `ModelsTabView`. Qwen3 leads the picker. Nemotron is the built-in engine and is
/// deliberately filtered out of every picker; see `BackendType.isBuiltin`.
enum BackendType: String, CaseIterable, Identifiable {
    case qwen3asr = "Qwen3ASR"
    case whisperCpp = "whisper.cpp"
    case parakeet = "Parakeet"
    case nemotron = "Nemotron"
    case nemotronHebrew = "NemotronHebrew"
    case speechAnalyzer = "Apple Speech"
    case whisperKit = "WhisperKit"

    var id: String { rawValue }

    /// The backend a user with no stored preference gets.
    ///
    /// Nemotron: it is the one engine that genuinely streams, so the live preview and the
    /// meeting transcript appear as the audio arrives rather than after a re-decode. Measured
    /// 2026-11-03 (`docs/knowledge/transcription/live-preview-whisper-base-vs-omni300m-2026-11-03.md`):
    /// text lags the speaker by 0.04 s, never revises what it has shown, and finalizes 0.03 s
    /// after the audio ends, against 0.5 s / 1 s for Qwen3's repeated decode. The model is a
    /// ~650 MB download, so first-run onboarding fetches it.
    ///
    /// Final-text accuracy is lower than Qwen3's on Russian and English (FLEURS WER 13.1 and 10.9
    /// against 6.4 and 4.1). That trade was made on purpose; Qwen3 stays selectable and
    /// existing users keep whatever they chose.
    static var defaultBackend: BackendType { defaultBackend(for: .auto) }

    /// The backend a user with no stored preference gets, given the language they transcribe in.
    ///
    /// `language` matters because Nemotron's coverage is not uniform. NVIDIA lists Hebrew as
    /// "adaptation-ready" (the tokenizer knows it, full ASR needs fine-tuning), and on 100 FLEURS
    /// Hebrew clips it scores WER 0.436 against the ivrit-v3-turbo fine-tune's 0.148. Handing a
    /// Hebrew user the streaming engine would make their dictation worse, so Hebrew falls back to
    /// whisper.cpp, which runs ivrit.
    static func defaultBackend(for language: TranscriptionLanguage) -> BackendType {
        guard BackendType.nemotron.isAvailable else { return .whisperCpp }
        return BackendType.nemotron.weakLanguages.contains(language) ? .whisperCpp : .nemotron
    }

    /// The built-in engine: always downloaded, always resident, never offered as a choice. It drives
    /// live text for every other engine and covers them when none is loaded or they are busy.
    var isBuiltin: Bool { self == .nemotron }

    /// The engines a user can pick. Excludes the built-in engine and the Hebrew sub-backend.
    static var selectable: [BackendType] { allCases.filter { $0 != .nemotron && $0 != .nemotronHebrew } }

    var displayName: String {
        switch self {
        case .whisperCpp: return "Whisper"
        case .parakeet: return "Parakeet"
        case .nemotron: return "Nemotron"
        case .nemotronHebrew: return "Nemotron Hebrew"
        case .qwen3asr: return "Qwen3 ASR"
        case .speechAnalyzer: return "Apple Speech"
        case .whisperKit: return "WhisperKit"
        }
    }

    var iconName: String {
        switch self {
        case .whisperCpp: return "waveform"
        case .parakeet: return "bird.fill"
        case .nemotron: return "waveform.badge.mic"
        case .nemotronHebrew: return "waveform.badge.mic"
        case .qwen3asr: return "waveform.badge.sparkles"
        case .speechAnalyzer: return "apple.logo"
        case .whisperKit: return "bolt.fill"
        }
    }

    /// Short user-facing label for settings pickers (vs. displayName which is used in logs/technical contexts)
    var friendlyName: String {
        switch self {
        case .whisperCpp: return "Accurate"
        case .parakeet: return "Fast"
        case .nemotron: return "Streaming"
        case .nemotronHebrew: return "Hebrew"
        case .qwen3asr: return "Leading"
        case .speechAnalyzer: return "System"
        case .whisperKit: return "Core ML"
        }
    }

    /// One-line benefit description shown under the picker option
    var settingsSubtitle: String {
        switch self {
        case .whisperCpp: return "97 languages"
        case .parakeet: return "ANE-accelerated"
        case .nemotron: return "True streaming, 37ms/chunk"
        case .nemotronHebrew: return "Hebrew fine-tune, 37ms/chunk"
        case .qwen3asr: return "Top of Open ASR Leaderboard · 31 languages"
        case .speechAnalyzer: return "macOS 26+"
        case .whisperKit: return "Core ML optimized · 100 languages"
        }
    }

    /// Languages this backend is **measured** to be materially worse at than an alternative the
    /// app already ships, despite nominally supporting them.
    ///
    /// Distinct from `supportsLanguage`, which answers "can it produce output at all". Qwen3
    /// produces Hebrew output; it is just bad Hebrew. On 56 Hebrew clips from the user's own
    /// history it scored WER 0.341 against `ivrit-v3-turbo`'s 0.183, and the transcripts show
    /// invented words and Cyrillic bleeding into Hebrew sentences — not a near miss.
    ///
    /// Only add a language here with a benchmark run behind it. The cost of a wrong entry is a
    /// user silently kept off the better engine. See `Qwen3GateBenchmarkTests` and
    /// `docs/knowledge/transcription/knowledge.md`.
    var weakLanguages: Set<TranscriptionLanguage> {
        switch self {
        case .qwen3asr, .nemotron: return [.hebrew]
        default: return []
        }
    }

    /// True when the backend reports the spoken language from its own decode, so the
    /// `LanguageRouter` + `ModelPool` detection pipeline must not run for it.
    ///
    /// Qwen3 emits a `language <Name>` header ahead of the transcript, which
    /// `Qwen3ASRBridge` parses into `lastDetectedLanguage` and ratchets on. Running whisper's
    /// detection alongside it would load a second model to answer a question already answered.
    var detectsLanguageNatively: Bool {
        switch self {
        case .parakeet, .nemotron, .nemotronHebrew, .qwen3asr: return true
        case .whisperCpp, .speechAnalyzer, .whisperKit: return false
        }
    }

    var isAvailable: Bool {
        switch self {
        case .whisperCpp: return true
        case .parakeet, .nemotron, .nemotronHebrew, .qwen3asr:
            // Requires Apple Silicon (CoreML/ANE)
            var sysinfo = utsname()
            uname(&sysinfo)
            let arch = withUnsafePointer(to: &sysinfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            return arch.hasPrefix("arm64")
        case .speechAnalyzer:
            if #available(macOS 26.0, *) { return true }
            return false
        case .whisperKit:
            #if canImport(WhisperKit)
            var sysinfo = utsname()
            uname(&sysinfo)
            let arch = withUnsafePointer(to: &sysinfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            return arch.hasPrefix("arm64")
            #else
            return false
            #endif
        }
    }
}

// MARK: - Transcription Backend Protocol

protocol TranscriptionBackend: AnyObject {
    /// Synchronous transcription of audio samples (16kHz mono float32)
    func transcribe(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32
    ) -> String

    /// Asynchronous transcription with completion handler (called on background queue)
    func transcribeAsync(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32,
        completion: @escaping (String) -> Void
    )

    /// Language code detected during the last transcription (e.g., "en", "de").
    /// Set by backends that support auto-detection (whisper.cpp). Nil if not detected.
    var lastDetectedLanguage: String? { get }

    /// Check if the backend is in a healthy state
    func isContextHealthy() -> Bool

    /// Prepare for app shutdown (drain queues, prevent new work)
    func prepareForShutdown()

    /// Signal the backend to abort any in-flight transcription immediately.
    /// Called by StreamingTranscriber.stopAsync() on all backends.
    func requestAbort()

    /// Reset abort flag before starting a new chunk transcription.
    /// Called by StreamingTranscriber.processNextChunk() on all backends.
    func resetAbort()

    /// Streaming-pipeline capabilities for this backend.
    /// Must be a computed var — never stored — so it is always derived from immutable bridge config.
    var streamingPolicy: BackendStreamingPolicy { get }
}

// MARK: - Default Parameter Values

extension TranscriptionBackend {
    var lastDetectedLanguage: String? { nil }

    func requestAbort() { }
    func resetAbort() { }

    /// Default policy: all capabilities off, conservative timing.
    /// Backends that need non-default behaviour override this computed var.
    var streamingPolicy: BackendStreamingPolicy {
        BackendStreamingPolicy(
            supportsEagerWordStream: false,
            requiresEagerEngine: false,
            suppressesVADChunking: false,
            maxVADChunkDuration: 30.0,
            previewPollInterval: 0.5,
            previewSharesDecodeQueue: false,
            serializesInferenceWithPreview: false
        )
    }

    // NOTE — do NOT add `transcribe`/`transcribeAsync` shims here just to supply default
    // parameter values. A protocol-extension method whose signature matches a requirement
    // *becomes* the witness for any conforming type that doesn't declare that exact
    // signature, and a shim that forwards to itself then recurses until the thread's 512 KB
    // stack hits its guard page — `EXC_BAD_ACCESS (code=2)` with no backtrace in the log.
    //
    // That is not hypothetical: adding `audioCtx:` to `WhisperBridge.transcribe` silently
    // unwitnessed the requirement and every call through a `TranscriptionBackend`-typed
    // reference crashed on the stop path (2026-08-17). With no shim, the same mistake is a
    // compile error instead. Concrete backends keep their own default arguments; call sites
    // holding the protocol type pass every argument explicitly.
    func transcribe(samples: [Float]) -> String {
        transcribe(samples: samples, initialPrompt: nil, language: .auto,
                   singleSegment: false, maxTokens: 0)
    }
}

// MARK: - Language Support

extension BackendType {
    private static let parakeetV2Languages: Set<String> = ["en"]
    private static let parakeetV3Languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
        "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk",
        "sl", "es", "sv", "ru", "uk"
    ]

    func supportsLanguage(
        _ language: TranscriptionLanguage,
        parakeetVariant: ParakeetModelVariant? = nil,
        speechAnalyzerLanguageCodes: Set<String>? = nil
    ) -> Bool {
        guard language != .auto else { return true }
        switch self {
        case .whisperCpp, .nemotron, .nemotronHebrew, .qwen3asr, .whisperKit: return true
        case .parakeet:
            let supported = (parakeetVariant == .v2) ? Self.parakeetV2Languages : Self.parakeetV3Languages
            return supported.contains(language.rawValue)
        case .speechAnalyzer:
            // Don't warn when locales haven't been loaded yet
            guard let codes = speechAnalyzerLanguageCodes, !codes.isEmpty else { return true }
            return codes.contains(language.rawValue)
        }
    }
}

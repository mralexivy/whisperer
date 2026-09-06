//
//  TranscriptionBackend.swift
//  Whisperer
//
//  Protocol abstraction for transcription backends (whisper.cpp, Parakeet, Apple Speech)
//

import Foundation

// MARK: - Backend Type

enum BackendType: String, CaseIterable, Identifiable {
    case whisperCpp = "whisper.cpp"
    case parakeet = "Parakeet"
    case nemotron = "Nemotron"
    case nemotronHebrew = "NemotronHebrew"
    case speechAnalyzer = "Apple Speech"
    case whisperKit = "WhisperKit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperCpp: return "Whisper"
        case .parakeet: return "Parakeet"
        case .nemotron: return "Nemotron"
        case .nemotronHebrew: return "Nemotron Hebrew"
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
        case .speechAnalyzer: return "macOS 26+"
        case .whisperKit: return "Core ML optimized · 100 languages"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .whisperCpp: return true
        case .parakeet, .nemotron, .nemotronHebrew:
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
}

// MARK: - Default Parameter Values

extension TranscriptionBackend {
    var lastDetectedLanguage: String? { nil }

    func requestAbort() { }
    func resetAbort() { }

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
        case .whisperCpp, .nemotron, .nemotronHebrew, .whisperKit: return true
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

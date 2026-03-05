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
    case speechAnalyzer = "Apple Speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperCpp: return "Whisper"
        case .parakeet: return "Parakeet"
        case .speechAnalyzer: return "Apple Speech"
        }
    }

    var iconName: String {
        switch self {
        case .whisperCpp: return "waveform"
        case .parakeet: return "bird.fill"
        case .speechAnalyzer: return "apple.logo"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .whisperCpp: return true
        case .parakeet:
            // Parakeet requires Apple Silicon (CoreML/ANE)
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
}

// MARK: - Default Parameter Values

extension TranscriptionBackend {
    var lastDetectedLanguage: String? { nil }

    func transcribe(
        samples: [Float],
        initialPrompt: String? = nil,
        language: TranscriptionLanguage = .auto,
        singleSegment: Bool = false,
        maxTokens: Int32 = 0
    ) -> String {
        transcribe(samples: samples, initialPrompt: initialPrompt, language: language, singleSegment: singleSegment, maxTokens: maxTokens)
    }

    func transcribeAsync(
        samples: [Float],
        initialPrompt: String? = nil,
        language: TranscriptionLanguage = .auto,
        singleSegment: Bool = false,
        maxTokens: Int32 = 0,
        completion: @escaping (String) -> Void
    ) {
        transcribeAsync(samples: samples, initialPrompt: initialPrompt, language: language, singleSegment: singleSegment, maxTokens: maxTokens, completion: completion)
    }
}

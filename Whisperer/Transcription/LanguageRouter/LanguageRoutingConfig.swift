//
//  LanguageRoutingConfig.swift
//  Whisperer
//
//  User configuration for multilingual language routing
//

import Foundation

struct LanguageRoutingConfig: Codable {
    var allowedLanguages: [TranscriptionLanguage]
    var primaryLanguage: TranscriptionLanguage?
    var languageModelOverrides: [String: String]  // lang rawValue → model rawValue
    var autoSwitchEnabled: Bool

    static let `default` = LanguageRoutingConfig(
        allowedLanguages: [.english],
        primaryLanguage: .english,
        languageModelOverrides: [:],
        autoSwitchEnabled: true
    )

    var isRoutingEnabled: Bool { allowedLanguages.count > 1 }

    /// The concrete language to start a transcriber with when routing is disabled (single allowed
    /// language). Returns nil when routing is enabled (the transcriber handles detection itself)
    /// or when the allowed set is empty — which is not a normal state.
    ///
    /// When `isRoutingEnabled` is false, neither LanguageRouter nor ModelRouter is created, so the
    /// transcriber never probes for a language. If `selectedLanguage` is `.auto` the transcriber
    /// runs the whole session as `.auto`, meaning whisper re-detects per eager pass and
    /// `languageIsLocked` is never true — confirmation is blocked for the full `unroutedCommitGrace`
    /// (30 s). Passing the sole allowed language resolves this: `languageIsLocked` is true from
    /// pass 1 without any detection machinery.
    var singleLanguageStartLanguage: TranscriptionLanguage? {
        guard !isRoutingEnabled, let sole = allowedLanguages.first, sole != .auto else { return nil }
        return sole
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "languageRoutingConfig"

    static func load() -> LanguageRoutingConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(LanguageRoutingConfig.self, from: data) else {
            return .default
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            Logger.error("Failed to encode LanguageRoutingConfig", subsystem: .app)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }
}

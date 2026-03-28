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

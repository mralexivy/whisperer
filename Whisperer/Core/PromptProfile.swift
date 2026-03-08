//
//  PromptProfile.swift
//  Whisperer
//
//  Named prompt presets for dictation and rewrite modes
//

import Foundation
import Combine

struct PromptProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var dictationPrompt: String?
    var rewritePrompt: String?
    var isDefault: Bool

    static let builtIn: [PromptProfile] = [
        PromptProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Default",
            dictationPrompt: nil,
            rewritePrompt: nil,
            isDefault: true
        ),
        PromptProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Coding",
            dictationPrompt: "Technical terminology, code identifiers, API names, function names, variable names",
            rewritePrompt: "You are a coding assistant. Rewrite text as clean, technical documentation or code comments. Use precise technical language.",
            isDefault: false
        ),
        PromptProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Email",
            dictationPrompt: "Professional email correspondence, greetings, regards, sincerely",
            rewritePrompt: "You are an email editor. Rewrite text as a professional email with appropriate tone, greeting, and sign-off.",
            isDefault: false
        ),
        PromptProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Creative",
            dictationPrompt: nil,
            rewritePrompt: "You are a creative writing assistant. Rewrite text with vivid, engaging language. Enhance descriptions and flow while preserving meaning.",
            isDefault: false
        ),
    ]
}

// MARK: - Persistence

@MainActor
class PromptProfileManager: ObservableObject {
    static let shared = PromptProfileManager()

    @Published var profiles: [PromptProfile] = []
    @Published var activeProfileId: UUID

    private let storageKey = "promptProfiles"
    private let activeProfileKey = "activeProfileId"

    private init() {
        let defaultId = PromptProfile.builtIn[0].id
        activeProfileId = defaultId

        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([PromptProfile].self, from: data) {
            profiles = saved
        } else {
            profiles = PromptProfile.builtIn
        }

        if let savedId = UserDefaults.standard.string(forKey: activeProfileKey),
           let uuid = UUID(uuidString: savedId),
           profiles.contains(where: { $0.id == uuid }) {
            activeProfileId = uuid
        }
    }

    var activeProfile: PromptProfile? {
        profiles.first { $0.id == activeProfileId }
    }

    func setActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
        UserDefaults.standard.set(id.uuidString, forKey: activeProfileKey)
    }

    func addProfile(_ profile: PromptProfile) {
        profiles.append(profile)
        persist()
    }

    func updateProfile(_ profile: PromptProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    func deleteProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isDefault else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileId == id {
            activeProfileId = profiles.first?.id ?? PromptProfile.builtIn[0].id
            UserDefaults.standard.set(activeProfileId.uuidString, forKey: activeProfileKey)
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

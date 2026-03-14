//
//  AIModeManager.swift
//  Whisperer
//
//  Manages AI mode presets with persistence and migration from legacy systems
//

import Foundation
import Combine

@MainActor
class AIModeManager: ObservableObject {
    static let shared = AIModeManager()

    @Published var modes: [AIMode] = []
    @Published var activeModeId: UUID

    private let storageKey = "aiModes"
    private let activeKey = "activeModeId"
    private let migrationKey = "aiModesMigrated"

    var activeMode: AIMode {
        modes.first { $0.id == activeModeId } ?? AIMode.defaultMode()
    }

    private init() {
        let defaultId = AIMode.builtInModes[0].id
        activeModeId = defaultId

        if UserDefaults.standard.bool(forKey: migrationKey),
           let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([AIMode].self, from: data) {
            modes = saved
        } else {
            modes = AIMode.builtInModes
            migrateFromLegacy()
            UserDefaults.standard.set(true, forKey: migrationKey)
            persist()
        }

        if let savedId = UserDefaults.standard.string(forKey: activeKey),
           let uuid = UUID(uuidString: savedId),
           modes.contains(where: { $0.id == uuid }) {
            activeModeId = uuid
        }
    }

    // MARK: - Public Methods

    func setActive(_ id: UUID) {
        guard modes.contains(where: { $0.id == id }) else { return }
        activeModeId = id
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
    }

    func addMode(_ mode: AIMode) {
        var newMode = mode
        newMode.sortOrder = (modes.map(\.sortOrder).max() ?? 0) + 1
        modes.append(newMode)
        persist()
    }

    func updateMode(_ mode: AIMode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index] = mode
        persist()
    }

    func deleteMode(_ id: UUID) {
        guard let mode = modes.first(where: { $0.id == id }), !mode.isBuiltIn else { return }
        modes.removeAll { $0.id == id }
        if activeModeId == id {
            activeModeId = modes.first?.id ?? AIMode.builtInModes[0].id
            UserDefaults.standard.set(activeModeId.uuidString, forKey: activeKey)
        }
        persist()
    }

    func resetToDefault(_ id: UUID) {
        guard let defaultMode = AIMode.builtInDefault(for: id),
              let index = modes.firstIndex(where: { $0.id == id }) else { return }
        modes[index] = defaultMode
        persist()
    }

    func duplicateMode(_ id: UUID) -> AIMode? {
        guard let source = modes.first(where: { $0.id == id }) else { return nil }
        let newMode = AIMode(
            id: UUID(),
            name: "\(source.name) Copy",
            icon: source.icon,
            color: source.color,
            systemPrompt: source.systemPrompt,
            rewritePrompt: source.rewritePrompt,
            temperature: source.temperature,
            topP: source.topP,
            isBuiltIn: false,
            targetLanguage: source.targetLanguage,
            sortOrder: (modes.map(\.sortOrder).max() ?? 0) + 1
        )
        modes.append(newMode)
        persist()
        return newMode
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(modes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Migration

    private func migrateFromLegacy() {
        // Migrate active task selection from old LLMTask system
        if let savedTask = UserDefaults.standard.string(forKey: "selectedLLMTask") {
            let taskToModeMap: [String: UUID] = [
                "Rewrite": AIMode.builtInModes[0].id,
                "Translate": AIMode.builtInModes[1].id,
                "Format": AIMode.builtInModes[2].id,
                "Summarize": AIMode.builtInModes[3].id,
                "Grammar": AIMode.builtInModes[4].id,
                "List Format": AIMode.builtInModes[5].id,
                "Custom": AIMode.builtInModes[9].id,
            ]
            if let modeId = taskToModeMap[savedTask] {
                activeModeId = modeId
                UserDefaults.standard.set(modeId.uuidString, forKey: activeKey)
            }
        }

        // Migrate custom prompt from old Custom task
        if let customPrompt = UserDefaults.standard.string(forKey: "llmCustomPrompt"), !customPrompt.isEmpty {
            if let customIndex = modes.firstIndex(where: { $0.name == "Custom" && $0.isBuiltIn }) {
                modes[customIndex].systemPrompt = customPrompt
            }
        }

        // Migrate translate language
        if let lang = UserDefaults.standard.string(forKey: "llmTranslateLanguage"), !lang.isEmpty {
            if let translateIndex = modes.firstIndex(where: { $0.name == "Translate" && $0.isBuiltIn }) {
                modes[translateIndex].targetLanguage = lang
            }
        }

        // Migrate custom PromptProfiles as custom AI modes
        if let data = UserDefaults.standard.data(forKey: "promptProfiles"),
           let profiles = try? JSONDecoder().decode([LegacyPromptProfile].self, from: data) {
            for profile in profiles where !profile.isDefault {
                // Skip if a built-in mode already has this name
                guard !modes.contains(where: { $0.name == profile.name && $0.isBuiltIn }) else { continue }
                // Skip if already migrated
                guard !modes.contains(where: { $0.name == profile.name && !$0.isBuiltIn }) else { continue }

                let mode = AIMode(
                    id: UUID(),
                    name: profile.name,
                    icon: "sparkle",
                    color: "A855F7",
                    systemPrompt: profile.dictationPrompt ?? "",
                    rewritePrompt: profile.rewritePrompt ?? "",
                    temperature: 0.3,
                    topP: 0.9,
                    isBuiltIn: false,
                    sortOrder: (modes.map(\.sortOrder).max() ?? 0) + 1
                )
                modes.append(mode)
            }
        }

        Logger.info("AI Modes migrated from legacy settings", subsystem: .app)
    }
}

// MARK: - Legacy Migration Type

/// Minimal struct for decoding legacy PromptProfile data during migration
private struct LegacyPromptProfile: Codable {
    var id: UUID
    var name: String
    var dictationPrompt: String?
    var rewritePrompt: String?
    var isDefault: Bool
}

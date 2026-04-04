//
//  AIModeManager.swift
//  Whisperer
//
//  Manages AI mode presets with persistence, function assignment, and migration
//

import Foundation
import Combine

@MainActor
class AIModeManager: ObservableObject {
    static let shared = AIModeManager()

    @Published var modes: [AIMode] = []
    @Published var activeModeId: UUID
    @Published var postProcessModeId: UUID
    @Published var rewriteModeId: UUID

    private let storageKey = "aiModes"
    private let activeKey = "activeModeId"
    private let postProcessKey = "postProcessModeId"
    private let rewriteKey = "rewriteModeId"
    private let migrationKey = "aiModesMigrated"
    private let promptVersionKey = "aiModesPromptVersion"

    /// Increment this when built-in prompts change to push updates to existing users.
    /// Only updates prompts that haven't been customized by the user.
    private static let currentPromptVersion = 6

    var activeMode: AIMode {
        modes.first { $0.id == activeModeId } ?? AIMode.defaultMode()
    }

    /// Mode used for post-processing transcribed speech
    var postProcessMode: AIMode {
        modes.first { $0.id == postProcessModeId } ?? AIMode.defaultMode()
    }

    /// Mode used for rewriting selected text with voice commands
    var rewriteMode: AIMode {
        modes.first { $0.id == rewriteModeId } ?? AIMode.builtInDefault(for: AIMode.rewriteModeId) ?? AIMode.defaultMode()
    }

    private init() {
        activeModeId = AIMode.correctModeId
        postProcessModeId = AIMode.correctModeId
        rewriteModeId = AIMode.rewriteModeId

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

        // Load function assignments
        if let savedPostProcess = UserDefaults.standard.string(forKey: postProcessKey),
           let uuid = UUID(uuidString: savedPostProcess),
           modes.contains(where: { $0.id == uuid }) {
            postProcessModeId = uuid
        }

        if let savedRewrite = UserDefaults.standard.string(forKey: rewriteKey),
           let uuid = UUID(uuidString: savedRewrite),
           modes.contains(where: { $0.id == uuid }) {
            rewriteModeId = uuid
        }

        refreshBuiltInPrompts()
    }

    // MARK: - Public Methods

    func setActive(_ id: UUID) {
        guard modes.contains(where: { $0.id == id }) else { return }
        activeModeId = id
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
    }

    func setPostProcessMode(_ id: UUID) {
        guard modes.contains(where: { $0.id == id }) else { return }
        postProcessModeId = id
        UserDefaults.standard.set(id.uuidString, forKey: postProcessKey)
    }

    func setRewriteMode(_ id: UUID) {
        guard modes.contains(where: { $0.id == id }) else { return }
        rewriteModeId = id
        UserDefaults.standard.set(id.uuidString, forKey: rewriteKey)
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
            activeModeId = modes.first?.id ?? AIMode.correctModeId
            UserDefaults.standard.set(activeModeId.uuidString, forKey: activeKey)
        }
        if postProcessModeId == id {
            postProcessModeId = AIMode.correctModeId
            UserDefaults.standard.set(postProcessModeId.uuidString, forKey: postProcessKey)
        }
        if rewriteModeId == id {
            rewriteModeId = AIMode.rewriteModeId
            UserDefaults.standard.set(rewriteModeId.uuidString, forKey: rewriteKey)
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
            prompt: source.prompt,
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

    // MARK: - Built-in Prompt Refresh

    /// Updates built-in mode prompts when the code defaults change.
    /// Inserts new built-in modes and updates existing prompts (only if not user-customized).
    private func refreshBuiltInPrompts() {
        let savedVersion = UserDefaults.standard.integer(forKey: promptVersionKey)
        guard savedVersion < Self.currentPromptVersion else { return }

        var updated = false

        // Insert any missing built-in modes (clamp index to avoid out-of-bounds crash)
        for builtIn in AIMode.builtInModes {
            if !modes.contains(where: { $0.id == builtIn.id }) {
                let insertIndex = min(builtIn.sortOrder, modes.count)
                modes.insert(builtIn, at: insertIndex)
                updated = true
                Logger.info("Inserted new built-in AI mode: \(builtIn.name)", subsystem: .app)

                // Set the new Correct mode as default for existing users
                if builtIn.id == AIMode.correctModeId {
                    activeModeId = builtIn.id
                    postProcessModeId = builtIn.id
                    UserDefaults.standard.set(builtIn.id.uuidString, forKey: activeKey)
                    UserDefaults.standard.set(builtIn.id.uuidString, forKey: postProcessKey)
                }
            }
        }

        // Update existing built-in modes with latest prompts
        for builtIn in AIMode.builtInModes {
            guard let index = modes.firstIndex(where: { $0.id == builtIn.id }) else { continue }
            if modes[index].prompt != builtIn.prompt {
                modes[index].prompt = builtIn.prompt
                updated = true
            }
        }

        UserDefaults.standard.set(Self.currentPromptVersion, forKey: promptVersionKey)
        if updated {
            persist()
            Logger.info("Built-in AI mode prompts refreshed to version \(Self.currentPromptVersion)", subsystem: .app)
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(modes)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            Logger.error("Failed to persist AI modes: \(error.localizedDescription)", subsystem: .app)
        }
    }

    // MARK: - Migration

    private func migrateFromLegacy() {
        // Migrate active task selection from old LLMTask system
        if let savedTask = UserDefaults.standard.string(forKey: "selectedLLMTask") {
            let taskToModeMap: [String: UUID] = [
                "Rewrite": AIMode.rewriteModeId,
                "Translate": AIMode.translateModeId,
                "Format": AIMode.formatModeId,
                "Summarize": AIMode.summarizeModeId,
                "Grammar": AIMode.grammarModeId,
                "List Format": AIMode.listFormatModeId,
                "Custom": AIMode.customModeId,
            ]
            if let modeId = taskToModeMap[savedTask] {
                activeModeId = modeId
                UserDefaults.standard.set(modeId.uuidString, forKey: activeKey)
            }
        }

        // Migrate custom prompt from old Custom task
        if let customPrompt = UserDefaults.standard.string(forKey: "llmCustomPrompt"), !customPrompt.isEmpty {
            if let customIndex = modes.firstIndex(where: { $0.name == "Custom" && $0.isBuiltIn }) {
                modes[customIndex].prompt = customPrompt
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
                guard !modes.contains(where: { $0.name == profile.name && $0.isBuiltIn }) else { continue }
                guard !modes.contains(where: { $0.name == profile.name && !$0.isBuiltIn }) else { continue }

                let mode = AIMode(
                    id: UUID(),
                    name: profile.name,
                    icon: "sparkle",
                    color: "A855F7",
                    prompt: profile.dictationPrompt ?? "",
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

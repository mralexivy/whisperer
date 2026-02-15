//
//  DictionaryPack.swift
//  Whisperer
//
//  Dictionary pack model for managing multiple dictionary files
//

import Foundation

struct DictionaryPack: Identifiable, Codable, Equatable {
    let id: String          // Filename without extension (e.g., "dict_01_languages_frameworks")
    let filename: String    // Full filename with extension
    let name: String        // From metadata.category
    let version: String     // From metadata.version
    let entryCount: Int     // Total entries (sum of all aliases)
    var isEnabled: Bool     // User preference, defaults to true
    let description: String? // Optional description from metadata

    var isWorkflowPack: Bool {
        filename.hasPrefix("workflow_")
    }

    var icon: String {
        isWorkflowPack ? "briefcase" : "book.closed"
    }
}

// MARK: - Dictionary Pack File Format

struct DictionaryPackFile: Codable {
    let metadata: Metadata
    let corrections: [Correction]

    struct Metadata: Codable {
        let category: String
        let version: String
        let totalEntries: Int?
        let description: String?
        let totalCorrections: Int?  // Alternative field name used in workflow files
    }

    struct Correction: Codable {
        let term: String
        let aliases: [String]
    }

    /// Count total entries (sum of all aliases across all corrections)
    var totalEntryCount: Int {
        corrections.reduce(0) { $0 + $1.aliases.count }
    }
}

// MARK: - Pack Preferences Storage

struct DictionaryPackPreferences: Codable {
    var enabledPacks: [String: Bool] = [:]      // packId -> isEnabled
    var loadedVersions: [String: String] = [:]  // packId -> version

    mutating func setEnabled(_ packId: String, enabled: Bool) {
        enabledPacks[packId] = enabled
    }

    func isEnabled(_ packId: String) -> Bool {
        enabledPacks[packId] ?? true  // Default to enabled
    }

    mutating func setLoadedVersion(_ packId: String, version: String) {
        loadedVersions[packId] = version
    }

    func getLoadedVersion(_ packId: String) -> String? {
        loadedVersions[packId]
    }
}

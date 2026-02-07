//
//  DictionaryEntry.swift
//  Whisperer
//
//  Swift model wrapper for dictionary entries
//

import Foundation

struct DictionaryEntry: Identifiable, Codable {
    let id: UUID
    let incorrectForm: String
    let correctForm: String
    let category: String?
    let isBuiltIn: Bool
    let isEnabled: Bool
    let notes: String?
    let createdAt: Date
    let lastModifiedAt: Date
    let useCount: Int

    init(
        id: UUID = UUID(),
        incorrectForm: String,
        correctForm: String,
        category: String? = nil,
        isBuiltIn: Bool = false,
        isEnabled: Bool = true,
        notes: String? = nil,
        createdAt: Date = Date(),
        lastModifiedAt: Date = Date(),
        useCount: Int = 0
    ) {
        self.id = id
        self.incorrectForm = incorrectForm.lowercased()
        self.correctForm = correctForm
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.notes = notes
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
        self.useCount = useCount
    }

    init(from entity: DictionaryEntryEntity) {
        self.id = entity.id
        self.incorrectForm = entity.incorrectForm
        self.correctForm = entity.correctForm
        self.category = entity.category
        self.isBuiltIn = entity.isBuiltIn
        self.isEnabled = entity.isEnabled
        self.notes = entity.notes
        self.createdAt = entity.createdAt
        self.lastModifiedAt = entity.lastModifiedAt
        self.useCount = Int(entity.useCount)
    }
}

// MARK: - Dictionary Filter

enum DictionaryFilter {
    case all
    case programming
    case devops
    case cloud
    case custom
    case enabled
    case disabled

    var predicate: String? {
        switch self {
        case .all:
            return nil
        case .programming:
            return "category == 'Programming'"
        case .devops:
            return "category == 'DevOps'"
        case .cloud:
            return "category == 'Cloud'"
        case .custom:
            return "isBuiltIn == NO"
        case .enabled:
            return "isEnabled == YES"
        case .disabled:
            return "isEnabled == NO"
        }
    }
}

// MARK: - Correction Result

struct AppliedCorrection: Identifiable, Equatable, Codable {
    let id: UUID
    let original: String
    let replacement: String
    let category: String?
    let notes: String?
    let entryId: UUID  // Dictionary entry ID for navigation

    init(original: String, replacement: String, category: String? = nil, notes: String? = nil, entryId: UUID) {
        self.id = UUID()
        self.original = original
        self.replacement = replacement
        self.category = category
        self.notes = notes
        self.entryId = entryId
    }
}

// MARK: - Bundled Dictionary Format

struct BundledDictionary: Codable {
    let version: String
    let entries: [BundledEntry]

    struct BundledEntry: Codable {
        let incorrectForm: String
        let correctForm: String
        let category: String?
        let notes: String?
    }
}

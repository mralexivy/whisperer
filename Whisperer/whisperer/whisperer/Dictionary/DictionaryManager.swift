//
//  DictionaryManager.swift
//  Whisperer
//
//  Singleton for managing dictionary CRUD operations
//

import Foundation
import CoreData
import Combine

@MainActor
class DictionaryManager: ObservableObject {
    static let shared = DictionaryManager()

    @Published var entries: [DictionaryEntry] = []
    @Published var isEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "dictionaryEnabled")
            if isEnabled {
                correctionEngine?.rebuild(with: entries.filter { $0.isEnabled })
            }
        }
    }
    @Published var fuzzyMatchingSensitivity: Int = 2 {
        didSet {
            UserDefaults.standard.set(fuzzyMatchingSensitivity, forKey: "fuzzyMatchingSensitivity")
        }
    }
    @Published var usePhoneticMatching: Bool = true {
        didSet {
            UserDefaults.standard.set(usePhoneticMatching, forKey: "usePhoneticMatching")
        }
    }
    @Published var lastCorrections: [AppliedCorrection] = []
    @Published var selectedEntryId: UUID? = nil  // For navigation from correction popover

    private let database = HistoryDatabase.shared
    private var context: NSManagedObjectContext {
        database.viewContext
    }

    private var correctionEngine: CorrectionEngine?

    private init() {
        // Load enabled state
        isEnabled = UserDefaults.standard.object(forKey: "dictionaryEnabled") as? Bool ?? true

        // Load fuzzy matching settings
        fuzzyMatchingSensitivity = UserDefaults.standard.object(forKey: "fuzzyMatchingSensitivity") as? Int ?? 2
        usePhoneticMatching = UserDefaults.standard.object(forKey: "usePhoneticMatching") as? Bool ?? true

        Task {
            await loadEntries()
            await loadBundledDictionaryIfNeeded()
            // Initialize correction engine with loaded entries
            let enabledEntries = entries.filter { $0.isEnabled }
            correctionEngine = CorrectionEngine(entries: enabledEntries)
        }
    }

    // MARK: - Create

    func addEntry(_ entry: DictionaryEntry) async throws {
        let context = database.newBackgroundContext()

        await context.perform {
            _ = DictionaryEntryEntity.create(
                in: context,
                incorrectForm: entry.incorrectForm,
                correctForm: entry.correctForm,
                category: entry.category,
                isBuiltIn: entry.isBuiltIn,
                notes: entry.notes
            )

            do {
                try context.save()
            } catch {
                Logger.error("Failed to save dictionary entry: \(error)", subsystem: .app)
            }
        }

        await loadEntries()
        rebuildCorrectionEngine()
    }

    func addEntryIfNotExists(_ entry: DictionaryEntry, isBuiltIn: Bool) async throws {
        // Check if entry with same incorrectForm already exists
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "incorrectForm == %@", entry.incorrectForm)
        fetchRequest.fetchLimit = 1

        if let _ = try? context.fetch(fetchRequest).first {
            // Entry already exists, skip
            return
        }

        // Add new entry
        var newEntry = entry
        newEntry = DictionaryEntry(
            id: entry.id,
            incorrectForm: entry.incorrectForm,
            correctForm: entry.correctForm,
            category: entry.category,
            isBuiltIn: isBuiltIn,
            isEnabled: entry.isEnabled,
            notes: entry.notes,
            createdAt: entry.createdAt,
            lastModifiedAt: entry.lastModifiedAt,
            useCount: entry.useCount
        )
        try await addEntry(newEntry)
    }

    // MARK: - Read

    func loadEntries(filter: DictionaryFilter = .all, searchQuery: String? = nil) async {
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "incorrectForm", ascending: true)]

        var predicates: [NSPredicate] = []

        // Apply filter
        if let filterPredicate = filter.predicate {
            predicates.append(NSPredicate(format: filterPredicate))
        }

        // Apply search
        if let query = searchQuery, !query.isEmpty {
            predicates.append(NSPredicate(
                format: "incorrectForm CONTAINS[cd] %@ OR correctForm CONTAINS[cd] %@ OR notes CONTAINS[cd] %@",
                query, query, query
            ))
        }

        if !predicates.isEmpty {
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        do {
            let entities = try context.fetch(fetchRequest)
            entries = entities.map { DictionaryEntry(from: $0) }
        } catch {
            Logger.error("Failed to load dictionary entries: \(error)", subsystem: .app)
        }
    }

    // MARK: - Update

    func updateEntry(_ entry: DictionaryEntry) async throws {
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw DictionaryError.entryNotFound
        }

        entity.incorrectForm = entry.incorrectForm.lowercased()
        entity.correctForm = entry.correctForm
        entity.category = entry.category
        entity.isEnabled = entry.isEnabled
        entity.notes = entry.notes
        entity.lastModifiedAt = Date()

        try context.save()
        await loadEntries()
        rebuildCorrectionEngine()
    }

    func toggleEntry(_ entry: DictionaryEntry) async throws {
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw DictionaryError.entryNotFound
        }

        entity.isEnabled.toggle()
        entity.lastModifiedAt = Date()

        try context.save()
        await loadEntries()
        rebuildCorrectionEngine()
    }

    func incrementUseCount(_ incorrectForm: String) async {
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "incorrectForm == %@", incorrectForm.lowercased())
        fetchRequest.fetchLimit = 1

        guard let entity = try? context.fetch(fetchRequest).first else { return }

        entity.useCount += 1
        try? context.save()
    }

    // MARK: - Delete

    func deleteEntry(_ entry: DictionaryEntry) async throws {
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw DictionaryError.entryNotFound
        }

        context.delete(entity)
        try context.save()

        await loadEntries()
        rebuildCorrectionEngine()
    }

    func deleteAllEntries() async throws {
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()

        do {
            let allEntities = try context.fetch(fetchRequest)
            for entity in allEntities {
                context.delete(entity)
            }
            try context.save()
            await loadEntries()
            rebuildCorrectionEngine()
        } catch {
            Logger.error("Failed to delete all dictionary entries: \(error)", subsystem: .app)
            throw error
        }
    }

    // MARK: - Bundled Dictionary

    func loadBundledDictionaryIfNeeded() async {
        // Check if we've already loaded the bundled dictionary
        let hasLoadedKey = "hasLoadedBundledDictionary"
        if UserDefaults.standard.bool(forKey: hasLoadedKey) {
            return
        }

        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "json") else {
            Logger.warning("Bundled dictionary not found", subsystem: .app)
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let bundledDict = try JSONDecoder().decode(BundledDictionary.self, from: data)

            Logger.debug("Loading \(bundledDict.entries.count) bundled dictionary entries", subsystem: .app)

            for entry in bundledDict.entries {
                let dictEntry = DictionaryEntry(
                    incorrectForm: entry.incorrectForm,
                    correctForm: entry.correctForm,
                    category: entry.category,
                    isBuiltIn: true,
                    notes: entry.notes
                )
                try await addEntryIfNotExists(dictEntry, isBuiltIn: true)
            }

            UserDefaults.standard.set(true, forKey: hasLoadedKey)
            Logger.debug("Bundled dictionary loaded successfully", subsystem: .app)
        } catch {
            Logger.error("Failed to load bundled dictionary: \(error)", subsystem: .app)
        }
    }

    // MARK: - Import/Export

    func importFromJSON(_ url: URL) async throws {
        let data = try Data(contentsOf: url)
        let bundledDict = try JSONDecoder().decode(BundledDictionary.self, from: data)

        for entry in bundledDict.entries {
            let dictEntry = DictionaryEntry(
                incorrectForm: entry.incorrectForm,
                correctForm: entry.correctForm,
                category: entry.category,
                isBuiltIn: false,
                notes: entry.notes
            )
            try await addEntry(dictEntry)
        }
    }

    func exportToJSON() async throws -> URL {
        let exportDict = BundledDictionary(
            version: "1.0",
            entries: entries.map { entry in
                BundledDictionary.BundledEntry(
                    incorrectForm: entry.incorrectForm,
                    correctForm: entry.correctForm,
                    category: entry.category,
                    notes: entry.notes
                )
            }
        )

        let data = try JSONEncoder().encode(exportDict)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary_export.json")
        try data.write(to: tempURL)
        return tempURL
    }

    // MARK: - Correction Engine

    func correctText(_ text: String) -> String {
        guard isEnabled, let engine = correctionEngine else {
            return text
        }

        // Use the new sensitivity settings (0 = exact match only, 1-3 = edit distance)
        let maxEditDistance = fuzzyMatchingSensitivity
        let result = engine.applyCorrections(text, maxEditDistance: maxEditDistance, usePhonetic: usePhoneticMatching)

        // Store corrections for UI display
        lastCorrections = result.corrections.map { AppliedCorrection(original: $0.original, replacement: $0.replacement, category: $0.category, notes: $0.notes, entryId: $0.entryId) }

        // Log corrections for debugging
        if !result.corrections.isEmpty {
            Logger.debug("📖 Applied \(result.corrections.count) dictionary corrections (sensitivity: \(maxEditDistance), phonetic: \(usePhoneticMatching)):", subsystem: .app)
            for correction in result.corrections {
                Logger.debug("  • \(correction.original) → \(correction.replacement)", subsystem: .app)
            }
        }

        // Increment use counts for applied corrections
        Task {
            for correction in result.corrections {
                await incrementUseCount(correction.original)
            }
        }

        return result.text
    }

    // MARK: - Navigation

    func navigateToEntry(_ entryId: UUID) {
        Task {
            // Ensure entries are loaded
            if entries.isEmpty {
                await loadEntries()
            }

            // Set selected entry ID on main thread
            await MainActor.run {
                selectedEntryId = entryId
            }
        }
    }

    private func rebuildCorrectionEngine() {
        let enabledEntries = entries.filter { $0.isEnabled }
        correctionEngine?.rebuild(with: enabledEntries)
    }
}

// MARK: - Errors

enum DictionaryError: Error {
    case entryNotFound
    case invalidData
}

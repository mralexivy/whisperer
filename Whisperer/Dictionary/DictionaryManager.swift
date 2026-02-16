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
    @Published var packs: [DictionaryPack] = []  // Available dictionary packs
    @Published var isLoadingEntries: Bool = true  // For UI skeleton loading
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
    private var packPreferences = DictionaryPackPreferences()
    private let packPreferencesKey = "dictionaryPackPreferences"

    private init() {
        // Load enabled state
        isEnabled = UserDefaults.standard.object(forKey: "dictionaryEnabled") as? Bool ?? true

        // Load fuzzy matching settings
        fuzzyMatchingSensitivity = UserDefaults.standard.object(forKey: "fuzzyMatchingSensitivity") as? Int ?? 2
        usePhoneticMatching = UserDefaults.standard.object(forKey: "usePhoneticMatching") as? Bool ?? true

        // Load pack preferences
        if let data = UserDefaults.standard.data(forKey: packPreferencesKey),
           let prefs = try? JSONDecoder().decode(DictionaryPackPreferences.self, from: data) {
            packPreferences = prefs
        }

        // Capture pack preferences before detaching (main actor isolated)
        let capturedPackPrefs = packPreferences

        // Load data in background to avoid blocking UI
        Task.detached { [weak self] in
            guard self != nil else { return }

            // Load packs from files (background thread)
            let loadedPacks = await Self.loadPacksInBackground(packPreferences: capturedPackPrefs)

            // Load entries from CoreData (background context)
            let loadedEntries = await Self.loadEntriesInBackground()

            // Also check if bundled dictionary needs loading
            await Self.loadBundledDictionaryInBackground(packs: loadedPacks, packPreferences: capturedPackPrefs)

            // Reload entries after bundled loading
            let finalEntries = await Self.loadEntriesInBackground()

            // Build correction engine on background thread (SymSpell + PhoneticMatcher
            // index building is expensive and would block the main actor for ~2s,
            // delaying text injection on the first recording)
            let enabledEntries = finalEntries.filter { $0.isEnabled }
            let engine = CorrectionEngine(entries: enabledEntries)

            // Only assign references on main thread (fast)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.packs = loadedPacks
                self.entries = finalEntries
                self.isLoadingEntries = false
                self.correctionEngine = engine
            }
        }
    }

    // MARK: - Background Loading (off main thread)

    /// Load packs from bundle files without blocking main thread
    private static func loadPacksInBackground(packPreferences: DictionaryPackPreferences) async -> [DictionaryPack] {
        guard let resourcePath = Bundle.main.resourcePath else {
            return []
        }

        let fileManager = FileManager.default
        var loadedPacks: [DictionaryPack] = []

        let dictionariesPath = (resourcePath as NSString).appendingPathComponent("dictionaries")
        let searchPath = fileManager.fileExists(atPath: dictionariesPath) ? dictionariesPath : resourcePath

        do {
            let files = try fileManager.contentsOfDirectory(atPath: searchPath)
            let jsonFiles = files.filter {
                $0.hasSuffix(".json") && $0.hasPrefix("pack_")
            }.sorted()

            for filename in jsonFiles {
                let filePath = (searchPath as NSString).appendingPathComponent(filename)
                let url = URL(fileURLWithPath: filePath)

                do {
                    let data = try Data(contentsOf: url)
                    let packFile = try JSONDecoder().decode(DictionaryPackFile.self, from: data)

                    let packId = (filename as NSString).deletingPathExtension
                    let pack = DictionaryPack(
                        id: packId,
                        filename: filename,
                        name: packFile.metadata.category,
                        version: packFile.metadata.version,
                        entryCount: packFile.totalEntryCount,
                        isEnabled: packPreferences.isEnabled(packId),
                        description: packFile.metadata.description
                    )

                    loadedPacks.append(pack)
                } catch {
                    Logger.error("Failed to load pack \(filename): \(error)", subsystem: .app)
                }
            }
        } catch {
            Logger.error("Failed to read dictionaries folder: \(error)", subsystem: .app)
        }

        return loadedPacks
    }

    /// Load entries from CoreData using background context
    private static func loadEntriesInBackground() async -> [DictionaryEntry] {
        let database = HistoryDatabase.shared
        let context = database.newBackgroundContext()

        return await context.perform {
            let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "incorrectForm", ascending: true)]

            do {
                let entities = try context.fetch(fetchRequest)
                return entities.map { DictionaryEntry(from: $0) }
            } catch {
                Logger.error("Failed to load dictionary entries in background: \(error)", subsystem: .app)
                return []
            }
        }
    }

    /// Load bundled dictionary entries in background if needed
    private static func loadBundledDictionaryInBackground(packs: [DictionaryPack], packPreferences: DictionaryPackPreferences) async {
        let database = HistoryDatabase.shared
        let context = database.newBackgroundContext()

        // Load entries from all enabled packs that haven't been loaded or have new versions
        for pack in packs where pack.isEnabled {
            let loadedVersion = packPreferences.getLoadedVersion(pack.id)

            if loadedVersion == nil || loadedVersion != pack.version {
                await loadEntriesFromPackInBackground(pack, context: context, packPreferences: packPreferences)
            }
        }

        // Legacy dictionary.json support
        let hasLoadedKey = "hasLoadedBundledDictionary"
        if !UserDefaults.standard.bool(forKey: hasLoadedKey) {
            if let url = Bundle.main.url(forResource: "dictionary", withExtension: "json") {
                do {
                    let data = try Data(contentsOf: url)
                    let bundledDict = try JSONDecoder().decode(BundledDictionary.self, from: data)

                    await context.perform {
                        for entry in bundledDict.entries {
                            // Check if exists
                            let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
                            fetchRequest.predicate = NSPredicate(format: "incorrectForm == %@", entry.incorrectForm)
                            fetchRequest.fetchLimit = 1

                            if (try? context.fetch(fetchRequest).first) == nil {
                                _ = DictionaryEntryEntity.create(
                                    in: context,
                                    incorrectForm: entry.incorrectForm,
                                    correctForm: entry.correctForm,
                                    category: entry.category,
                                    isBuiltIn: true,
                                    notes: entry.notes
                                )
                            }
                        }
                        try? context.save()
                    }

                    await MainActor.run {
                        UserDefaults.standard.set(true, forKey: hasLoadedKey)
                    }
                } catch {
                    Logger.error("Failed to load legacy bundled dictionary: \(error)", subsystem: .app)
                }
            }
        }
    }

    /// Load entries from a specific pack in background
    private static func loadEntriesFromPackInBackground(_ pack: DictionaryPack, context: NSManagedObjectContext, packPreferences: DictionaryPackPreferences) async {
        guard let resourcePath = Bundle.main.resourcePath else { return }

        let fileManager = FileManager.default
        let dictionariesPath = (resourcePath as NSString).appendingPathComponent("dictionaries")
        let searchPath = fileManager.fileExists(atPath: dictionariesPath) ? dictionariesPath : resourcePath
        let filePath = (searchPath as NSString).appendingPathComponent(pack.filename)
        let url = URL(fileURLWithPath: filePath)

        do {
            let data = try Data(contentsOf: url)
            let packFile = try JSONDecoder().decode(DictionaryPackFile.self, from: data)

            await context.perform {
                for correction in packFile.corrections {
                    let correctForm = correction.term

                    for alias in correction.aliases {
                        // Check if exists
                        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "incorrectForm == %@", alias.lowercased())
                        fetchRequest.fetchLimit = 1

                        if (try? context.fetch(fetchRequest).first) == nil {
                            _ = DictionaryEntryEntity.create(
                                in: context,
                                incorrectForm: alias,
                                correctForm: correctForm,
                                category: packFile.metadata.category,
                                isBuiltIn: true,
                                notes: "From \(pack.name)"
                            )
                        }
                    }
                }
                try? context.save()
            }

            // Update loaded version
            var mutablePrefs = packPreferences
            mutablePrefs.setLoadedVersion(pack.id, version: pack.version)
            if let data = try? JSONEncoder().encode(mutablePrefs) {
                await MainActor.run {
                    UserDefaults.standard.set(data, forKey: "dictionaryPackPreferences")
                }
            }
        } catch {
            Logger.error("Failed to load entries from pack \(pack.name): \(error)", subsystem: .app)
        }
    }

    // MARK: - Create

    func addEntry(_ entry: DictionaryEntry, skipRebuild: Bool = false) async throws {
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

        if !skipRebuild {
            await loadEntries()
            rebuildCorrectionEngine()
        }
    }

    func addEntryIfNotExists(_ entry: DictionaryEntry, isBuiltIn: Bool, skipRebuild: Bool = false) async throws {
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
        try await addEntry(newEntry, skipRebuild: skipRebuild)
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

    // MARK: - Dictionary Packs

    /// Load all dictionary packs from the bundle
    func loadPacks() async {
        guard let resourcePath = Bundle.main.resourcePath else {
            Logger.warning("Resource path not found", subsystem: .app)
            return
        }

        let fileManager = FileManager.default
        var loadedPacks: [DictionaryPack] = []

        // Check if dictionaries are in a subfolder (Resources/dictionaries/)
        let dictionariesPath = (resourcePath as NSString).appendingPathComponent("dictionaries")
        let searchPath: String

        if fileManager.fileExists(atPath: dictionariesPath) {
            searchPath = dictionariesPath
            Logger.debug("Found dictionaries folder at: \(dictionariesPath)", subsystem: .app)
        } else {
            // Fall back to Resources folder directly
            searchPath = resourcePath
            Logger.debug("Searching for dictionaries in Resources folder: \(resourcePath)", subsystem: .app)
        }

        do {
            let files = try fileManager.contentsOfDirectory(atPath: searchPath)
            // Filter for pack_*.json files only
            let jsonFiles = files.filter {
                $0.hasSuffix(".json") && $0.hasPrefix("pack_")
            }.sorted()

            Logger.debug("Found \(jsonFiles.count) dictionary pack files", subsystem: .app)

            for filename in jsonFiles {
                let filePath = (searchPath as NSString).appendingPathComponent(filename)
                let url = URL(fileURLWithPath: filePath)

                do {
                    let data = try Data(contentsOf: url)
                    let packFile = try JSONDecoder().decode(DictionaryPackFile.self, from: data)

                    let packId = (filename as NSString).deletingPathExtension
                    let pack = DictionaryPack(
                        id: packId,
                        filename: filename,
                        name: packFile.metadata.category,
                        version: packFile.metadata.version,
                        entryCount: packFile.totalEntryCount,
                        isEnabled: packPreferences.isEnabled(packId),
                        description: packFile.metadata.description
                    )

                    loadedPacks.append(pack)
                    Logger.debug("Loaded pack: \(pack.name) (\(pack.entryCount) entries)", subsystem: .app)
                } catch {
                    Logger.error("Failed to load pack \(filename): \(error)", subsystem: .app)
                }
            }

            packs = loadedPacks
            Logger.debug("Loaded \(packs.count) dictionary packs", subsystem: .app)
        } catch {
            Logger.error("Failed to read dictionaries folder: \(error)", subsystem: .app)
        }
    }

    /// Toggle a dictionary pack on/off
    func togglePack(_ pack: DictionaryPack) async throws {
        guard let index = packs.firstIndex(where: { $0.id == pack.id }) else { return }

        packs[index].isEnabled.toggle()
        packPreferences.setEnabled(pack.id, enabled: packs[index].isEnabled)
        savePackPreferences()

        // Reload entries from all enabled packs
        await reloadAllPackEntries()
    }

    /// Reload all entries from enabled packs
    private func reloadAllPackEntries() async {
        // Delete all built-in entries
        let fetchRequest: NSFetchRequest<DictionaryEntryEntity> = DictionaryEntryEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "isBuiltIn == YES")

        do {
            let builtInEntities = try context.fetch(fetchRequest)
            for entity in builtInEntities {
                context.delete(entity)
            }
            try context.save()
        } catch {
            Logger.error("Failed to delete built-in entries: \(error)", subsystem: .app)
        }

        // Load entries from all enabled packs
        for pack in packs where pack.isEnabled {
            await loadEntriesFromPack(pack)
        }

        await loadEntries()
        rebuildCorrectionEngine()
    }

    /// Load entries from a specific pack
    private func loadEntriesFromPack(_ pack: DictionaryPack) async {
        guard let resourcePath = Bundle.main.resourcePath else { return }

        let fileManager = FileManager.default
        let dictionariesPath = (resourcePath as NSString).appendingPathComponent("dictionaries")

        // Check if dictionaries are in a subfolder or directly in Resources
        let searchPath = fileManager.fileExists(atPath: dictionariesPath) ? dictionariesPath : resourcePath
        let filePath = (searchPath as NSString).appendingPathComponent(pack.filename)
        let url = URL(fileURLWithPath: filePath)

        do {
            let data = try Data(contentsOf: url)
            let packFile = try JSONDecoder().decode(DictionaryPackFile.self, from: data)

            Logger.debug("Loading \(packFile.totalEntryCount) entries from \(pack.name)", subsystem: .app)

            // Convert each correction (term + aliases) to individual dictionary entries
            for correction in packFile.corrections {
                let correctForm = correction.term

                for alias in correction.aliases {
                    let entry = DictionaryEntry(
                        incorrectForm: alias,
                        correctForm: correctForm,
                        category: packFile.metadata.category,
                        isBuiltIn: true,
                        notes: "From \(pack.name)"
                    )
                    try await addEntryIfNotExists(entry, isBuiltIn: true, skipRebuild: true)
                }
            }

            // Update loaded version
            packPreferences.setLoadedVersion(pack.id, version: pack.version)
            savePackPreferences()
        } catch {
            Logger.error("Failed to load entries from pack \(pack.name): \(error)", subsystem: .app)
        }
    }

    /// Save pack preferences to UserDefaults
    private func savePackPreferences() {
        if let data = try? JSONEncoder().encode(packPreferences) {
            UserDefaults.standard.set(data, forKey: packPreferencesKey)
        }
    }

    // MARK: - Bundled Dictionary (Legacy)

    func loadBundledDictionaryIfNeeded() async {
        // NEW: Load from packs instead of single dictionary file
        for pack in packs where pack.isEnabled {
            let loadedVersion = packPreferences.getLoadedVersion(pack.id)

            // Load if not loaded before, or if version has changed
            if loadedVersion == nil || loadedVersion != pack.version {
                Logger.debug("Loading/updating pack: \(pack.name) (v\(pack.version))", subsystem: .app)
                await loadEntriesFromPack(pack)
            }
        }

        // LEGACY: Still support old dictionary.json for backwards compatibility
        let hasLoadedKey = "hasLoadedBundledDictionary"
        if !UserDefaults.standard.bool(forKey: hasLoadedKey) {
            if let url = Bundle.main.url(forResource: "dictionary", withExtension: "json") {
                do {
                    let data = try Data(contentsOf: url)
                    let bundledDict = try JSONDecoder().decode(BundledDictionary.self, from: data)

                    Logger.debug("Loading \(bundledDict.entries.count) legacy bundled dictionary entries", subsystem: .app)

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
                    Logger.debug("Legacy bundled dictionary loaded successfully", subsystem: .app)
                } catch {
                    Logger.error("Failed to load legacy bundled dictionary: \(error)", subsystem: .app)
                }
            }
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

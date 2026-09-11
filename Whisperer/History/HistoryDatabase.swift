//
//  HistoryDatabase.swift
//  Whisperer
//
//  Core Data stack for history storage
//

import Foundation
import CoreData

class HistoryDatabase {
    static let shared = HistoryDatabase()

    /// Error that occurred during initialization, if any
    private(set) var initializationError: Error?

    private let inMemory: Bool

    lazy var persistentContainer: NSPersistentContainer? = {
        // Find the model in the app bundle
        guard let modelURL = Bundle.main.url(forResource: "WhispererHistory", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            Logger.error("Unable to find Core Data model - history will be unavailable", subsystem: .app)
            initializationError = HistoryDatabaseError.modelNotFound
            return nil
        }

        let container = NSPersistentContainer(name: "WhispererHistory", managedObjectModel: model)

        if inMemory {
            let desc = NSPersistentStoreDescription()
            desc.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [desc]
        } else {
            // Set store location
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let whispererDir = appSupport.appendingPathComponent("Whisperer")

            // Create directory if needed
            try? fileManager.createDirectory(at: whispererDir, withIntermediateDirectories: true)

            let storeURL = whispererDir.appendingPathComponent("history.sqlite")
            let description = NSPersistentStoreDescription(url: storeURL)
            // Enable automatic migration
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                Logger.error("Core Data failed to load: \(error.localizedDescription)", subsystem: .app)
            } else {
                Logger.debug("Core Data loaded from: \(description.url?.path ?? "unknown")", subsystem: .app)
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return container
    }()

    var viewContext: NSManagedObjectContext {
        guard let container = persistentContainer else {
            Logger.error("Core Data unavailable - returning in-memory context", subsystem: .app)
            // Return an in-memory context as fallback
            let inMemoryContainer = NSPersistentContainer(name: "WhispererHistory")
            let inMemoryDescription = NSPersistentStoreDescription()
            inMemoryDescription.type = NSInMemoryStoreType
            inMemoryContainer.persistentStoreDescriptions = [inMemoryDescription]
            inMemoryContainer.loadPersistentStores { _, _ in }
            return inMemoryContainer.viewContext
        }
        return container.viewContext
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        guard let container = persistentContainer else {
            Logger.error("Core Data unavailable - returning in-memory context", subsystem: .app)
            let inMemoryContainer = NSPersistentContainer(name: "WhispererHistory")
            let inMemoryDescription = NSPersistentStoreDescription()
            inMemoryDescription.type = NSInMemoryStoreType
            inMemoryContainer.persistentStoreDescriptions = [inMemoryDescription]
            inMemoryContainer.loadPersistentStores { _, _ in }
            return inMemoryContainer.newBackgroundContext()
        }
        return container.newBackgroundContext()
    }

    // Designated init. `shared` uses the on-disk store; tests build an in-memory instance.
    init(inMemory: Bool) {
        self.inMemory = inMemory
        _ = persistentContainer
        if !inMemory { migrateWordCountsIfNeeded() }
    }

    private convenience init() {
        self.init(inMemory: false)
        migrateNullUUIDsIfNeeded()
    }

    // MARK: - Migrations

    /// One-time migration that assigns a fresh UUID to any TranscriptionEntity rows whose
    /// `id` column is NULL. This happens when the attribute was added to the model after
    /// the store was created — lightweight migration leaves existing rows with NULL, which
    /// causes EXC_BAD_ACCESS when Swift bridges the nil ObjC value to a non-optional UUID.
    private func migrateNullUUIDsIfNeeded() {
        let migrationKey = "nullUUIDMigrationV1Done"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        guard let container = persistentContainer else { return }

        let context = container.newBackgroundContext()
        context.perform {
            let request: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
            do {
                let entities = try context.fetch(request)
                var patched = 0
                for entity in entities {
                    if entity.value(forKey: "id") == nil {
                        entity.setValue(UUID(), forKey: "id")
                        patched += 1
                    }
                    if entity.value(forKey: "timestamp") == nil {
                        entity.setValue(Date(), forKey: "timestamp")
                    }
                    if entity.value(forKey: "createdAt") == nil {
                        entity.setValue(Date(), forKey: "createdAt")
                    }
                    if entity.value(forKey: "lastModifiedAt") == nil {
                        entity.setValue(Date(), forKey: "lastModifiedAt")
                    }
                    if entity.value(forKey: "transcription") == nil {
                        entity.setValue("", forKey: "transcription")
                    }
                    if entity.value(forKey: "language") == nil {
                        entity.setValue("en", forKey: "language")
                    }
                    if entity.value(forKey: "modelUsed") == nil {
                        entity.setValue("", forKey: "modelUsed")
                    }
                }
                if context.hasChanges {
                    try context.save()
                    Logger.info("Null UUID migration: patched \(patched) of \(entities.count) records", subsystem: .app)
                }
                UserDefaults.standard.set(true, forKey: migrationKey)
            } catch {
                Logger.error("Null UUID migration failed: \(error)", subsystem: .app)
            }
        }
    }

    /// One-time migration to recalculate wordCount for all existing records
    /// using the corrected algorithm (components by whitespace+newlines).
    /// Old code used split(separator: " ") which could produce different counts.
    private func migrateWordCountsIfNeeded() {
        let migrationKey = "wordCountMigrationV1Done"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        guard let container = persistentContainer else { return }

        let context = container.newBackgroundContext()
        context.perform {
            let request: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
            do {
                let entities = try context.fetch(request)
                var updated = 0
                for entity in entities {
                    let correctCount = Int32(entity.transcription
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .count)
                    if entity.wordCount != correctCount {
                        entity.wordCount = correctCount
                        updated += 1
                    }
                }
                if context.hasChanges {
                    try context.save()
                    Logger.info("Word count migration: updated \(updated) of \(entities.count) records", subsystem: .app)
                }
                UserDefaults.standard.set(true, forKey: migrationKey)
            } catch {
                Logger.error("Word count migration failed: \(error)", subsystem: .app)
            }
        }
    }
}

enum HistoryDatabaseError: Error {
    case modelNotFound
    case storeLoadFailed
}

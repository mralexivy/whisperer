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

    lazy var persistentContainer: NSPersistentContainer? = {
        // Find the model in the app bundle
        guard let modelURL = Bundle.main.url(forResource: "WhispererHistory", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            Logger.error("Unable to find Core Data model - history will be unavailable", subsystem: .app)
            initializationError = HistoryDatabaseError.modelNotFound
            return nil
        }

        let container = NSPersistentContainer(name: "WhispererHistory", managedObjectModel: model)

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

    func saveContext() {
        guard let container = persistentContainer else { return }
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                Logger.error("Failed to save context: \(error.localizedDescription)", subsystem: .app)
            }
        }
    }

    private init() {
        // Load persistent container
        _ = persistentContainer
    }
}

enum HistoryDatabaseError: Error {
    case modelNotFound
    case storeLoadFailed
}

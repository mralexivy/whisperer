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

    lazy var persistentContainer: NSPersistentContainer = {
        // Find the model in the app bundle
        guard let modelURL = Bundle.main.url(forResource: "WhispererHistory", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Unable to find Core Data model")
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
        return persistentContainer.viewContext
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        return persistentContainer.newBackgroundContext()
    }

    func saveContext() {
        let context = viewContext
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

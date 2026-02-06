//
//  HistoryManager.swift
//  Whisperer
//
//  Singleton for managing transcription history CRUD operations
//

import Foundation
import CoreData
import Combine

@MainActor
class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published var transcriptions: [TranscriptionRecord] = []
    @Published var statistics: HistoryStatistics?

    private let database = HistoryDatabase.shared
    private var context: NSManagedObjectContext {
        database.viewContext
    }

    private init() {
        Task {
            await loadTranscriptions()
            await updateStatistics()
        }
    }

    // MARK: - Create

    func saveTranscription(_ record: TranscriptionRecord) async throws {
        let context = database.newBackgroundContext()

        await context.perform {
            _ = TranscriptionEntity.create(
                in: context,
                transcription: record.transcription,
                audioFileURL: record.audioFileURL,
                duration: record.duration,
                language: record.language,
                modelUsed: record.modelUsed
            )

            do {
                try context.save()
            } catch {
                Logger.error("Failed to save transcription: \(error)", subsystem: .app)
            }
        }

        await loadTranscriptions()
        await updateStatistics()
    }

    // MARK: - Read

    func loadTranscriptions(filter: TranscriptionFilter = .all, searchQuery: String? = nil) async {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        // Apply filter
        var predicates: [NSPredicate] = []

        switch filter {
        case .all:
            break
        case .pinned:
            predicates.append(NSPredicate(format: "isPinned == YES"))
        case .flagged:
            predicates.append(NSPredicate(format: "isFlagged == YES"))
        }

        // Apply search
        if let query = searchQuery, !query.isEmpty {
            predicates.append(NSPredicate(format: "transcription CONTAINS[cd] %@ OR editedTranscription CONTAINS[cd] %@ OR notes CONTAINS[cd] %@", query, query, query))
        }

        if !predicates.isEmpty {
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        fetchRequest.fetchLimit = 500

        do {
            let entities = try context.fetch(fetchRequest)
            transcriptions = entities.map { TranscriptionRecord(from: $0) }
        } catch {
            Logger.error("Failed to load transcriptions: \(error)", subsystem: .app)
        }
    }

    // MARK: - Update

    func updateTranscription(_ record: TranscriptionRecord) async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw HistoryError.recordNotFound
        }

        entity.isPinned = record.isPinned
        entity.isFlagged = record.isFlagged
        entity.editedTranscription = record.editedTranscription
        entity.notes = record.notes
        entity.lastModifiedAt = Date()

        try context.save()
        await loadTranscriptions()
    }

    func togglePin(_ record: TranscriptionRecord) async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw HistoryError.recordNotFound
        }

        entity.isPinned.toggle()
        entity.lastModifiedAt = Date()

        try context.save()
        await loadTranscriptions()
    }

    func toggleFlag(_ record: TranscriptionRecord) async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw HistoryError.recordNotFound
        }

        entity.isFlagged.toggle()
        entity.lastModifiedAt = Date()

        try context.save()
        await loadTranscriptions()
    }

    func editTranscription(_ record: TranscriptionRecord, newText: String) async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw HistoryError.recordNotFound
        }

        entity.editedTranscription = newText
        entity.lastModifiedAt = Date()

        try context.save()
        await loadTranscriptions()
    }

    func updateNotes(_ record: TranscriptionRecord, notes: String?) async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw HistoryError.recordNotFound
        }

        entity.notes = notes
        entity.lastModifiedAt = Date()

        try context.save()
        await loadTranscriptions()
    }

    // MARK: - Delete

    func deleteTranscription(_ record: TranscriptionRecord) async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw HistoryError.recordNotFound
        }

        context.delete(entity)
        try context.save()

        await loadTranscriptions()
        await updateStatistics()
    }

    func deleteAllTranscriptions() async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()

        do {
            let allEntities = try context.fetch(fetchRequest)

            for entity in allEntities {
                // Optionally delete associated audio files
                if let audioFileURL = entity.audioFileURL {
                    let fileManager = FileManager.default
                    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")
                    let audioURL = recordingsDir.appendingPathComponent(audioFileURL)

                    try? fileManager.removeItem(at: audioURL)
                }

                context.delete(entity)
            }

            try context.save()

            await loadTranscriptions()
            await updateStatistics()
        } catch {
            Logger.error("Failed to delete all transcriptions: \(error)", subsystem: .app)
            throw error
        }
    }

    // MARK: - Statistics

    private func updateStatistics() async {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()

        do {
            let allEntities = try context.fetch(fetchRequest)

            let totalRecordings = allEntities.count
            let totalWords = allEntities.reduce(0) { $0 + Int($1.wordCount) }
            let totalDuration = allEntities.reduce(0.0) { $0 + $1.duration }

            let uniqueDays = Set(allEntities.map { Calendar.current.startOfDay(for: $0.timestamp) }).count

            let avgWPM = totalDuration > 0 ? Int(Double(totalWords) / (totalDuration / 60.0)) : 0

            statistics = HistoryStatistics(
                totalRecordings: totalRecordings,
                totalDays: uniqueDays,
                totalWords: totalWords,
                totalDuration: totalDuration,
                averageWPM: avgWPM
            )
        } catch {
            Logger.error("Failed to calculate statistics: \(error)", subsystem: .app)
        }
    }
}

// MARK: - Supporting Types

enum TranscriptionFilter {
    case all
    case pinned
    case flagged
}

struct HistoryStatistics {
    let totalRecordings: Int
    let totalDays: Int
    let totalWords: Int
    let totalDuration: TimeInterval
    let averageWPM: Int
}

enum HistoryError: Error {
    case databaseNotInitialized
    case recordNotFound
}

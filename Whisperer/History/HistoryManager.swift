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
    @Published private(set) var hasMorePages: Bool = true
    @Published private(set) var isLoadingPage: Bool = false

    private let pageSize = 50
    private var currentOffset = 0
    private var currentFilter: TranscriptionFilter = .all
    private var currentSearchQuery: String?
    private var currentDateRange: (start: Date, end: Date)?
    private var loadGeneration: Int = 0

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
                modelUsed: record.modelUsed,
                corrections: record.corrections,
                targetAppName: record.targetAppName
            )

            do {
                try context.save()
            } catch {
                Logger.error("Failed to save transcription: \(error)", subsystem: .app)
            }
        }

        await loadTranscriptions(filter: currentFilter, searchQuery: currentSearchQuery, dateRange: currentDateRange)
        await updateStatistics()

        NotificationCenter.default.post(name: NSNotification.Name("TranscriptionSaved"), object: nil)
    }

    // MARK: - Read

    /// Resets pagination and loads the first page. Called on filter/search/date changes.
    func loadTranscriptions(filter: TranscriptionFilter = .all, searchQuery: String? = nil, dateRange: (start: Date, end: Date)? = nil) async {
        // Increment generation to invalidate any in-flight sentinel loads
        loadGeneration += 1
        currentFilter = filter
        currentSearchQuery = searchQuery
        currentDateRange = dateRange
        currentOffset = 0
        hasMorePages = true
        isLoadingPage = false
        transcriptions = []

        await fetchNextPage()
    }

    /// Loads the next page of results and appends to existing transcriptions.
    func loadNextPage() async {
        await fetchNextPage()
    }

    private func fetchNextPage() async {
        guard !isLoadingPage, hasMorePages else { return }
        isLoadingPage = true
        let generation = loadGeneration

        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]

        var predicates: [NSPredicate] = []

        switch currentFilter {
        case .all:
            break
        case .pinned:
            predicates.append(NSPredicate(format: "isPinned == YES"))
        case .flagged:
            predicates.append(NSPredicate(format: "isFlagged == YES"))
        }

        if let query = currentSearchQuery, !query.isEmpty {
            predicates.append(NSPredicate(format: "transcription CONTAINS[cd] %@ OR editedTranscription CONTAINS[cd] %@ OR notes CONTAINS[cd] %@", query, query, query))
        }

        if let range = currentDateRange {
            predicates.append(NSPredicate(format: "timestamp >= %@", range.start as NSDate))
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: range.end) ?? range.end
            predicates.append(NSPredicate(format: "timestamp < %@", endOfDay as NSDate))
        }

        if !predicates.isEmpty {
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        fetchRequest.fetchOffset = currentOffset
        fetchRequest.fetchLimit = pageSize

        do {
            let entities = try context.fetch(fetchRequest)

            // Discard results if a newer loadTranscriptions invalidated this fetch
            guard generation == loadGeneration else {
                isLoadingPage = false
                return
            }

            let newRecords = entities.map { TranscriptionRecord(from: $0) }

            transcriptions.append(contentsOf: newRecords)
            currentOffset += newRecords.count
            hasMorePages = newRecords.count == pageSize
        } catch {
            Logger.error("Failed to load transcriptions page: \(error)", subsystem: .app)
        }

        isLoadingPage = false
    }

    /// Returns the set of dates (start of day) that have at least one transcription.
    func fetchDatesWithTranscriptions() async -> Set<Date> {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.propertiesToFetch = ["timestamp"]

        do {
            let entities = try context.fetch(fetchRequest)
            return Set(entities.map { Calendar.current.startOfDay(for: $0.timestamp) })
        } catch {
            Logger.error("Failed to fetch transcription dates: \(error)", subsystem: .app)
            return []
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

        if let index = transcriptions.firstIndex(where: { $0.id == record.id }) {
            transcriptions[index] = TranscriptionRecord(from: entity)
        }
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

        if currentFilter == .pinned, !entity.isPinned {
            transcriptions.removeAll { $0.id == record.id }
            currentOffset = max(0, currentOffset - 1)
        } else if let index = transcriptions.firstIndex(where: { $0.id == record.id }) {
            transcriptions[index] = TranscriptionRecord(from: entity)
        }
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

        if currentFilter == .flagged, !entity.isFlagged {
            transcriptions.removeAll { $0.id == record.id }
            currentOffset = max(0, currentOffset - 1)
        } else if let index = transcriptions.firstIndex(where: { $0.id == record.id }) {
            transcriptions[index] = TranscriptionRecord(from: entity)
        }
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

        if let index = transcriptions.firstIndex(where: { $0.id == record.id }) {
            transcriptions[index] = TranscriptionRecord(from: entity)
        }
    }

    func retranscribe(_ record: TranscriptionRecord, newText: String, language: String, modelUsed: String) async throws {
        let fetchRequest: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", record.id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let entity = try context.fetch(fetchRequest).first else {
            throw HistoryError.recordNotFound
        }

        entity.editedTranscription = newText
        entity.language = language
        entity.modelUsed = modelUsed
        entity.lastModifiedAt = Date()

        try context.save()

        if let index = transcriptions.firstIndex(where: { $0.id == record.id }) {
            transcriptions[index] = TranscriptionRecord(from: entity)
        }
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

        if let index = transcriptions.firstIndex(where: { $0.id == record.id }) {
            transcriptions[index] = TranscriptionRecord(from: entity)
        }
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

        transcriptions.removeAll { $0.id == record.id }
        currentOffset = max(0, currentOffset - 1)
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

            await loadTranscriptions(filter: currentFilter, searchQuery: currentSearchQuery, dateRange: currentDateRange)
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

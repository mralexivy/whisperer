//
//  TranscriptionEntity.swift
//  Whisperer
//
//  Core Data entity for transcriptions
//

import Foundation
import CoreData

@objc(TranscriptionEntity)
public class TranscriptionEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var timestamp: Date
    @NSManaged public var transcription: String
    @NSManaged public var audioFileURL: String?
    @NSManaged public var duration: Double
    @NSManaged public var wordCount: Int32
    @NSManaged public var language: String
    @NSManaged public var modelUsed: String
    @NSManaged public var isPinned: Bool
    @NSManaged public var isFlagged: Bool
    @NSManaged public var editedTranscription: String?
    @NSManaged public var notes: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var lastModifiedAt: Date
    @NSManaged public var correctionsData: Data?

    // Computed properties
    var displayText: String {
        editedTranscription ?? transcription
    }

    var wordsPerMinute: Int {
        guard duration > 0 else { return 0 }
        return Int(Double(wordCount) / (duration / 60.0))
    }

    var audioURL: URL? {
        guard let audioFileURL = audioFileURL else { return nil }
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")
        return recordingsDir.appendingPathComponent(audioFileURL)
    }

    var corrections: [AppliedCorrection] {
        get {
            guard let data = correctionsData else { return [] }
            do {
                return try JSONDecoder().decode([AppliedCorrection].self, from: data)
            } catch {
                Logger.error("Failed to decode corrections: \(error)", subsystem: .app)
                return []
            }
        }
        set {
            do {
                correctionsData = try JSONEncoder().encode(newValue)
            } catch {
                Logger.error("Failed to encode corrections: \(error)", subsystem: .app)
            }
        }
    }
}

extension TranscriptionEntity: Identifiable {}

// MARK: - Fetch Request

extension TranscriptionEntity {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TranscriptionEntity> {
        return NSFetchRequest<TranscriptionEntity>(entityName: "TranscriptionEntity")
    }
}

// MARK: - Convenience Initializer

extension TranscriptionEntity {
    static func create(in context: NSManagedObjectContext, transcription: String, audioFileURL: String?, duration: Double, language: String, modelUsed: String, corrections: [AppliedCorrection] = []) -> TranscriptionEntity {
        let entity = TranscriptionEntity(context: context)
        let now = Date()

        entity.id = UUID()
        entity.timestamp = now
        entity.transcription = transcription
        entity.audioFileURL = audioFileURL
        entity.duration = duration
        entity.wordCount = Int32(transcription.split(separator: " ").count)
        entity.language = language
        entity.modelUsed = modelUsed
        entity.isPinned = false
        entity.isFlagged = false
        entity.editedTranscription = nil
        entity.notes = nil
        entity.createdAt = now
        entity.lastModifiedAt = now
        entity.corrections = corrections

        return entity
    }
}

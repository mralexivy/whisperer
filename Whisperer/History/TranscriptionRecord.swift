//
//  TranscriptionRecord.swift
//  Whisperer
//
//  SwiftUI-friendly wrapper for TranscriptionEntity
//

import Foundation

struct TranscriptionRecord: Identifiable {
    let id: UUID
    let timestamp: Date
    let transcription: String
    let audioFileURL: String?
    let duration: Double
    let wordCount: Int
    let language: String
    let modelUsed: String
    let isPinned: Bool
    let isFlagged: Bool
    let editedTranscription: String?
    let notes: String?
    let createdAt: Date
    let lastModifiedAt: Date
    let corrections: [AppliedCorrection]
    let targetAppName: String?
    let aiEnhancedText: String?
    let aiModeName: String?

    // Computed properties
    var displayText: String {
        editedTranscription ?? aiEnhancedText ?? transcription
    }

    var hasAIEnhancement: Bool {
        aiEnhancedText != nil
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

    // Initialize from Core Data entity
    init(from entity: TranscriptionEntity) {
        self.id = entity.id
        self.timestamp = entity.timestamp
        self.transcription = entity.transcription
        self.audioFileURL = entity.audioFileURL
        self.duration = entity.duration
        self.wordCount = Int(entity.wordCount)
        self.language = entity.language
        self.modelUsed = entity.modelUsed
        self.isPinned = entity.isPinned
        self.isFlagged = entity.isFlagged
        self.editedTranscription = entity.editedTranscription
        self.notes = entity.notes
        self.createdAt = entity.createdAt
        self.lastModifiedAt = entity.lastModifiedAt
        self.corrections = entity.corrections
        self.targetAppName = entity.targetAppName
        self.aiEnhancedText = entity.aiEnhancedText
        self.aiModeName = entity.aiModeName
    }

    // For creating new records
    init(id: UUID = UUID(), transcription: String, audioFileURL: String?, duration: Double, language: String, modelUsed: String, corrections: [AppliedCorrection] = [], targetAppName: String? = nil, aiEnhancedText: String? = nil, aiModeName: String? = nil) {
        let now = Date()
        self.id = id
        self.timestamp = now
        self.transcription = transcription
        self.audioFileURL = audioFileURL
        self.duration = duration
        self.wordCount = transcription.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        self.language = language
        self.modelUsed = modelUsed
        self.isPinned = false
        self.isFlagged = false
        self.editedTranscription = nil
        self.notes = nil
        self.createdAt = now
        self.lastModifiedAt = now
        self.corrections = corrections
        self.targetAppName = targetAppName
        self.aiEnhancedText = aiEnhancedText
        self.aiModeName = aiModeName
    }
}

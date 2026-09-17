//
//  TranscriptionRecord.swift
//  Whisperer
//
//  SwiftUI-friendly wrapper for TranscriptionEntity
//

import CoreData
import Foundation

struct TranscriptionRecord: Identifiable {
    let id: UUID
    let timestamp: Date
    let transcription: String
    /// `var` because library compaction rewrites the recording to Opus under a new name and
    /// patches the loaded page in place rather than forcing a full reload.
    var audioFileURL: String?
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
    let targetAppBundleID: String?
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

    /// The archived audio for this record, or nil when there is none on disk.
    ///
    /// The existence check is the honest answer to rows damaged before 2026-09-17, which name a
    /// file that was never written (or has since been reaped). Returning a URL for a missing file
    /// gave the user a play button that failed with CoreAudio 2003334207 and a Re-transcribe that
    /// did nothing. This is the single choke point for both consumers in `TranscriptionDetailView`.
    var audioURL: URL? {
        guard let audioFileURL = audioFileURL else { return nil }
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")
        let url = recordingsDir.appendingPathComponent(audioFileURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// True when the record claims audio that is no longer on disk — the UI explains this rather
    /// than silently showing no player at all.
    var audioIsMissing: Bool {
        audioFileURL != nil && audioURL == nil
    }

    // Initialize from Core Data entity
    init(from entity: TranscriptionEntity) {
        // Safe KVC casting guards against nil in non-optional @NSManaged fields —
        // old rows written before a column was added have NULL in SQLite, which
        // EXC_BAD_ACCESSes when Swift tries to bridge nil ObjC to a non-optional.
        let now = Date()
        self.id = entity.value(forKey: "id") as? UUID ?? UUID()
        self.timestamp = entity.value(forKey: "timestamp") as? Date ?? now
        self.transcription = entity.value(forKey: "transcription") as? String ?? ""
        self.audioFileURL = entity.audioFileURL
        self.duration = entity.duration
        self.wordCount = Int(entity.wordCount)
        self.language = entity.value(forKey: "language") as? String ?? "en"
        self.modelUsed = entity.value(forKey: "modelUsed") as? String ?? ""
        self.isPinned = entity.isPinned
        self.isFlagged = entity.isFlagged
        self.editedTranscription = entity.editedTranscription
        self.notes = entity.notes
        self.createdAt = entity.value(forKey: "createdAt") as? Date ?? now
        self.lastModifiedAt = entity.value(forKey: "lastModifiedAt") as? Date ?? now
        self.corrections = entity.corrections
        self.targetAppBundleID = entity.value(forKey: "targetAppBundleID") as? String
        self.targetAppName = entity.targetAppName
        self.aiEnhancedText = entity.aiEnhancedText
        self.aiModeName = entity.aiModeName
    }

    // For creating new records
    init(id: UUID = UUID(), transcription: String, audioFileURL: String?, duration: Double, language: String, modelUsed: String, corrections: [AppliedCorrection] = [], targetAppName: String? = nil, targetAppBundleID: String? = nil, aiEnhancedText: String? = nil, aiModeName: String? = nil) {
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
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.aiEnhancedText = aiEnhancedText
        self.aiModeName = aiModeName
    }
}

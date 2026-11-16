//
//  TranscriptDocument.swift
//  Whisperer
//
//  What the unified Recordings workspace reads: one recording — a dictation, a meeting or an
//  imported file — as ordered paragraphs with optional speakers and times. It is a *view* over the
//  two stores (`TranscriptionEntity`, `MeetingEntity`); nothing here is persisted or copied.
//
//  Identity is namespaced by store (`RecordingID`) and derived from the persisted row, so it is
//  stable across fetches, sorts and renders. The recording kind is separate: a file and a dictation
//  both live in the transcription store.
//

import CryptoKit
import Foundation

// MARK: - Identity

nonisolated enum RecordingKind: String, Codable, CaseIterable, Sendable {
    case dictation, meeting, file

    var label: String {
        switch self {
        case .dictation: return "Dictation"
        case .meeting: return "Meeting"
        case .file: return "File"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "mic.fill"
        case .meeting: return "video.fill"
        case .file: return "doc.text.fill"
        }
    }
}

nonisolated enum RecordingStoreKind: String, Sendable {
    case transcription, meeting
}

nonisolated struct RecordingID: Hashable, Sendable, Identifiable {
    let store: RecordingStoreKind
    let uuid: UUID

    var id: String { key }
    var key: String { "\(store.rawValue):\(uuid.uuidString)" }

    static func dictation(_ uuid: UUID) -> RecordingID { RecordingID(store: .transcription, uuid: uuid) }
    static func meeting(_ uuid: UUID) -> RecordingID { RecordingID(store: .meeting, uuid: uuid) }
}

extension UUID {
    /// A UUID derived from a string, the same every time. Gives synthetic paragraphs identities that
    /// do not change between renders or launches.
    nonisolated static func deterministic(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Paragraph

nonisolated struct TranscriptParagraph: Identifiable, Equatable, Sendable {
    /// Meetings: the segment's own id. Dictation and files: `<recording uuid>-p<index>`.
    let id: String
    var text: String
    var start: Double?
    var end: Double?
    var speakerName: String?
    var speakerIndex: Int?
    var tags: [SegmentTag] = []
    /// The meeting segment this paragraph is, when there is one.
    var sourceSegmentID: UUID?
}

/// The paragraph structure an import writes next to its text, so a reopened file keeps the times.
nonisolated struct StoredParagraph: Codable, Equatable, Sendable {
    var text: String
    var start: Double?
    var end: Double?
}

// MARK: - Document

nonisolated struct TranscriptDocument: Identifiable, Equatable, Sendable {
    let id: RecordingID
    var kind: RecordingKind
    var title: String
    var titleIsUserSet: Bool
    var createdAt: Date
    var duration: Double
    var language: String
    var model: String
    var audioFileName: String?
    /// Nil when there is no audio or it is no longer on disk.
    var audioURL: URL?
    var audioIsMissing: Bool
    /// What the reader shows by default (edited / polished text where there is one).
    var paragraphs: [TranscriptParagraph]
    /// The recognizer's own text, when the shown version differs from it.
    var originalParagraphs: [TranscriptParagraph]?
    /// Name of the enhancement behind the shown version ("Fast Polish", a mode, "AI polish").
    var enhancementName: String?
    var summary: MeetingAISummary?
    var participants: [MeetingParticipant]
    /// The destination app (dictation), the file name (import) or the call app (meeting).
    var sourceName: String?
    var sourceBundleID: String?
    var isPinned: Bool
    var isFlagged: Bool
    var isInProgress: Bool
    var captureFailed: Bool
    /// Notes the dictation/import carries as plain text. Preserved even though dictation has no Notes tab.
    var legacyNotes: String?
    var correctionCount: Int
    var wordCount: Int
    /// Changes whenever the shown text does, so a late AI result can tell it was written for old text.
    var revision: Int

    var hasTiming: Bool { paragraphs.contains { $0.start != nil } }
    var hasSpeakers: Bool { paragraphs.contains { !($0.speakerName ?? "").isEmpty } }
    var hasOriginalVersion: Bool { originalParagraphs != nil }
    var fullText: String { paragraphs.map(\.text).joined(separator: "\n\n") }
    var wordsPerMinute: Int { duration > 0 ? Int(Double(wordCount) / (duration / 60)) : 0 }
    var speakerNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for name in paragraphs.compactMap(\.speakerName) where !name.isEmpty && seen.insert(name).inserted { out.append(name) }
        return out
    }

    // MARK: Citation keys

    /// The number an AI cites a paragraph by (`[Ns]`). Real start times when every paragraph has
    /// one; otherwise an ordinal at 60-second spacing, so untimed text never claims to have a time
    /// and neighbouring paragraphs can never be confused.
    var citationKeys: [Double] {
        let timed = !paragraphs.isEmpty && paragraphs.allSatisfy { $0.start != nil }
        return paragraphs.enumerated().map { timed ? $0.element.start ?? 0 : Double($0.offset) * 60 }
    }

    /// The paragraph an AI citation key refers to.
    func paragraph(forCitationKey key: Double) -> TranscriptParagraph? {
        let keys = citationKeys
        guard !keys.isEmpty else { return nil }
        var best = 0
        for index in keys.indices where abs(keys[index] - key) < abs(keys[best] - key) { best = index }
        return paragraphs[best]
    }

    // MARK: Bridge to the existing AI services

    /// The paragraphs as meeting segments — what `MeetingAIService`, the polisher and the overview
    /// already consume. Ids are the paragraph ids for meetings and deterministic for the rest.
    var segments: [MeetingSegment] {
        let keys = citationKeys
        return paragraphs.enumerated().map { index, paragraph in
            let start = keys[index]
            let end = index + 1 < keys.count ? keys[index + 1] : start + 60
            return MeetingSegment(
                id: paragraph.sourceSegmentID ?? UUID.deterministic("\(id.key)-\(paragraph.id)"),
                timestamp: start,
                endTimestamp: max(start, paragraph.end ?? end),
                text: paragraph.text,
                speakerName: paragraph.speakerName ?? "Speaker",
                speakerIndex: paragraph.speakerIndex ?? 0,
                tags: paragraph.tags,
                rawText: rawText(at: index),
                language: nil)
        }
    }

    /// What the recognizer wrote, for a paragraph the AI polish rewrote — what `TranscriptPolishBar` reads to
    /// know there is something to undo. Fast Polish is not an AI polish, so it does not count.
    private func rawText(at index: Int) -> String? {
        guard let original = originalParagraphs, original.count == paragraphs.count,
              kind == .meeting || enhancementName == HistoryManager.aiPolishModeName else { return nil }
        return original[index].text
    }

    /// A `MeetingRecord` carrying this document, for the views that were written against one
    /// (Overview, Ask AI). Not persisted.
    func asMeetingRecord() -> MeetingRecord {
        var record = MeetingRecord(
            id: id.uuid, title: title, createdAt: createdAt, duration: duration, audioFileURL: audioFileName,
            segments: segments, notes: [], aiSummary: summary, wordCount: wordCount, language: language,
            modelUsed: model, isInProgress: false)
        record.titleIsUserSet = titleIsUserSet
        record.sourceBundleID = sourceBundleID
        record.sourceAppName = sourceName
        record.participants = participants
        record.isPinned = isPinned
        record.isFlagged = isFlagged
        return record
    }

    // MARK: Export

    func exportText(includeTimes: Bool = true) -> String {
        var lines = [title, "\(kind.label) · \(createdAt.formatted(date: .long, time: .shortened))"]
        if duration > 0 { lines.append("Duration: \(FileTranscriptClock.format(duration))") }
        lines.append("")
        for paragraph in paragraphs {
            var head: [String] = []
            if let name = paragraph.speakerName, !name.isEmpty { head.append(name) }
            if includeTimes, let start = paragraph.start { head.append("[\(FileTranscriptClock.format(start))]") }
            if !head.isEmpty { lines.append(head.joined(separator: " ")) }
            lines.append(paragraph.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Adapters

extension TranscriptDocument {

    /// The one place the legacy "File Import" convention is understood.
    nonisolated static func kind(of record: TranscriptionRecord) -> RecordingKind {
        if record.sourceKind == "file" || record.targetAppName == "File Import" { return .file }
        return .dictation
    }

    /// A short title for a dictation, which has none stored: its first words.
    /// The rest of a dictation after the words its derived title already shows, so a row does not say the same thing twice.
    nonisolated static func previewAfterTitle(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 8 else { return "" }
        return words.dropFirst(8).joined(separator: " ")
    }

    nonisolated static func derivedTitle(from text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        guard !flat.isEmpty else { return "Untitled recording" }
        let trimmed = flat.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…"))
        return trimmed.count < flat.count || text.split(whereSeparator: \.isWhitespace).count <= 8 ? trimmed : trimmed + "…"
    }

    // MARK: Meeting

    init(meeting record: MeetingRecord) {
        let paragraphs = record.segments.map { segment in
            TranscriptParagraph(
                id: segment.id.uuidString, text: segment.text, start: segment.timestamp, end: segment.endTimestamp,
                speakerName: segment.speakerName.isEmpty ? nil : segment.speakerName, speakerIndex: segment.speakerIndex,
                tags: segment.tags, sourceSegmentID: segment.id)
        }
        let original: [TranscriptParagraph]? = record.segments.contains { $0.rawText != nil }
            ? zip(paragraphs, record.segments).map { paragraph, segment in
                var copy = paragraph
                copy.text = segment.rawText ?? segment.text
                return copy
            } : nil
        self.init(
            id: .meeting(record.id), kind: .meeting, title: record.title, titleIsUserSet: record.titleIsUserSet,
            createdAt: record.createdAt, duration: record.duration, language: record.language, model: record.modelUsed,
            audioFileName: record.audioFileURL, audioURL: record.resolvedAudioURL.flatMap(Self.existing),
            audioIsMissing: record.audioFileURL != nil && record.resolvedAudioURL.flatMap(Self.existing) == nil,
            paragraphs: paragraphs, originalParagraphs: original, enhancementName: original == nil ? nil : "AI polish",
            summary: record.aiSummary, participants: record.participants, sourceName: record.sourceAppName,
            sourceBundleID: record.sourceBundleID, isPinned: record.isPinned, isFlagged: record.isFlagged,
            isInProgress: record.isInProgress, captureFailed: record.captureFailed, legacyNotes: nil,
            correctionCount: 0, wordCount: record.wordCount,
            revision: Self.revision(of: paragraphs, extra: record.title))
    }

    // MARK: Dictation / imported file

    init(transcription record: TranscriptionRecord) {
        let kind = Self.kind(of: record)
        let uuid = record.id
        let original = record.editedTranscription ?? record.transcription
        // A polish made with the shared AI polish wins over an earlier edit (it was made on the edited text);
        // otherwise the legacy precedence stands: an edit beats an enhancement.
        let polishWins = record.aiModeName == HistoryManager.aiPolishModeName
        let shown = polishWins ? (record.aiEnhancedText ?? original) : (record.editedTranscription ?? record.aiEnhancedText ?? record.transcription)
        let stored = record.paragraphsJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([StoredParagraph].self, from: $0) }

        let originalParagraphs = Self.paragraphs(fromText: original, stored: stored, uuid: uuid)
        let isEnhanced = record.aiEnhancedText != nil && (polishWins || record.editedTranscription == nil)
        let shownParagraphs = isEnhanced
            ? Self.paragraphs(fromText: shown, stored: nil, uuid: uuid, alignedTo: originalParagraphs)
            : originalParagraphs

        let audio = record.audioURL
        let derived = Self.derivedTitle(from: shown)
        self.init(
            id: .dictation(uuid), kind: kind, title: record.title ?? (kind == .file ? Self.fileTitle(record) ?? derived : derived),
            titleIsUserSet: record.title != nil, createdAt: record.timestamp, duration: record.duration,
            language: record.language, model: record.modelUsed, audioFileName: record.audioFileURL, audioURL: audio,
            audioIsMissing: record.audioIsMissing, paragraphs: shownParagraphs,
            originalParagraphs: isEnhanced ? originalParagraphs : nil, enhancementName: isEnhanced ? record.aiModeName : nil,
            summary: record.aiSummaryJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(MeetingAISummary.self, from: $0) },
            participants: [], sourceName: kind == .file ? (record.sourceFileName ?? "File import") : record.targetAppName,
            sourceBundleID: record.targetAppBundleID, isPinned: record.isPinned, isFlagged: record.isFlagged,
            isInProgress: false, captureFailed: false, legacyNotes: record.notes, correctionCount: record.corrections.count,
            wordCount: record.wordCount, revision: Self.revision(of: shownParagraphs, extra: record.title ?? ""))
    }

    private static func fileTitle(_ record: TranscriptionRecord) -> String? {
        guard let name = record.sourceFileName, !name.isEmpty else { return nil }
        return (name as NSString).deletingPathExtension
    }

    /// Paragraphs from flat text. Stored import paragraphs keep their times when the text is still
    /// the import's; a polished version keeps them when it has one block per original paragraph.
    private static func paragraphs(fromText text: String, stored: [StoredParagraph]?, uuid: UUID,
                                   alignedTo original: [TranscriptParagraph]? = nil) -> [TranscriptParagraph] {
        func make(_ index: Int, _ text: String, _ start: Double?, _ end: Double?) -> TranscriptParagraph {
            TranscriptParagraph(id: "\(uuid.uuidString)-p\(index)", text: text, start: start, end: end)
        }
        if let stored, !stored.isEmpty,
           stored.map(\.text).joined(separator: " ").filter({ !$0.isWhitespace }) == text.filter({ !$0.isWhitespace }) {
            return stored.enumerated().map { make($0.offset, $0.element.text, $0.element.start, $0.element.end) }
        }
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let original, blocks.count == original.count, blocks.count > 1 {
            return zip(blocks, original).enumerated().map { make($0.offset, $0.element.0, $0.element.1.start, $0.element.1.end) }
        }
        if blocks.count > 1 { return blocks.enumerated().map { make($0.offset, $0.element, nil, nil) } }
        let split = FileTranscriptParagraphs.split(text)
        if split.isEmpty { return text.isEmpty ? [] : [make(0, text, nil, nil)] }
        return split.enumerated().map { make($0.offset, $0.element.text, nil, nil) }
    }

    nonisolated private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated private static func revision(of paragraphs: [TranscriptParagraph], extra: String) -> Int {
        var hasher = Hasher()
        hasher.combine(extra)
        for paragraph in paragraphs { hasher.combine(paragraph.id); hasher.combine(paragraph.text) }
        return hasher.finalize()
    }
}

extension RecordingKind {
    /// The thin line icons the list uses.
    var outlineIcon: String {
        switch self {
        case .dictation: return "mic"
        case .meeting: return "video"
        case .file: return "doc.text"
        }
    }
}

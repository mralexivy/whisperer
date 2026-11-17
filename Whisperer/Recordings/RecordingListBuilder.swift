//
//  RecordingListBuilder.swift
//  Whisperer
//
//  Merges the two stores' already-paged lists into the one Recordings list. Pure, so every edge case of
//  paging is testable without a database.
//
//  Paging is the subtle part. Each store pages newest-first on its own, so right after the first page of
//  each the merged list could contain a meeting older than the oldest dictation that has been *loaded* —
//  while dictations between the two are still unloaded. Showing it would make rows pop into the middle of
//  the list when the next page arrives. Instead the list ends at the **cutoff**: the newer of the two
//  stores' oldest loaded dates, for the stores that still have more to load. Anything older waits.
//

import Foundation
import SwiftUI

nonisolated enum RecordingKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", dictation = "Dictation", meetings = "Meetings", files = "Files"
    var id: String { rawValue }

    func includes(_ kind: RecordingKind) -> Bool {
        switch self {
        case .all: return true
        case .dictation: return kind == .dictation
        case .meetings: return kind == .meeting
        case .files: return kind == .file
        }
    }

    /// Whether the history store (dictation and imports) can contribute at all.
    var usesHistoryStore: Bool { self != .meetings }
    var usesMeetingStore: Bool { self == .all || self == .meetings }
}

nonisolated enum RecordingMarkFilter: String, CaseIterable, Sendable { case none, pinned, flagged }

nonisolated enum RecordingStoreSource: Sendable { case history, meetings }

nonisolated enum RecordingListBuilder {

    struct Inputs {
        var transcriptions: [TranscriptionRecord]
        var meetings: [MeetingListItem]
        var historyHasMore: Bool
        var meetingsHaveMore: Bool
        var kind: RecordingKindFilter = .all
        var mark: RecordingMarkFilter = .none
        /// Meeting ids matching the current search; nil when there is no search.
        /// Meetings matching the current search (id → the passage that matched); nil when there is no search.
        var meetingHits: [UUID: String?]? = nil
        /// The search text, so a dictation row can show the passage that matched.
        var query: String? = nil
    }

    struct Output: Equatable {
        var items: [RecordingListItem]
        /// Rows older than this are held back until the store that defines it loads more.
        var cutoff: Date?
        /// The store whose next page lowers the cutoff.
        var limiting: RecordingStoreSource?
    }

    static func build(_ input: Inputs) -> Output {
        var merged: [RecordingListItem] = []
        var seen = Set<RecordingID>()

        if input.kind.usesHistoryStore {
            for record in input.transcriptions {
                let kind = TranscriptDocument.kind(of: record)
                guard input.kind.includes(kind) else { continue }
                let text = record.editedTranscription ?? record.aiEnhancedText ?? record.transcription
                let item = RecordingListItem(
                    id: .dictation(record.id), kind: kind,
                    title: record.title ?? TranscriptDocument.derivedTitle(from: text),
                    preview: Self.preview(text: text, title: record.title, query: input.query),
                    date: record.timestamp, duration: record.duration, isPinned: record.isPinned, isFlagged: record.isFlagged,
                    isInProgress: false, sourceName: kind == .file ? record.sourceFileName : record.targetAppName,
                    sourceBundleID: record.targetAppBundleID)
                if seen.insert(item.id).inserted { merged.append(item) }
            }
        }

        if input.kind.usesMeetingStore {
            for meeting in input.meetings {
                if let hits = input.meetingHits, hits[meeting.id] == nil { continue }
                switch input.mark {
                case .pinned where !meeting.isPinned: continue
                case .flagged where !meeting.isFlagged: continue
                default: break
                }
                let item = RecordingListItem(
                    id: .meeting(meeting.id), kind: .meeting, title: meeting.title,
                    preview: (input.meetingHits?[meeting.id] ?? nil) ?? (meeting.captureFailed ? "No audio was captured" : "\(meeting.wordCount) words"),
                    date: meeting.createdAt, duration: meeting.duration, isPinned: meeting.isPinned, isFlagged: meeting.isFlagged,
                    isInProgress: meeting.isInProgress, sourceName: meeting.sourceAppName, sourceBundleID: meeting.sourceBundleID)
                if seen.insert(item.id).inserted { merged.append(item) }
            }
        }

        // The cutoff: the newer of the oldest loaded dates of the stores that still have pages to give.
        let historyOldest = input.kind.usesHistoryStore && input.historyHasMore ? input.transcriptions.map(\.timestamp).min() : nil
        let meetingOldest = input.kind.usesMeetingStore && input.meetingsHaveMore ? input.meetings.map(\.createdAt).min() : nil
        var cutoff: Date?
        var limiting: RecordingStoreSource?
        switch (historyOldest, meetingOldest) {
        case let (h?, m?): (cutoff, limiting) = h >= m ? (h, .history) : (m, .meetings)
        case let (h?, nil): (cutoff, limiting) = (h, .history)
        case let (nil, m?): (cutoff, limiting) = (m, .meetings)
        case (nil, nil): break
        }
        // A pinned or flagged row is always shown: the filter fetched exactly those, so there is no gap.
        if let cutoff, input.mark == .none {
            merged = merged.filter { $0.date >= cutoff }
        }

        // Strictly newest first; equal dates keep one order between rebuilds.
        merged.sort { $0.date != $1.date ? $0.date > $1.date : $0.id.key < $1.id.key }
        return Output(items: merged, cutoff: cutoff, limiting: limiting)
    }
}

/// Finding and showing where a search matched. Pure.
nonisolated enum RecordingSnippet {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func contains(_ text: String, _ query: String) -> Bool {
        !query.isEmpty && text.range(of: query, options: options) != nil
    }

    /// The query as it appears inside JSON: `/`, `"` and `\` are escaped there, so a transcript saying "TCP/IP" is
    /// stored as `TCP\/IP`.
    static func jsonSpellings(of query: String) -> [String] {
        var escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "/", with: "\\/")
        return escaped == query ? [query] : [query, escaped]
    }

    /// A short passage with the match in the middle: "… the quarterly budget is approved by …".
    static func around(_ query: String, in text: String, radius: Int = 46) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let range = flat.range(of: query, options: options) else { return String(flat.prefix(radius * 2)) }
        let lower = flat.distance(from: flat.startIndex, to: range.lowerBound)
        let upper = flat.distance(from: flat.startIndex, to: range.upperBound)
        let startOffset = max(0, lower - radius), endOffset = min(flat.count, upper + radius)
        var piece = String(flat[flat.index(flat.startIndex, offsetBy: startOffset)..<flat.index(flat.startIndex, offsetBy: endOffset)])
        piece = piece.trimmingCharacters(in: .whitespaces)
        return (startOffset > 0 ? "…" : "") + piece + (endOffset < flat.count ? "…" : "")
    }

    /// `text` as an attributed string with every match of `query` marked.
    static func highlighted(_ text: String, query: String?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let query, !query.isEmpty else { return attributed }
        var from = text.startIndex
        while let range = text.range(of: query, options: options, range: from..<text.endIndex),
              let target = Range(range, in: attributed) {
            attributed[target].backgroundColor = Color.yellow.opacity(0.35)
            attributed[target].foregroundColor = .white
            from = range.upperBound
        }
        return attributed
    }
}

extension RecordingListBuilder {
    /// A dictation's second line: the passage that matched the search when there is one, otherwise the rest of
    /// the text after the words its derived title already shows.
    static func preview(text: String, title: String?, query: String?) -> String {
        if let query, !query.isEmpty, RecordingSnippet.contains(text, query) {
            return RecordingSnippet.around(query, in: text)
        }
        let rest = title == nil ? TranscriptDocument.previewAfterTitle(text) : text
        return String(rest.prefix(140)).replacingOccurrences(of: "\n", with: " ")
    }
}

extension RecordingKindFilter {
    /// The kind a tab stands for (nil for All).
    var kind: RecordingKind? {
        switch self {
        case .all: return nil
        case .meetings: return .meeting
        case .dictation: return .dictation
        case .files: return .file
        }
    }
}

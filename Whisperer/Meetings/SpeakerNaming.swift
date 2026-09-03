//
//  SpeakerNaming.swift
//  Whisperer
//
//  Shared helpers for speaker name uniqueness validation and index-keyed mutation.
//  All callers (MeetingManager, MeetingDetailViewModel, MeetingSession, UI) route
//  through here so the comparison rule and array mutation cannot drift apart.
//
//

import Foundation

// MARK: - SpeakerNaming

enum SpeakerNaming {

    /// Trimmed, case- and diacritic-insensitive fold used for all duplicate checks.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Returns the *display* name of the speaker already using `candidate` if one exists,
    /// or nil when the name is free.
    ///
    /// - Parameters:
    ///   - candidate: The proposed new name (trimmed before comparison).
    ///   - roster:    All (speakerIndex, speakerName) pairs for the meeting.
    ///   - excluding: The speakerIndex being renamed — its own current name is never a conflict.
    static func conflictingName(for candidate: String,
                                in roster: [(index: Int, name: String)],
                                excluding index: Int) -> String? {
        let fold = normalized(candidate)
        guard !fold.isEmpty else { return nil }
        return roster.first { $0.index != index && normalized($0.name) == fold }?.name
    }

    /// Indices of speakers that share a normalized name with at least one other speaker.
    /// Used to flag legacy data that already contains duplicates.
    static func duplicateIndices(in roster: [(index: Int, name: String)]) -> Set<Int> {
        var seen: [String: Int] = [:]   // normalized name → first speakerIndex
        var dupes: Set<Int> = []
        for (idx, name) in roster {
            let key = normalized(name)
            if let prior = seen[key] {
                dupes.insert(prior)
                dupes.insert(idx)
            } else {
                seen[key] = idx
            }
        }
        return dupes
    }
}

// MARK: - Array<MeetingSegment> helpers

extension Array where Element == MeetingSegment {

    /// Renames every segment belonging to `speakerIndex` to `name`.
    mutating func renameSpeaker(index speakerIndex: Int, to name: String) {
        for i in self.indices where self[i].speakerIndex == speakerIndex {
            self[i].speakerName = name
        }
    }
}

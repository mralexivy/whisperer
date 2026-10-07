//
//  MeetingTranscriptAccumulator.swift
//  Whisperer
//
//  Guarantees the monotonic, accumulated text that `MeetingSpeakerCoordinator` requires.
//
//  ### Why this exists
//  `MeetingSpeakerCoordinator.ingestAccumulated` takes the **full transcript so far**, diffs it
//  against what it has already attributed, and emits the new words. Hand it anything shorter
//  than what it has already emitted and it rejects the input as a delta — which is correct
//  defensive behaviour, and also means a caller that gets the contract wrong silently stops
//  attributing text. That is not hypothetical: feeding whisper.cpp's per-commit deltas into this
//  path blanked a Hebrew meeting's live tail roughly 148 times in one 4.5-minute session
//  (2026-09-07).
//
//  Nemotron satisfies the contract natively — its partial callback *is* the growing transcript.
//  Qwen3 does not: its preview is a window-local tail and its chunk callback is a delta. What
//  Qwen3 does have is `StreamingTranscriber.onTranscription`, which publishes committed text plus
//  the current preview tail — accumulated by construction, but not guaranteed monotonic, because
//  the preview tail can shrink when a chunk commits and the next preview pass has not run yet.
//
//  This type closes that last gap. It is the only thing between `onTranscription` and the
//  coordinator, it is pure, and it is unit-tested — so the contract is enforced by a type rather
//  than by every call site remembering it.
//

import Foundation

/// Filters a stream of accumulated-transcript snapshots down to the monotonically growing ones.
///
/// Not thread-safe by design. Callers drive it from one place — the main actor, in
/// `AppState.startInAppRecording()` — and making it an actor would add an await to a callback
/// that already hops.
struct MeetingTranscriptAccumulator {

    /// The last snapshot passed on to the coordinator.
    private(set) var published: String = ""

    /// Snapshots dropped because they were not an extension of `published`. Surfaced so a run
    /// that silently stops growing is visible in the logs rather than merely absent.
    private(set) var rejectedCount: Int = 0

    init() {}

    /// Returns the snapshot to forward, or `nil` when this one must be withheld.
    ///
    /// Forwards only when `snapshot` extends what was already published. Two cases are dropped:
    ///
    /// - **A shrink.** The preview tail retracted between passes. The coordinator has already
    ///   attributed those words and cannot un-attribute them, so the shorter text is stale.
    /// - **A divergence.** The snapshot is longer but its word prefix disagrees with what was
    ///   published, meaning the decoder rewrote history. The coordinator's floor
    ///   (`emittedWordCount`) would reject it anyway; dropping it here keeps the rejection out
    ///   of the error log and off the attribution path.
    ///
    /// Equal input is dropped too: re-publishing an unchanged transcript costs a diff and a
    /// `livePreviewText` write per audio buffer for no new words.
    mutating func accept(_ snapshot: String) -> String? {
        let trimmed = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != published else { return nil }

        let newWords = Self.words(trimmed)
        let oldWords = Self.words(published)

        guard newWords.count > oldWords.count else {
            rejectedCount += 1
            return nil
        }
        guard Array(newWords.prefix(oldWords.count)) == oldWords else {
            rejectedCount += 1
            return nil
        }

        published = trimmed
        return trimmed
    }

    /// Clears state between recordings. A new session starts from an empty transcript, and a
    /// carried-over `published` would make the first snapshot of the next meeting look like a
    /// shrink and be dropped for the whole session.
    mutating func reset() {
        published = ""
        rejectedCount = 0
    }

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}

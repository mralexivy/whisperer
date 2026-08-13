//
//  MeetingRefineWindow.swift
//  Whisperer
//
//  Groups transcript cards into ~30s audio windows for the re-transcription pass,
//  and maps whisper's timed output back onto the cards it came from.
//
//  Pure value logic — no I/O, no actor isolation.
//

import Foundation

struct MeetingRefineWindow {
    /// Indices into the segment array this window covers, in order. Never empty.
    let segmentIndices: [Int]
    /// Audio span in seconds from meeting start.
    let start: Double
    let end: Double

    var duration: Double { max(0, end - start) }
}

extension MeetingRefineWindow {

    // MARK: - Planning

    /// Group consecutive segments into windows of at most `maxDuration` seconds of audio.
    ///
    /// 30s is whisper's training window: it is both the cheapest shape (one encoder run per
    /// 30s of audio rather than one per card) and the one whisper is most accurate on. Slicing
    /// per card would hand the model 2–5s fragments, which it pads to 30s and frequently
    /// hallucinates into.
    ///
    /// A card is never split across windows — the mapping step needs whole cards to assign
    /// text back to. A single card longer than `maxDuration` becomes its own window.
    static func plan(_ segments: [MeetingSegment], maxDuration: Double = 30.0) -> [MeetingRefineWindow] {
        var windows: [MeetingRefineWindow] = []
        var current: [Int] = []
        var start = 0.0
        var end = 0.0

        for (index, segment) in segments.enumerated() {
            // Cards are written on the audio clock, but a malformed span would otherwise
            // produce a window that runs backwards.
            let segStart = max(0, segment.timestamp)
            let segEnd = max(segStart, segment.endTimestamp)

            if current.isEmpty {
                current = [index]
                start = segStart
                end = segEnd
                continue
            }

            if segEnd - start <= maxDuration {
                current.append(index)
                end = max(end, segEnd)
            } else {
                windows.append(MeetingRefineWindow(segmentIndices: current, start: start, end: end))
                current = [index]
                start = segStart
                end = segEnd
            }
        }

        if !current.isEmpty {
            windows.append(MeetingRefineWindow(segmentIndices: current, start: start, end: end))
        }
        return windows
    }

    // MARK: - Mapping

    /// Assign whisper's timed segments to the cards they overlap.
    ///
    /// `timed` spans must already be shifted to absolute meeting time by the caller (whisper
    /// reports relative to the buffer it was handed, which starts before `window.start` when
    /// a lead-in was prepended).
    ///
    /// Each timed segment goes to the single card it overlaps most, ties to the earlier card,
    /// so text is never duplicated across cards. A timed segment overlapping nothing is
    /// attached to the nearest card in the window rather than dropped — whisper's boundaries
    /// drift by a few hundred ms and losing a sentence is worse than placing it one card off.
    /// Cards that receive nothing are absent from the result and keep their existing text.
    static func assign(_ timed: [WhisperTimedSegment], to window: MeetingRefineWindow,
                       in segments: [MeetingSegment]) -> [Int: String] {
        guard !window.segmentIndices.isEmpty else { return [:] }

        var pieces: [Int: [String]] = [:]

        for piece in timed {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            var bestIndex: Int?
            var bestOverlap = 0.0
            var nearestIndex = window.segmentIndices[0]
            var nearestDistance = Double.greatestFiniteMagnitude

            for index in window.segmentIndices {
                let segment = segments[index]
                let segStart = max(0, segment.timestamp)
                let segEnd = max(segStart, segment.endTimestamp)

                let overlap = min(piece.end, segEnd) - max(piece.start, segStart)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = index
                }

                let distance = piece.start < segStart ? segStart - piece.end : piece.start - segEnd
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = index
                }
            }

            pieces[bestIndex ?? nearestIndex, default: []].append(text)
        }

        return pieces.mapValues { $0.joined(separator: " ") }
    }
}

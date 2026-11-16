//
//  FileTranscriptClock.swift
//  Whisperer
//
//  m:ss / h:mm:ss for playback positions and paragraph times.
//

import Foundation

nonisolated enum FileTranscriptClock {
    /// `m:ss`, or `h:mm:ss` from an hour up.
    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

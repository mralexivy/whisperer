//
//  SessionStorage.swift
//  Whisperer
//
//  Session audio file URL management and window reads for long-record pipeline.
//

import Foundation
import AVFoundation

enum SessionStorage {

    // MARK: - URL Management

    /// Returns a URL for a new session audio file under ~/Library/Application Support/Whisperer/Sessions/
    static func makeSessionAudioURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sessionsDir = appSupport.appendingPathComponent("Whisperer/Sessions")

        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        return sessionsDir.appendingPathComponent("\(UUID().uuidString).caf")
    }

    // MARK: - Reading

    /// Read a window of Float32 samples from a 16 kHz mono Int16 CAF session file.
    /// - Parameters:
    ///   - url: Session CAF file written by AudioRecorder
    ///   - startSample: Absolute sample index to start reading from (0 = file start)
    ///   - endSample: Absolute sample index to stop at (exclusive); pass Int.max for end of file
    /// - Returns: Float32 samples in [-1.0, 1.0], or empty on any error.
    static func readFloat32Window(from url: URL, startSample: Int, endSample: Int) -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let file = try AVAudioFile(forReading: url)
            let fileLength = Int(file.length)
            guard fileLength > 0 else { return [] }

            let start = max(0, startSample)
            let end = min(fileLength, endSample == Int.max ? fileLength : endSample)
            guard start < end else { return [] }

            let count = end - start
            file.framePosition = AVAudioFramePosition(start)

            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                return []
            }

            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            guard let channelData = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        } catch {
            Logger.error("SessionStorage.readFloat32Window failed: \(error.localizedDescription)", subsystem: .audio)
            return []
        }
    }

    // MARK: - Cleanup

    /// Delete a session file, ignoring errors.
    static func deleteSessionFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete all session files older than the given age. Call on launch to clean up orphans
    /// that were recovered (or recording was never completed).
    static func deleteOrphanedSessions(olderThan age: TimeInterval = 7 * 24 * 3600) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sessionsDir = appSupport.appendingPathComponent("Whisperer/Sessions")
        guard let items = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for item in items where item.pathExtension == "caf" {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            if created < cutoff {
                try? fm.removeItem(at: item)
                Logger.debug("Deleted orphaned session file: \(item.lastPathComponent)", subsystem: .audio)
            }
        }
    }
}

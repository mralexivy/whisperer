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

        return sessionsDir.appendingPathComponent("\(UUID().uuidString).\(AudioArchiveFormat.fileExtension)")
    }

    // MARK: - Reading

    /// Read a window of 16 kHz mono Float32 samples from a session or archived audio file.
    ///
    /// Sample indices are in **whisper's 16 kHz clock**, not the file's own rate — callers
    /// derive them from an audio-time span, and the file's rate is an encoding detail.
    /// An Ogg Opus file reports 48 kHz through `AVAudioFile` no matter what rate it was
    /// encoded at, so both the seek and the conversion have to be rate-relative.
    ///
    /// - Parameters:
    ///   - url: Any readable audio file — current `.opus`, or a legacy `.caf` / `.wav`
    ///   - startSample: Absolute 16 kHz sample index to start from (0 = file start)
    ///   - endSample: Absolute 16 kHz sample index to stop at (exclusive); `Int.max` = end of file
    /// - Returns: Float32 samples in [-1.0, 1.0], or empty on any error.
    static func readFloat32Window(from url: URL, startSample: Int, endSample: Int) -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let file = try AVAudioFile(forReading: url)
            let fileFormat = file.processingFormat
            let fileRate = fileFormat.sampleRate
            let fileLength = Int(file.length)
            guard fileLength > 0, fileRate > 0 else { return [] }

            let scale = fileRate / AudioArchiveFormat.sampleRate
            let fileStart = min(fileLength, Int((Double(max(0, startSample)) * scale).rounded()))
            let fileEnd = endSample == Int.max
                ? fileLength
                : min(fileLength, Int((Double(endSample) * scale).rounded()))
            guard fileStart < fileEnd else { return [] }

            let windowFrames = AVAudioFrameCount(fileEnd - fileStart)
            file.framePosition = AVAudioFramePosition(fileStart)

            // Fast path: the file is already exactly what whisper wants (legacy `.wav`).
            if fileRate == AudioArchiveFormat.sampleRate,
               fileFormat.channelCount == AudioArchiveFormat.channels,
               fileFormat.commonFormat == .pcmFormatFloat32 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: windowFrames) else { return [] }
                try file.read(into: buffer, frameCount: windowFrames)
                guard let channelData = buffer.floatChannelData else { return [] }
                return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            }

            // `read(into:)` does **not** resample into a differently-formatted client buffer.
            // Measured: a 440 Hz tone in a 48 kHz file, read into a 16 kHz Float32 buffer,
            // comes back as 146 cycles per 16000 frames instead of 440 — raw 48 kHz frames
            // relabeled, not converted. The conversion has to be explicit.
            guard let converter = AVAudioConverter(from: fileFormat, to: AudioArchiveFormat.pcmFormat) else {
                Logger.error("No converter from \(fileFormat) for \(url.lastPathComponent)", subsystem: .audio)
                return []
            }

            let inputChunk: AVAudioFrameCount = 32_768
            let outputCapacity = AVAudioFrameCount(Double(inputChunk) / scale) + 1024
            var remaining = windowFrames
            var result = [Float]()
            result.reserveCapacity(Int(Double(windowFrames) / scale) + 1024)

            while true {
                guard let output = AVAudioPCMBuffer(pcmFormat: AudioArchiveFormat.pcmFormat,
                                                    frameCapacity: outputCapacity) else { break }

                var readError: Error?
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                    let want = min(inputChunk, remaining)
                    guard want > 0, let chunk = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: want) else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try file.read(into: chunk, frameCount: want)
                    } catch {
                        readError = error
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    guard chunk.frameLength > 0 else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    remaining -= chunk.frameLength
                    outStatus.pointee = .haveData
                    return chunk
                }

                if let readError { throw readError }

                if output.frameLength > 0, let channelData = output.floatChannelData {
                    result.append(contentsOf: UnsafeBufferPointer(start: channelData[0],
                                                                  count: Int(output.frameLength)))
                }

                if status == .error {
                    Logger.error("Window conversion failed: \(conversionError?.localizedDescription ?? "unknown")",
                                 subsystem: .audio)
                    break
                }
                // Anything but a full `.haveData` pull means the input is spent. A zero-length
                // `.haveData` would otherwise spin forever.
                if status != .haveData || output.frameLength == 0 { break }
            }

            return result
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

    /// Delete all session files older than the given age — leftovers from a recording that was
    /// never finalized, or whose archive copy already succeeded.
    ///
    /// Called by `AudioRetentionService`, which runs it *after* crash recovery has finished
    /// with the in-progress rows. Calling it before that races: a session interrupted 7+ days
    /// ago can have its audio unlinked while `loadInProgressSessions` is still finalizing the
    /// record that points at it.
    ///
    /// - Returns: how many files were removed and how many bytes that reclaimed.
    @discardableResult
    static func deleteOrphanedSessions(olderThan age: TimeInterval = 7 * 24 * 3600) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sessionsDir = appSupport.appendingPathComponent("Whisperer/Sessions")
        guard let items = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) else { return (0, 0) }

        let cutoff = Date().addingTimeInterval(-age)
        var count = 0
        var bytes: Int64 = 0
        for item in items where AudioArchiveFormat.isRecognizedAudio(item) {
            let values = try? item.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            let created = values?.creationDate ?? Date()
            guard created < cutoff else { continue }
            let size = values?.fileSize.map { Int64($0) } ?? 0
            guard (try? fm.removeItem(at: item)) != nil else { continue }
            count += 1
            bytes += size
            Logger.debug("Deleted orphaned session file: \(item.lastPathComponent)", subsystem: .audio)
        }
        return (count, bytes)
    }
}

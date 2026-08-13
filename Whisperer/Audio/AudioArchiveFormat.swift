//
//  AudioArchiveFormat.swift
//  Whisperer
//
//  The one audio format the app stores: Ogg Opus, 16 kHz mono, written live.
//

import Foundation
import AVFoundation
import SwiftOGG

enum AudioArchiveError: Error, LocalizedError {
    case cannotCreateFile(URL)
    case unsupportedSource(URL)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let url): return "Could not create audio file at \(url.lastPathComponent)"
        case .unsupportedSource(let url): return "Could not read audio from \(url.lastPathComponent)"
        case .conversionFailed(let reason): return "Audio conversion failed: \(reason)"
        }
    }
}

/// Single source of truth for the on-disk audio format. Everything the app writes —
/// live sessions, dictation archives, meeting audio, imported files — goes through here.
enum AudioArchiveFormat {

    // MARK: - Format

    static let fileExtension = "opus"
    static let sampleRate: Double = 16_000
    static let channels: AVAudioChannelCount = 1

    /// No bitrate constant on purpose: `OGGEncoder` keeps its `opus_encoder` handle private,
    /// so `opus_encoder_ctl` / `OPUS_SET_BITRATE` are unreachable. libopus's own default for
    /// 16 kHz mono VoIP measures ~19 kbps (8.3 MB/hour), which is what we want anyway.
    /// The only lever available is `OGGEncoder.Application` (`.voip` vs `.audio`).

    /// The format the capture path produces and every reader wants back.
    static let pcmFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: channels, interleaved: false)!

    // MARK: - Writing

    static func makeWriter(at url: URL) throws -> AudioArchiveWriter {
        try AudioArchiveWriter(url: url)
    }

    // MARK: - Classification

    private static let recognizedExtensions: Set<String> = [
        "opus", "ogg", "oga", "caf", "wav", "wave", "m4a", "mp4", "mp3",
        "aac", "flac", "aif", "aiff", "aifc"
    ]

    /// True for anything the app may have written or imported, current or legacy.
    /// Cleanup and migration use this so pre-Opus files are still seen.
    static func isRecognizedAudio(_ url: URL) -> Bool {
        recognizedExtensions.contains(url.pathExtension.lowercased())
    }

    /// True if the file is already in the archive format — a string compare, because
    /// Ogg gets its own extension (an Opus-in-CAF scheme would have needed a format probe).
    static func isAlreadyArchived(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Replace a URL's extension with the archive one, preserving the rest of the name.
    static func archiveURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    // MARK: - Transcoding

    /// Convert any readable audio file to a 16 kHz mono `.opus`.
    ///
    /// Streams in fixed chunks — a 60-minute import must never be materialized as one
    /// `AVAudioPCMBuffer`. Used by the import path and by library migration.
    static func transcode(from source: URL, to destination: URL) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw AudioArchiveError.unsupportedSource(source)
        }

        let inputFormat = input.processingFormat
        guard input.length > 0 else { throw AudioArchiveError.unsupportedSource(source) }

        let writer = try AudioArchiveWriter(url: destination)
        var succeeded = false
        defer {
            writer.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        let chunkFrames: AVAudioFrameCount = 32_768

        // Already 16 kHz mono Float32 (a session file re-read, say) — no converter needed.
        if inputFormat.sampleRate == sampleRate,
           inputFormat.channelCount == channels,
           inputFormat.commonFormat == .pcmFormatFloat32 {
            while true {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames) else {
                    throw AudioArchiveError.conversionFailed("buffer allocation failed")
                }
                try input.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                try writer.write(buffer)
            }
            succeeded = true
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
            throw AudioArchiveError.conversionFailed("no converter from \(inputFormat)")
        }

        let ratio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024

        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: outputCapacity) else {
                throw AudioArchiveError.conversionFailed("buffer allocation failed")
            }

            var readError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                guard let chunk = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: chunk, frameCount: chunkFrames)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard chunk.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return chunk
            }

            if let readError { throw readError }

            switch status {
            case .haveData, .inputRanDry:
                if output.frameLength > 0 { try writer.write(output) }
                if status == .inputRanDry { finished = true }
            case .endOfStream:
                if output.frameLength > 0 { try writer.write(output) }
                finished = true
            case .error:
                throw AudioArchiveError.conversionFailed(
                    conversionError?.localizedDescription ?? "unknown converter error")
            @unknown default:
                finished = true
            }
        }

        succeeded = true
    }
}

/// Incremental Ogg Opus writer.
///
/// Unlike `AVAudioFile` the encoder needs an explicit lifecycle, so this owns both the
/// encoder and the file handle. Pages are appended as libogg completes them (~one per
/// 1.7 s at this bitrate); `flush()` forces out whatever is already encoded.
///
/// **Not thread-safe by design** — every call site is already serialized (the recorder's
/// `sessionWriteQueue`, or a single transcode loop).
final class AudioArchiveWriter {

    private let url: URL
    private let encoder: OGGEncoder
    private let handle: FileHandle
    private var isClosed = false
    private var int16Scratch: [Int16] = []

    init(url: URL) throws {
        self.url = url

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AudioArchiveError.cannotCreateFile(url)
        }

        // pcmRate must equal opusRate — the library refuses to resample. pcmBytesPerFrame
        // is 2 because the encoder takes interleaved Int16.
        encoder = try OGGEncoder(
            pcmRate: Int32(AudioArchiveFormat.sampleRate),
            pcmChannels: Int32(AudioArchiveFormat.channels),
            pcmBytesPerFrame: 2,
            opusRate: Int32(AudioArchiveFormat.sampleRate),
            application: .voip
        )

        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw AudioArchiveError.cannotCreateFile(url)
        }

        // `init` already queued OpusHead + OpusTags — write them out.
        handle.write(encoder.bitstream(flush: true))
    }

    deinit {
        if !isClosed { try? handle.close() }
    }

    /// Encode one buffer of 16 kHz mono Float32. Partial Opus frames are cached inside the
    /// encoder, so buffer lengths need not align to the 20 ms frame.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard !isClosed else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let source = buffer.floatChannelData?[0] else { return }

        if int16Scratch.count < frames {
            int16Scratch = [Int16](repeating: 0, count: frames)
        }
        int16Scratch.withUnsafeMutableBufferPointer { out in
            for i in 0..<frames {
                let clamped = max(-1.0, min(1.0, source[i]))
                out[i] = Int16(clamped * 32767.0)
            }
        }

        let pcm = int16Scratch.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: frames * MemoryLayout<Int16>.size)
        }
        try encoder.encode(pcm: pcm)
        handle.write(encoder.bitstream(flush: false))
    }

    /// Force out every completed packet. Called periodically during long recordings so a
    /// crash costs the flush interval rather than a whole page.
    func flush() {
        guard !isClosed else { return }
        handle.write(encoder.bitstream(flush: true))
    }

    /// Final flush and close. `OGGEncoder.endstream()` is `internal`, so the last packet
    /// carries no `e_o_s` — verified harmless: the file reopens and plays regardless.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        handle.write(encoder.bitstream(flush: true))
        try? handle.close()
    }
}

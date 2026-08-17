//
//  SessionAudioWriteTests.swift
//  WhispererTests
//
//  Regression guard for the session-audio write path.
//
//  Commit e8adf20 ("Compact logs: ~25K lines/day → target <400") — a logging change — reverted
//  the Ogg Opus session writer in `AudioRecorder` to an older `AVAudioFile` + Int16-CAF
//  implementation. `SessionStorage.makeSessionAudioURL()` returns a `.opus` path, and
//  `AVAudioFile(forWriting:settings:)` infers its container from the path extension, so the
//  open failed on *every* recording. A `try?` swallowed the reason, leaving only
//  `rec.fail fail=session_file` in the log. Result: no session audio on disk for a day and a
//  half while history rows kept recording a `sessionAudioURL` pointing at a file that was
//  never created — meeting playback silently had nothing to play, and `HistoryTestLoader`
//  quietly skipped every affected row, shrinking the fixture corpus.
//
//  These tests pin the contract that broke: the URL the app writes sessions to must be
//  writable by the writer the app actually uses, and the bytes must read back.
//

import XCTest
import AVFoundation
@testable import whisperer

final class SessionAudioWriteTests: XCTestCase {

    // MARK: - Helpers

    /// 16 kHz mono Float32 sine, the format the capture callback delivers.
    private func makeBuffer(seconds: Double, frequency: Double = 440) -> AVAudioPCMBuffer {
        let rate = AudioArchiveFormat.sampleRate
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: AudioArchiveFormat.pcmFormat,
                                      frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = Float(sin(2 * Double.pi * frequency * Double(i) / rate) * 0.5)
        }
        return buffer
    }

    private func removeIfPresent(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - The regression

    /// The exact contract e8adf20 broke: a session URL must be openable by the archive writer.
    func testSessionURLIsWritableByArchiveWriter() throws {
        let url = SessionStorage.makeSessionAudioURL()
        defer { removeIfPresent(url) }

        XCTAssertEqual(url.pathExtension, "opus",
                       "Session audio is stored in the archive format; a change here must be "
                       + "matched in AudioRecorder's writer.")

        let writer = try AudioArchiveFormat.makeWriter(at: url)
        try writer.write(makeBuffer(seconds: 1.0))
        writer.close()

        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "Writer produced an empty session file")
    }

    /// Why `AVAudioFile` is not an option here. Pinning this stops a future "simplification"
    /// from reintroducing the same failure — the bug was not a typo, it was someone reasonably
    /// assuming AVAudioFile could write the session path.
    func testAVAudioFileCannotWriteTheSessionURL() {
        let url = SessionStorage.makeSessionAudioURL()
        defer { removeIfPresent(url) }

        let lpcmSettings = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true)!.settings
        XCTAssertThrowsError(try AVAudioFile(forWriting: url, settings: lpcmSettings),
                             "AVAudioFile cannot write LPCM into a .opus container. If this ever "
                             + "stops throwing, revisit AudioRecorder's writer choice — but note "
                             + "the failure it caused was silent because of a `try?`.")
    }

    /// Written audio must be readable back through the same path meeting playback and
    /// `HistoryTestLoader` use. A file that exists but decodes to nothing is the same outage.
    func testWrittenSessionAudioReadsBack() throws {
        let url = SessionStorage.makeSessionAudioURL()
        defer { removeIfPresent(url) }

        let writer = try AudioArchiveFormat.makeWriter(at: url)
        for _ in 0..<10 { try writer.write(makeBuffer(seconds: 0.2)) }  // 2.0s total
        writer.close()

        let samples = SessionStorage.readFloat32Window(from: url, startSample: 0,
                                                       endSample: Int.max)
        XCTAssertFalse(samples.isEmpty, "Session audio decoded to zero samples")

        // Opus is lossy and pads, so assert duration within a tolerance rather than exactly.
        let seconds = Double(samples.count) / AudioArchiveFormat.sampleRate
        XCTAssertEqual(seconds, 2.0, accuracy: 0.25,
                       "Decoded \(String(format: "%.2f", seconds))s from 2.0s of input")

        // And that it is signal, not silence — a zero-filled decode would pass a length check.
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        XCTAssertGreaterThan(rms, 0.05, "Decoded audio is silent (rms \(rms))")
    }

    /// Buffer lengths from the capture callback do not align to Opus's 20 ms frame. The encoder
    /// caches partial frames, and `close()` writes the terminating page — a writer that is only
    /// dropped, never closed, truncates the tail.
    func testUnalignedBuffersAndCloseFinalizeTheStream() throws {
        let url = SessionStorage.makeSessionAudioURL()
        defer { removeIfPresent(url) }

        let writer = try AudioArchiveFormat.makeWriter(at: url)
        for seconds in [0.017, 0.043, 0.101, 0.007, 0.232] {  // deliberately unaligned
            try writer.write(makeBuffer(seconds: seconds))
        }
        writer.close()
        writer.close()  // must be idempotent — discard paths can close twice

        let samples = SessionStorage.readFloat32Window(from: url, startSample: 0,
                                                       endSample: Int.max)
        XCTAssertFalse(samples.isEmpty, "Unaligned writes produced an undecodable file")
    }

    /// A writer that is dropped without `close()` must still finalize. `deinit` used to only
    /// close the file descriptor, skipping the terminating `bitstream(flush: true)` — so every
    /// path that forgot to close (three in `recoverAudioEngine` alone) silently truncated the
    /// recording instead of failing loudly.
    func testDroppedWriterStillFinalizes() throws {
        let url = SessionStorage.makeSessionAudioURL()
        defer { removeIfPresent(url) }

        // Scoped so the writer deallocates without an explicit close().
        try autoreleasepool {
            let writer = try AudioArchiveFormat.makeWriter(at: url)
            for _ in 0..<10 { try writer.write(makeBuffer(seconds: 0.2)) }  // 2.0s
        }

        // Identical input, explicitly closed — the reference for what "not truncated" means.
        let closedURL = SessionStorage.makeSessionAudioURL()
        defer { removeIfPresent(closedURL) }
        let closedWriter = try AudioArchiveFormat.makeWriter(at: closedURL)
        for _ in 0..<10 { try closedWriter.write(makeBuffer(seconds: 0.2)) }
        closedWriter.close()

        let dropped = SessionStorage.readFloat32Window(from: url, startSample: 0,
                                                       endSample: Int.max).count
        let closed = SessionStorage.readFloat32Window(from: closedURL, startSample: 0,
                                                      endSample: Int.max).count
        XCTAssertEqual(dropped, closed,
                       "Dropped writer decoded \(dropped) samples vs \(closed) when closed "
                       + "explicitly — deinit is not finalizing the stream.")
    }

    /// `makeSessionAudioURL` is responsible for creating the Sessions directory. If it stops
    /// doing so the writer fails with `cannotCreateFile` and every recording loses its audio.
    func testSessionsDirectoryIsCreated() {
        let url = SessionStorage.makeSessionAudioURL()
        defer { removeIfPresent(url) }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path,
                                                    isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue,
                      "Sessions directory missing at \(url.deletingLastPathComponent().path)")
    }
}

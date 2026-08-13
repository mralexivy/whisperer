//
//  AudioLibraryCompactor.swift
//  Whisperer
//
//  Opt-in rewrite of pre-Opus library audio (`.wav` dictations, `.caf` meetings) into the
//  archive format.
//
//  ### Why opt-in and not automatic
//  Nothing is broken about the old files — every reader goes through `AVAudioFile` /
//  `AVAudioPlayer`, so a 2024 `.wav` plays and renders a waveform exactly as before. This
//  only reclaims disk, so it runs when the user asks and never behind their back.
//
//  ### The ordering that matters
//  Transcode to a temp file → verify it opens and its duration matches → commit the new
//  filename to CoreData → *only then* unlink the original. Any earlier unlink can leave a
//  library row with a dead play button, which is worse than the bytes it saved.
//

import Foundation
import AVFoundation
import Combine

/// What the audio library looks like right now.
struct AudioLibrarySurvey: Equatable, Sendable {
    /// Everything under `Recordings/` + `Meetings/` + `Sessions/`, including files no record
    /// refers to — this is the number the user sees in Finder.
    var totalBytes: Int64
    /// The referenced, non-Opus subset compaction would touch.
    var legacyBytes: Int64
    var legacyCount: Int
    /// What that subset should weigh afterwards.
    var estimatedBytes: Int64

    var estimatedSaving: Int64 { max(0, legacyBytes - estimatedBytes) }
}

@MainActor
final class AudioLibraryCompactor: ObservableObject {
    static let shared = AudioLibraryCompactor()

    @Published private(set) var survey: AudioLibrarySurvey?
    @Published private(set) var isSurveying = false
    @Published private(set) var isRunning = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    /// One-line outcome of the last run, shown under the row until the next one.
    @Published private(set) var lastResultMessage: String?

    private init() {}

    // MARK: - Survey

    func refreshSurvey() async {
        guard !isSurveying, !isRunning else { return }
        isSurveying = true
        defer { isSurveying = false }

        let candidates = await legacyCandidates().map { $0.url }

        survey = await Task.detached(priority: .utility) {
            var legacyBytes: Int64 = 0
            var estimated: Int64 = 0
            var count = 0

            for url in candidates {
                guard let size = AudioLibraryFiles.fileSize(url), size > 0 else { continue }
                // Opening the header also proves the file is readable, so the estimate and
                // the work list agree on what counts.
                guard let seconds = AudioLibraryFiles.durationSeconds(url) else { continue }
                legacyBytes += size
                estimated += Int64(seconds * AudioLibraryFiles.opusBytesPerSecond)
                count += 1
            }

            return AudioLibrarySurvey(
                totalBytes: AudioLibraryFiles.directoryBytes(),
                legacyBytes: legacyBytes,
                legacyCount: count,
                estimatedBytes: estimated
            )
        }.value
    }

    // MARK: - Compaction

    func compact() async {
        guard !isRunning else { return }

        if let blocker = AudioRetentionService.shared.currentBlocker {
            lastResultMessage = "Paused — \(blocker)"
            return
        }

        let work = await legacyCandidates()
        guard !work.isEmpty else {
            lastResultMessage = "Everything is already compact"
            await refreshSurvey()
            return
        }

        isRunning = true
        completed = 0
        total = work.count
        var converted = 0
        var skipped = 0
        var reclaimed: Int64 = 0

        for item in work {
            // Re-checked per file: a library of hour-long meetings takes a while, and the
            // user may start recording in the middle of it.
            guard AudioRetentionService.shared.currentBlocker == nil else { break }

            switch await convert(source: item.url, commit: item.commit) {
            case .converted(let bytes):
                converted += 1
                reclaimed += bytes
            case .skipped:
                skipped += 1
            }
            completed += 1
        }

        isRunning = false

        let stoppedEarly = completed < total
        var message = converted == 0
            ? "No files were compacted"
            : "Compacted \(converted) file\(converted == 1 ? "" : "s"), \(Self.format(reclaimed)) reclaimed"
        if skipped > 0 { message += " · \(skipped) skipped" }
        if stoppedEarly { message += " · stopped early" }
        lastResultMessage = message

        Logger.info(
            "Library compaction: \(converted) converted, \(skipped) skipped, "
            + "\(Self.format(reclaimed)) reclaimed"
            + (stoppedEarly ? " (stopped early — pipeline became busy)" : ""),
            subsystem: .audio
        )

        await refreshSurvey()
    }

    // MARK: - Work list

    /// One entry per record whose audio is not yet Opus, paired with the write that repoints
    /// that record. Bundling the commit here keeps the loop above from having to know which
    /// manager owns which file.
    private struct Candidate {
        let url: URL
        let commit: (String) async -> Bool
    }

    private func legacyCandidates() async -> [Candidate] {
        var result: [Candidate] = []

        for item in await HistoryManager.shared.legacyAudioRecordings() {
            guard let url = HistoryManager.absoluteRecordingURL(for: item.fileName) else { continue }
            result.append(Candidate(url: url) { name in
                await HistoryManager.shared.updateAudioFileName(id: item.id, fileName: name)
            })
        }

        for item in await MeetingManager.shared.legacyAudioMeetings() {
            let url = AudioLibraryFiles.meetingsDirectory.appendingPathComponent(item.fileName)
            result.append(Candidate(url: url) { name in
                await MeetingManager.shared.updateAudioFileName(meetingID: item.id, fileName: name)
            })
        }

        return result
    }

    // MARK: - One file

    private enum Outcome {
        case converted(reclaimed: Int64)
        case skipped
    }

    /// Transcode one file, verify it, hand the new bare filename to `commit`, and unlink the
    /// original only if that commit succeeded.
    private func convert(source: URL, commit: (String) async -> Bool) async -> Outcome {
        let originalBytes = AudioLibraryFiles.fileSize(source) ?? 0

        let produced: URL? = await Task.detached(priority: .utility) {
            AudioLibraryFiles.transcodeVerified(source: source)
        }.value

        guard let produced else { return .skipped }

        guard await commit(produced.lastPathComponent) else {
            // The row still names the original, which is still there — drop the new copy.
            try? FileManager.default.removeItem(at: produced)
            return .skipped
        }

        let newBytes = AudioLibraryFiles.fileSize(produced) ?? 0
        try? FileManager.default.removeItem(at: source)
        return .converted(reclaimed: max(0, originalBytes - newBytes))
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        AudioLibraryFiles.format(bytes)
    }
}

// MARK: - Filesystem work (no actor isolation — all of it runs off the main thread)

enum AudioLibraryFiles {

    /// Measured: libopus's default for 16 kHz mono VoIP lands at 8.3 MB/hour. Used only to
    /// show an estimate before the user commits — the real figure is reported after the run.
    static let opusBytesPerSecond: Double = 8.3 * 1024 * 1024 / 3600

    private static let audioDirectories = ["Recordings", "Meetings", "Sessions"]

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer")
    }

    static var meetingsDirectory: URL {
        appSupport.appendingPathComponent("Meetings")
    }

    /// Transcode `source` to a sibling `.opus`, returning it only once it has been verified.
    /// Returns nil — leaving the original untouched — on any failure.
    static func transcodeVerified(source: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        guard let expected = durationSeconds(source), expected > 0 else {
            Logger.warning("Compaction: cannot read \(source.lastPathComponent) — skipped", subsystem: .audio)
            return nil
        }

        // Write beside the original under a name nothing else can be holding, so a crash
        // mid-transcode leaves an obvious leftover rather than a half-written archive.
        let temp = source.deletingPathExtension()
            .appendingPathExtension("compacting")
            .appendingPathExtension(AudioArchiveFormat.fileExtension)
        try? FileManager.default.removeItem(at: temp)

        do {
            try AudioArchiveFormat.transcode(from: source, to: temp)
        } catch {
            Logger.warning(
                "Compaction: transcode failed for \(source.lastPathComponent): \(error.localizedDescription)",
                subsystem: .audio
            )
            try? FileManager.default.removeItem(at: temp)
            return nil
        }

        // Compare **seconds**, never frame counts: the source reports 16 kHz and Ogg Opus
        // always reports 48 kHz, so the frame numbers are legitimately 3× apart.
        guard let actual = durationSeconds(temp),
              abs(actual - expected) <= max(0.5, expected * 0.02) else {
            Logger.warning(
                "Compaction: \(source.lastPathComponent) failed the duration check — original kept",
                subsystem: .audio
            )
            try? FileManager.default.removeItem(at: temp)
            return nil
        }

        let final = uniqueArchiveURL(besides: source)
        do {
            try FileManager.default.moveItem(at: temp, to: final)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        return final
    }

    /// `<name>.opus`, or `<name>-1.opus` … if that name is taken — two rows can legitimately
    /// hold `note.wav` and `note.caf`.
    static func uniqueArchiveURL(besides source: URL) -> URL {
        let base = source.deletingPathExtension()
        var candidate = base.appendingPathExtension(AudioArchiveFormat.fileExtension)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(suffix)")
                .appendingPathExtension(AudioArchiveFormat.fileExtension)
            suffix += 1
        }
        return candidate
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
    }

    /// Duration in seconds from the file header — no decode. Rate-relative on purpose: an
    /// Ogg Opus file reports 48 kHz whatever it was encoded at.
    static func durationSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    static func directoryBytes() -> Int64 {
        var total: Int64 = 0
        for name in audioDirectories {
            let dir = appSupport.appendingPathComponent(name)
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for item in items where AudioArchiveFormat.isRecognizedAudio(item) {
                total += fileSize(item) ?? 0
            }
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

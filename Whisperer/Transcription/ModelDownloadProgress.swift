//
//  ModelDownloadProgress.swift
//  Whisperer
//
//  One record per model being fetched, so every screen shows the progress of *that* model.
//
//  Before this there was a single `AppState.downloadProgress` that every engine's downloader
//  wrote to. Two downloads at once (onboarding's Whisper plus a Qwen3 started from the menu, or
//  a meeting cleanup model) overwrote each other's percent, and a row for one model could show
//  another model's bar. Each engine also invented its own status string, and three of them put
//  `AppState.state` into `.downloadingModel`, which blocked dictation for the whole download.
//

import Foundation

/// A downloadable speech model, one case per thing a row in the Models tab can fetch.
nonisolated enum ModelAsset: Hashable {
    case whisper(WhisperModel)
    case parakeet(ParakeetModelVariant)
    case nemotron
    case nemotronHebrew
    case qwen3
    case whisperKit

    var displayName: String {
        switch self {
        case .whisper(let model): return model.displayName
        case .parakeet(let variant): return variant.displayName
        case .nemotron: return "Nemotron"
        case .nemotronHebrew: return "Nemotron Hebrew"
        case .qwen3: return "Qwen3 ASR"
        case .whisperKit: return "WhisperKit Turbo"
        }
    }

    /// Approximate size, for "x of y" before the server has reported a length and for downloaders
    /// (Hugging Face snapshots) that report only a fraction.
    var approximateBytes: Int64 {
        switch self {
        case .whisper(let model): return Int64(model.approximateDownloadBytes)
        case .parakeet: return 480_000_000
        case .nemotron: return 1_500_000_000
        case .nemotronHebrew: return 1_500_000_000
        case .qwen3: return 2_500_000_000
        case .whisperKit: return 646_000_000
        }
    }

    /// Stable id for click tests and accessibility identifiers.
    var testID: String {
        switch self {
        case .whisper(let model): return "whisper.\(model.rawValue)"
        case .parakeet(let variant): return "parakeet.\(variant.rawValue)"
        case .nemotron: return "nemotron"
        case .nemotronHebrew: return "nemotronHebrew"
        case .qwen3: return "qwen3"
        case .whisperKit: return "whisperKit"
        }
    }

    /// "547 MB", shown on a row before the download starts.
    var sizeLabel: String {
        if case .whisper(let model) = self { return model.sizeDescription }
        return ModelDownloadProgress.format(bytes: approximateBytes)
    }
}

/// Where a download is, beyond its fraction. Each phase has its own words in the UI so a stalled
/// bar is never the only thing the user sees.
nonisolated enum ModelDownloadPhase: Equatable {
    /// Started, no bytes yet.
    case connecting
    case downloading
    /// URLSession is holding the request until the network comes back.
    case waitingForNetwork
    /// A transfer failed and is being retried; carries the attempt about to run.
    case retrying(attempt: Int, of: Int)
    /// Bytes are in; the files are being moved, validated or compiled.
    case finishing
}

nonisolated struct ModelDownloadProgress: Equatable {
    var fraction: Double = 0
    var phase: ModelDownloadPhase = .connecting
    /// Known only for single-file downloads (whisper.cpp). Otherwise estimated from the fraction.
    var bytesWritten: Int64?
    var bytesExpected: Int64?
    let startedAt: Date
    /// Throughput measured over the recent window, bytes per second. nil until there is enough
    /// data to be honest about it.
    var bytesPerSecond: Double?

    /// Last sample used for the throughput estimate.
    fileprivate var sampleAt: Date
    fileprivate var sampleBytes: Int64 = 0

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.sampleAt = startedAt
    }

    /// Records a new reading. `fraction` is clamped and never goes backwards within one attempt —
    /// Hugging Face snapshots re-weight their total as file sizes arrive, and a bar that jumps
    /// back reads as a failure.
    mutating func update(fraction newFraction: Double, bytesWritten: Int64?, bytesExpected: Int64?,
                         approximateTotal: Int64, now: Date = Date()) {
        let clamped = newFraction.isFinite ? min(max(newFraction, 0), 1) : 0
        fraction = max(fraction, clamped)
        if let bytesWritten { self.bytesWritten = bytesWritten }
        if let bytesExpected, bytesExpected > 0 { self.bytesExpected = bytesExpected }
        if phase != .finishing { phase = fraction >= 1 ? .finishing : .downloading }

        let total = self.bytesExpected ?? approximateTotal
        let written = self.bytesWritten ?? Int64(Double(total) * fraction)
        let elapsed = now.timeIntervalSince(sampleAt)
        // Two-second window, exponentially smoothed so a single slow chunk does not swing the ETA.
        if elapsed >= 2 {
            let instant = Double(written - sampleBytes) / elapsed
            if instant >= 0 {
                bytesPerSecond = bytesPerSecond.map { $0 * 0.6 + instant * 0.4 } ?? instant
            }
            sampleAt = now
            sampleBytes = written
        }
    }

    /// Restarts the counters for a fresh attempt. The start time stays: the user waited through
    /// the failed attempt too.
    mutating func restart(phase newPhase: ModelDownloadPhase) {
        fraction = 0
        bytesWritten = nil
        bytesPerSecond = nil
        sampleBytes = 0
        sampleAt = Date()
        phase = newPhase
    }

    /// Seconds left at the current rate, or nil when the rate is not known yet.
    func secondsRemaining(approximateTotal: Int64) -> Double? {
        guard phase == .downloading, let rate = bytesPerSecond, rate > 1 else { return nil }
        let total = bytesExpected ?? approximateTotal
        let written = bytesWritten ?? Int64(Double(total) * fraction)
        return Double(max(total - written, 0)) / rate
    }

    /// "312 MB of 547 MB · about 1 min left", or the phase's own words.
    func detailText(approximateTotal: Int64) -> String {
        switch phase {
        case .connecting: return "Starting download…"
        case .waitingForNetwork: return "Waiting for network…"
        case .retrying(let attempt, let max): return "Connection dropped — retrying (\(attempt)/\(max))…"
        case .finishing: return "Finishing up…"
        case .downloading: break
        }
        let total = bytesExpected ?? approximateTotal
        let written = bytesWritten ?? Int64(Double(total) * fraction)
        // "Zero KB of 2.5 GB" reads as broken; until bytes land, say it is starting.
        guard written > 0 else { return "Starting download… \(Self.format(bytes: total))" }
        var text = "\(Self.format(bytes: written)) of \(Self.format(bytes: total))"
        if let remaining = secondsRemaining(approximateTotal: approximateTotal) {
            text += " · \(Self.format(remaining: remaining))"
        }
        return text
    }

    static func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB]
        return formatter.string(fromByteCount: bytes)
    }

    static func format(remaining seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = Double(minutes) / 60
        return String(format: "about %.1f h left", hours)
    }
}

/// Words for a failure the user can act on. Raw `URLError` descriptions ("The request timed
/// out.") say what broke, not what to do.
nonisolated enum ModelDownloadFailure {
    static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No internet connection. Retry when you're back online."
            case .timedOut:
                return "The download timed out. Check your connection and retry."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach the download server. Retry in a moment."
            default: break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteOutOfSpaceError {
            return "Not enough disk space. Free some space and retry."
        }
        if case ModelDownloadError.maxRetriesExhausted(let last) = error {
            return message(for: last)
        }
        if case ModelDownloadError.invalidFileSize = error {
            return "The download was incomplete. Retry to fetch it again."
        }
        return "Download failed: \(error.localizedDescription)"
    }

    /// True when the error is the user's own cancel, which is not a failure to report.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }
}

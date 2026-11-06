//
//  MeetingCallPolicy.swift
//  Whisperer
//
//  How sure we are that a call is actually happening, from the detector's evidence — and the one
//  rule that matters most: only CONFIRMED may ever start a recording on its own.
//
//  Deterministic and explainable on purpose. No audio is analysed to decide whether a call
//  exists; the inputs are process-level facts the OS already reports (who holds the microphone,
//  whether a conferencing app's in-call audio device is running, a verified meeting tab).
//
//  Prefer a missed auto-start over recording an unrelated conversation.
//

import Foundation

nonisolated enum MeetingCallConfidence: Int, Comparable, Sendable, CustomStringConvertible {
    /// No candidate.
    case none
    /// A conferencing app is around but nothing says a call is live. Never prompts.
    case possible
    /// A call is very probably live. Prompts; never auto-records.
    case likely
    /// A validated conferencing app or verified meeting tab is live, sustained. May auto-record
    /// when the user opted in.
    case confirmed

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .none: return "none"
        case .possible: return "possible"
        case .likely: return "likely"
        case .confirmed: return "confirmed"
        }
    }
}

/// The evidence behind one detected call, as the detector saw it.
nonisolated struct MeetingCallSignals: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A native conferencing app (Zoom, Teams, Webex, Slack, FaceTime).
        case nativeApp
        /// A browser whose meeting tab was identified from its window title (direct build only:
        /// it needs Accessibility, which the App Store build does not use).
        case browserVerifiedTab
        /// A browser holding the microphone with no way to tell which tab. Could be dictation,
        /// voice search, a voice memo site — never enough for an unattended start.
        case browserUnverified
    }

    var source: Source
    var provider: ConferenceProvider?
    /// This app was attributed live microphone capture by CoreAudio.
    var processCaptureConfirmed: Bool
    /// The provider's in-call audio device is running (ZoomAudioDevice, Microsoft Teams Audio…).
    var virtualDeviceActive: Bool
    /// How long the live signal has held without a break.
    var sustainedSeconds: TimeInterval
}

nonisolated enum MeetingCallPolicy {
    /// Native apps validated for unattended starts. Slack (mic held for many non-call reasons in
    /// some builds) and FaceTime stay prompt-only until validated on real traces.
    static let autoRecordProviders: Set<ConferenceProvider> = [.zoom, .teams, .webex]

    /// Live evidence must hold this long before a call counts as confirmed.
    static let minStableSeconds: TimeInterval = 3

    static func confidence(_ s: MeetingCallSignals) -> MeetingCallConfidence {
        let live = s.processCaptureConfirmed || s.virtualDeviceActive
        guard live else { return .possible }
        switch s.source {
        case .nativeApp:
            guard let provider = s.provider, autoRecordProviders.contains(provider) else { return .likely }
            // The in-call device exists only during a call, so it needs no settling time.
            if s.virtualDeviceActive { return .confirmed }
            return s.sustainedSeconds >= minStableSeconds ? .confirmed : .likely
        case .browserVerifiedTab:
            return s.processCaptureConfirmed && s.sustainedSeconds >= minStableSeconds ? .confirmed : .likely
        case .browserUnverified:
            return .likely
        }
    }

    /// One line for the log — which signals, which verdict, why.
    static func explain(_ s: MeetingCallSignals) -> String {
        "confidence=\(confidence(s)) source=\(s.source) provider=\(s.provider?.rawValue ?? "unknown") capture=\(s.processCaptureConfirmed) device=\(s.virtualDeviceActive) sustained=\(Int(s.sustainedSeconds))s"
    }
}

/// Whether a call that was live still is — used to re-check right before an automatic start and
/// to decide when an automatically started recording should end.
nonisolated enum MeetingCallLiveness: Equatable, Sendable {
    case live
    /// Off the microphone (and its in-call device down) since this time.
    case ended(since: Date)
    /// The app quit — the most definitive end there is.
    case appQuit
    /// Nothing observable either way (a source whose end cannot be seen).
    case unknown
}

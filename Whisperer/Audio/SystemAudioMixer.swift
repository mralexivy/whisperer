//
//  SystemAudioMixer.swift
//  Whisperer
//
//  The meeting's far-end audio (the other participants, captured from the call app through a
//  Core Audio process tap) folded into the microphone stream the meeting pipeline already reads.
//
//  Pure and lock-guarded so it can be unit-tested without CoreAudio. The capture side
//  (`SystemAudioCapture`) appends 16 kHz mono samples from its IOProc queue; `AudioRecorder`
//  pulls exactly as many as each microphone buffer holds, so the **microphone stays the clock**:
//  the transcriber, the diarizer and the session file keep counting the same samples they always
//  counted, and every timestamp in the pipeline means what it meant before.
//

import CoreAudio
import Foundation

nonisolated final class SystemAudioMixer: @unchecked Sendable {

    /// The levels of both sides over one microphone buffer, on the meeting's own clock (the
    /// samples the transcript and the diarizer count). Recorded whether or not the far end is
    /// mixed in: on speakers the mix is off but the tap still says when the call is talking,
    /// which is what tells a local voice from a remote one (`SpeakerSourceAttribution`).
    struct SourceFrame: Equatable, Sendable {
        /// First sample of the buffer, counted from the start of the meeting's audio.
        let start: Int
        let count: Int
        let micRMS: Float
        let callRMS: Float
    }

    /// The most far-end audio held waiting for a microphone buffer. The two streams run on
    /// different device clocks, so the backlog drifts; past this the oldest samples are dropped
    /// rather than letting the call audio fall further and further behind the user's voice.
    static let maxBacklogSamples = 8_000          // 0.5 s at 16 kHz

    private let lock = NSLock()
    private var pending: [Float] = []
    private var _isMixEnabled = true

    // Counters for the end-of-meeting log line.
    private var appendedSamples = 0
    private var mixedSamples = 0
    private var droppedSamples = 0
    private var underrunSamples = 0
    private var peak: Float = 0
    private var frames: [SourceFrame] = []
    private var position = 0

    /// False while the far end would be heard twice (the call is playing on speakers, which the
    /// microphone already picks up). The backlog keeps draining so re-enabling it later does not
    /// replay stale audio.
    var isMixEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isMixEnabled }
        set { lock.lock(); _isMixEnabled = newValue; lock.unlock() }
    }

    /// Far-end audio, 16 kHz mono Float32. Called from the capture queue.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        pending.append(contentsOf: samples)
        appendedSamples += samples.count
        for s in samples where abs(s) > peak { peak = abs(s) }
        let excess = pending.count - Self.maxBacklogSamples
        if excess > 0 {
            pending.removeFirst(excess)
            droppedSamples += excess
        }
    }

    /// Returns `mic` with the same number of far-end samples summed in. A short backlog is padded
    /// with silence (the call was quiet, or the tap has not delivered yet). The sum is clamped to
    /// [-1, 1]; both sides are speech at conversational level, so clipping is rare and a hard
    /// clamp is enough.
    func mix(mic: [Float]) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let take = min(mic.count, pending.count)
        let enabled = _isMixEnabled
        if !mic.isEmpty {
            var micSum: Float = 0, callSum: Float = 0
            for v in mic { micSum += v * v }
            for i in 0..<take { callSum += pending[i] * pending[i] }
            let n = Float(mic.count)
            frames.append(SourceFrame(start: position, count: mic.count,
                                      micRMS: (micSum / n).squareRoot(), callRMS: (callSum / n).squareRoot()))
            position += mic.count
        }
        var out = mic
        if enabled {
            for i in 0..<take {
                out[i] = max(-1, min(1, mic[i] + pending[i]))
            }
            mixedSamples += take
        }
        if take > 0 { pending.removeFirst(take) }
        if enabled { underrunSamples += mic.count - take }
        return out
    }

    /// Throws away whatever is waiting — the meeting is paused (or the user is dictating on top of
    /// it), so the span is skipped in the file and the transcript. Keeping it would replay it
    /// into the first buffer after the pause.
    func discardPending() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll(keepingCapacity: true)
    }

    /// Every buffer's levels so far, oldest first.
    var sourceActivity: [SourceFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    var backlog: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    var stats: (appended: Int, mixed: Int, dropped: Int, underrun: Int, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        return (appendedSamples, mixedSamples, droppedSamples, underrunSamples, peak)
    }

    // MARK: - Format helpers (pure)

    /// Averages `channels` interleaved channels down to mono.
    static func downmixInterleaved(_ data: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        guard channels > 1 else { return Array(data) }
        let frames = data.count / channels
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += data[f * channels + c] }
            out[f] = sum * scale
        }
        return out
    }

    /// Averages non-interleaved channel buffers down to mono. Buffers of unequal length are
    /// truncated to the shortest.
    static func downmixPlanar(_ channels: [UnsafeBufferPointer<Float>]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return Array(first) }
        let frames = channels.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels.count)
        for f in 0..<frames {
            var sum: Float = 0
            for ch in channels { sum += ch[f] }
            out[f] = sum * scale
        }
        return out
    }
}

// MARK: - Decisions (pure)

/// Where the call's audio is going, as far as echo is concerned.
nonisolated enum CallAudioOutputRoute: String, Equatable {
    /// Headphones, a headset, AirPods — the microphone cannot hear the far end.
    case headphones
    /// Speakers the microphone hears: the far end is already in the mic signal.
    case speakers
    /// A virtual or aggregate device — nothing can be concluded, so treat it as private.
    case unknown

    /// Mixing the tap on speakers would put every far-end word in the stream twice, the second
    /// copy a few tens of milliseconds late through the room. Skip it there; the microphone
    /// already carries the call, which is exactly how meetings recorded before this existed.
    var shouldMixFarEnd: Bool { self != .speakers }

    /// Classifies an output device from its transport type, its data source (the built-in
    /// output reports `ispk` / `hdpn`), and its name as a last resort — recent Macs present
    /// "External Headphones" as a device of its own with no data source.
    static func classify(transport: UInt32, dataSource: UInt32?, name: String?) -> CallAudioOutputRoute {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            if let source = dataSource {
                if source == fourCC("hdpn") { return .headphones }
                if source == fourCC("ispk") { return .speakers }
            }
            if let name, name.localizedCaseInsensitiveContains("headphone") { return .headphones }
            return .speakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB:
            // Headsets far outnumber Bluetooth/USB speakers on a call. A speaker here is the
            // documented echo case.
            return .headphones
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeThunderbolt:
            return .speakers
        default:
            return .unknown
        }
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// What the process tap listens to.
nonisolated enum CallAudioTapTarget: Equatable {
    /// Every process of the call app (helpers included — Chrome and Electron apps play through
    /// them).
    case app(bundleID: String, processes: [AudioObjectID])
    /// Everything except Whisperer itself: the call app is unknown or not playing yet.
    case allExcept(processes: [AudioObjectID])

    var logLabel: String {
        switch self {
        case .app(let id, let p): return "app:\(id)(\(p.count))"
        case .allExcept: return "system"
        }
    }

    /// Picks the narrowest target that will hear the call: the app the meeting was detected in;
    /// failing that, the one app other than Whisperer holding the microphone; failing that, all
    /// system audio except Whisperer's own.
    static func choose(sourceBundleID: String?,
                       capturingBundleIDs: Set<String>,
                       ownBundleID: String,
                       processesFor: (String) -> [AudioObjectID],
                       ownProcesses: [AudioObjectID]) -> CallAudioTapTarget {
        if let source = sourceBundleID, source != ownBundleID {
            let processes = processesFor(source)
            if !processes.isEmpty { return .app(bundleID: source, processes: processes) }
        }
        let others = capturingBundleIDs.subtracting([ownBundleID])
        if others.count == 1, let only = others.first {
            let processes = processesFor(only)
            if !processes.isEmpty { return .app(bundleID: only, processes: processes) }
        }
        return .allExcept(processes: ownProcesses)
    }
}

//
//  AudioEngineLifecycle.swift
//  Whisperer
//
//  Actor that is the sole owner of AVAudioEngine.
//  No external code ever holds a reference to the engine, input node, or tap.
//  All lifecycle operations go through actor methods.
//
//  Actor reentrancy is intentional and load-bearing:
//  During `await withCheckedThrowingContinuation`, the actor is suspended and
//  stopEngine() can run immediately — this is the mechanism that prevents
//  concurrent start/stop from deadlocking. Never "fix" the reentrancy out.
//

import AVFoundation
import Accelerate
import CoreAudio
import AudioToolbox

// MARK: - Error

enum AudioEngineError: Error, LocalizedError {
    case notPrepared
    case abandoned
    case buildFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notPrepared: return "Engine not in prepared state"
        case .abandoned:   return "Engine operation abandoned (concurrent stop)"
        case .buildFailed(let e): return "Engine build failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - Actor

actor AudioEngineLifecycle {

    // MARK: Phase

    enum Phase {
        case idle
        case building        // configure(): engine being built on lifecycleQueue
        case prepared        // engine configured, tap installed, not yet started
        case starting        // engine.start() dispatched off-actor
        case running(generation: Int)
        case stopping        // engine.stop() queued on lifecycleQueue
        case abandoned       // engine.start() was hung — engine orphaned on old queue
        case failed(Error)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.building, .building), (.prepared, .prepared),
                 (.starting, .starting), (.stopping, .stopping), (.abandoned, .abandoned):
                return true
            case (.running(let a), .running(let b)): return a == b
            case (.failed, .failed): return true
            default: return false
            }
        }
    }

    // MARK: State

    private(set) var generation: Int = 0
    private var engine: AVAudioEngine?

    // Phase setter auto-emits to EventRingBuffer — no manual record() calls needed elsewhere
    private(set) var phase: Phase = .idle {
        didSet { emitPhaseTransition(from: oldValue, to: phase) }
    }

    // Fresh per-engine lifecycle queue — replaced on replaceDeadEngine() to bypass hung old queue
    private var lifecycleQueue = DispatchQueue(label: "audio.engine.lifecycle.0", qos: .userInitiated)
    // Dead engines released here — CoreAudio dealloc can block, keep off main/audio queue
    private let destroyQueue = DispatchQueue(label: "audio.engine.destroy", qos: .utility)

    // Config change observer — attached to the specific engine instance, removed on stop/replace
    private var configChangeObserver: NSObjectProtocol?

    // Device ID bound at configure time — cached for sync diagnostics in AudioRecorder
    private(set) var lastKnownDeviceID: AudioDeviceID?

    // Input format settled during buildGraph — exposed so the config-change handler in
    // AudioRecorder can distinguish a real format flip (must trigger recovery) from harmless
    // configuration noise (ignore during startup grace period).
    private(set) var lastKnownInputFormat: AVAudioFormat?

    // MARK: - configure

    /// Creates a fresh AVAudioEngine, binds device, installs tap, calls prepare().
    /// All CoreAudio setup runs on lifecycleQueue.
    func configure(
        route: ResolvedInputRoute,
        onBuffer: @escaping ([Float]) -> Void,
        onConfigChange: @escaping () -> Void
    ) async throws {
        // Remove previous observer before building new engine
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        // Release any previous engine to destroyQueue
        if let old = engine {
            engine = nil
            let dq = destroyQueue
            dq.async { _ = old }
        }

        phase = .building
        generation += 1
        let gen = generation
        let e = AVAudioEngine()

        // Replace the queue so this buildGraph is never blocked by a previous hung buildGraph.
        // Same pattern as replaceDeadEngine() — old queue and any queued work are abandoned.
        let newQ = DispatchQueue(label: "audio.engine.lifecycle.\(generation)", qos: .userInitiated, autoreleaseFrequency: .workItem)
        lifecycleQueue = newQ
        let q = newQ

        var boundDeviceID: AudioDeviceID? = nil
        var settledFormat: AVAudioFormat? = nil

        try await withCheckedThrowingContinuation { cont in
            q.async {
                do {
                    let result = try AudioEngineLifecycle.buildGraph(engine: e, route: route, onBuffer: onBuffer)
                    boundDeviceID = result.deviceID
                    settledFormat = result.settledFormat
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // Revalidate ALL state after suspension — actor may have been re-entered (e.g. stopEngine)
        guard generation == gen, case .building = phase else {
            destroyQueue.async { _ = e }
            throw AudioEngineError.abandoned
        }

        engine = e
        lastKnownDeviceID = boundDeviceID
        lastKnownInputFormat = settledFormat

        // Register config change observer for THIS specific engine instance
        let callback = onConfigChange
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: e,
            queue: .main
        ) { _ in callback() }

        phase = .prepared
    }

    // MARK: - startEngine

    /// Dispatches engine.start() to lifecycleQueue via continuation.
    ///
    /// INTENTIONAL DESIGN: if engine.start() hangs forever, this continuation never resumes.
    /// The startEngine() Task becomes permanently suspended. This is the deliberate tradeoff:
    /// the actor remains reentrant, stopEngine() runs normally, the app continues to function.
    /// The hung lifecycleQueue and engine are abandoned on the next replaceDeadEngine().
    /// Do NOT add a timeout continuation — that reintroduces the concurrent start/stop race.
    func startEngine() async throws {
        guard case .prepared = phase, let e = engine else { throw AudioEngineError.notPrepared }
        let gen = generation
        phase = .starting

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            lifecycleQueue.async {
                var nsErr: NSError?
                var swiftErr: Error?
                ObjCTry({
                    do { try e.start() }
                    catch { swiftErr = error }
                }, &nsErr)
                if let err = swiftErr { cont.resume(throwing: err) }
                else if let err = nsErr { cont.resume(throwing: err) }
                else { cont.resume() }
            }
        }

        // Revalidate generation, phase, AND engine identity after suspension.
        // stopEngine() sets phase to .abandoned or .idle and increments generation.
        // replaceDeadEngine() also increments generation.
        // Either means we must NOT transition to .running.
        guard generation == gen, case .starting = phase, engine === e else {
            lifecycleQueue.async { try? e.stop() }  // clean up our local ref
            throw AudioEngineError.abandoned
        }

        phase = .running(generation: gen)
    }

    // MARK: - stopEngine

    /// Synchronous stop. If engine is starting, abandons it (never calls stop() on a starting engine).
    /// If engine is running/prepared, dispatches removeTap + stop to lifecycleQueue.
    func stopEngine() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }

        let e = engine
        let q = lifecycleQueue
        engine = nil
        lastKnownDeviceID = nil
        lastKnownInputFormat = nil
        generation += 1

        if case .starting = phase {
            // engine.start() is running on lifecycleQueue.
            // Queueing stop() behind it would deadlock if start() hangs. Abandon instead.
            // The suspended startEngine() task will see gen/phase mismatch and clean its local ref.
            phase = .abandoned
            let dq = destroyQueue
            dq.async { _ = e }
        } else {
            phase = .stopping
            let dq = destroyQueue
            q.async {
                var err: NSError?
                ObjCTry({ e?.inputNode.removeTap(onBus: 0) }, &err)
                if let err { Logger.warning("removeTap exception: \(err.localizedDescription)", subsystem: .audio) }
                ObjCTry({ e?.stop() }, &err)
                if let err { Logger.warning("engine.stop exception: \(err.localizedDescription)", subsystem: .audio) }
                dq.async { _ = e }
            }
            phase = .idle
        }
    }

    // MARK: - replaceDeadEngine

    /// Called at the start of mid-recording recovery. Creates a fresh lifecycleQueue,
    /// bypassing the old one which may be permanently hung in engine.start().
    func replaceDeadEngine() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }

        let dead = engine
        let deadQueue = lifecycleQueue
        engine = nil
        lastKnownDeviceID = nil
        lastKnownInputFormat = nil
        generation += 1
        lifecycleQueue = DispatchQueue(
            label: "audio.engine.lifecycle.\(generation)",
            qos: .userInitiated
        )
        phase = .idle
        let dq = destroyQueue
        dq.async {
            _ = dead       // dealloc engine (CoreAudio cleanup)
            _ = deadQueue  // dealloc old queue — blocks if hung start() is still running on it
        }
    }

    // MARK: - buildGraph (static — no actor isolation required)

    /// Sets up the engine graph: device binding, format validation with settle wait, tap installation.
    /// Runs synchronously on lifecycleQueue. Returns the device ID bound to the engine.
    ///
    /// Key correctness invariant: the format passed to `installTap` is always re-read immediately
    /// before the call (not the object captured earlier), and the tap closure rebuilds its
    /// `AVAudioConverter` on-the-fly whenever the buffer's format differs from the one the
    /// converter was built for. Together, these prevent the macOS 26.2 Bluetooth assertion:
    ///   "required condition is false: format.sampleRate == inputHWFormat.sampleRate"
    @discardableResult
    private static func buildGraph(
        engine: AVAudioEngine,
        route: ResolvedInputRoute,
        onBuffer: @escaping ([Float]) -> Void
    ) throws -> (deviceID: AudioDeviceID?, settledFormat: AVAudioFormat?) {
        let inputNode = engine.inputNode  // force AUHAL AudioUnit creation
        Logger.step(.engBuild, .audio, ["unit": .bool(inputNode.audioUnit != nil)])

        // Bind device — skip CADefaultDeviceAggregate-* UIDs that CoreAudio creates during
        // handoffs; they are transient wrappers and binding one explicitly re-enters the same
        // broken default rather than using the stable underlying device.
        var boundDeviceID: AudioDeviceID? = nil
        switch route {
        case .explicit(let uid, let deviceID):
            if setInputDevice(deviceID, on: inputNode) {
                Logger.step(.devSelect, .audio, ["uid": .string(uid), "id": .int(Int(deviceID))])
                boundDeviceID = deviceID
            } else {
                Logger.event(.devFail, .audio, ["uid": .string(uid), "id": .int(Int(deviceID))], level: .error)
                throw RecordingError.audioUnitFailed
            }
        case .systemDefault:
            if let defaultID = systemDefaultInputDeviceID() {
                if setInputDevice(defaultID, on: inputNode) {
                    Logger.step(.devSelect, .audio, ["id": .int(Int(defaultID)), "explicit": .bool(false)])
                    boundDeviceID = defaultID
                } else {
                    Logger.event(.devFail, .audio, ["id": .int(Int(defaultID)), "fallback": .string("implicit")], level: .warning)
                }
            } else {
                Logger.step(.devSelect, .audio, ["id": .string("unresolved")])
            }
        }

        // Prepare BEFORE querying format (allocates resources for the bound device)
        engine.prepare()

        // Settle the input format. On Bluetooth (especially after a handoff on macOS 26.2), the
        // HAL negotiates the mic sample rate inside `prepare()`. The format read immediately after
        // `prepare()` reflects the *start* of that negotiation, not the end — and AVAudioEngine
        // asserts the tap format matches the *live* hardware format at install time. Wait until
        // two consecutive reads agree (or the budget expires).
        let settledFormat = settledInputFormat(inputNode: inputNode, deviceID: boundDeviceID)
        guard let inputFormat = settledFormat,
              inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            let badSR = inputNode.outputFormat(forBus: 0).sampleRate
            let badCh = inputNode.outputFormat(forBus: 0).channelCount
            Logger.event(.engBuild, .audio, ["sr": .double(badSR), "ch": .int(Int(badCh)), "fail": .bool(true)], level: .error)
            throw RecordingError.invalidFormat
        }

        // Create 16kHz mono Float32 output format (whisper requirement)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        ) else { throw RecordingError.invalidFormat }

        // Adaptive converter holder. Captured by reference (class wrapper) so the tap closure
        // can rebuild it when the hardware format flips mid-session (post-install BT negotiate).
        final class ConverterHolder {
            var converter: AVAudioConverter
            var lastInputFormat: AVAudioFormat
            var channelSelected: Bool = false
            init(_ c: AVAudioConverter, _ fmt: AVAudioFormat) { converter = c; lastInputFormat = fmt }
        }

        guard let initialConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            Logger.event(.engBuild, .audio, ["fail": .string("converter")], level: .error)
            throw RecordingError.invalidFormat
        }
        initialConverter.channelMap = [0]
        let holder = ConverterHolder(initialConverter, inputFormat)

        // Install tap — re-read the live format immediately before the call to close the
        // remaining window between `settledInputFormat` and `installTap`.
        let bufferSize: AVAudioFrameCount = 4096
        var tapErr: NSError?
        var tapOk = false

        // Three attempts at 100 ms intervals in case the format is still in flux.
        for tapAttempt in 1...3 {
            // Re-read the live format right before each install attempt.
            let liveFormat = inputNode.outputFormat(forBus: 0)
            let tapFormat = (liveFormat.sampleRate > 0 && liveFormat.channelCount > 0)
                ? liveFormat : inputFormat

            tapErr = nil
            tapOk = ObjCTry({
                inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [holder] buffer, _ in
                    // Adaptive converter: rebuild if the buffer's format changed (e.g. a BT
                    // re-negotiation that completes after tap install). Only fires on format change —
                    // the hot path is the `else` branch which is a single pointer compare.
                    if buffer.format != holder.lastInputFormat {
                        if let newConv = AVAudioConverter(from: buffer.format, to: outputFormat) {
                            newConv.channelMap = [0]
                            holder.converter = newConv
                            holder.lastInputFormat = buffer.format
                            holder.channelSelected = false
                            Logger.step(.engBuild, .audio, ["adaptive_conv": .bool(true),
                                                            "sr": .double(buffer.format.sampleRate)])
                        }
                    }

                    // RMS-based channel selection on first stereo/multi-channel buffer.
                    // Picks the channel with most energy; prevents silent-channel capture on
                    // right-dominant headsets and some USB mics.
                    if !holder.channelSelected, buffer.format.channelCount > 1,
                       let chanData = buffer.floatChannelData {
                        let frames = vDSP_Length(buffer.frameLength)
                        let nCh = Int(buffer.format.channelCount)
                        var bestCh = 0; var bestEnergy: Float = 0; var ch0Energy: Float = 0
                        for ch in 0..<nCh {
                            var energy: Float = 0
                            vDSP_measqv(chanData[ch], 1, &energy, frames)
                            if ch == 0 { ch0Energy = energy }
                            if energy > bestEnergy { bestEnergy = energy; bestCh = ch }
                        }
                        if bestCh != 0 && bestEnergy > ch0Energy * 1.5 {
                            holder.converter.channelMap = [NSNumber(value: bestCh)]
                            Logger.step(.engBuild, .audio, ["ch": .int(bestCh), "rms": .double(Double(bestEnergy))])
                        } else {
                            Logger.step(.engBuild, .audio, ["ch": .int(0), "rms": .double(Double(ch0Energy))])
                        }
                        holder.channelSelected = true
                    }

                    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
                    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                    guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
                    var convErr: NSError?
                    holder.converter.convert(to: out, error: &convErr, withInputFrom: { _, status in
                        status.pointee = .haveData
                        return buffer
                    })
                    guard convErr == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
                    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
                    onBuffer(samples)
                }
            }, &tapErr)

            if tapOk { break }

            Logger.event(.engTap, .audio, [
                "err": .string(tapErr?.localizedDescription ?? "unknown"),
                "tap_attempt": .int(tapAttempt)
            ], level: tapAttempt < 3 ? .warning : .error)

            if tapAttempt < 3 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        guard tapOk else {
            throw RecordingError.audioUnitFailed
        }
        Logger.step(.engTap, .audio, ["buf": .int(Int(bufferSize))])

        return (boundDeviceID, inputFormat)
    }

    // MARK: - Format settle helper

    /// Polls the input node's output format until two consecutive reads agree on the same
    /// sample rate, or until the budget expires (~1.2 s on the BT path). Subsumes the old
    /// zero-rate retry loop — same "HAL not ready" problem with a stricter test.
    ///
    /// Returns `nil` only if the format never produced a non-zero sample rate, which the caller
    /// treats as `invalidFormat`.
    private static func settledInputFormat(
        inputNode: AVAudioInputNode,
        deviceID: AudioDeviceID?,
        budgetSeconds: TimeInterval = 1.2
    ) -> AVAudioFormat? {
        let pollInterval: TimeInterval = 0.05  // 50 ms
        let maxIterations = Int(budgetSeconds / pollInterval)

        var prev = inputNode.outputFormat(forBus: 0)
        var flips = 0
        let startMs = Date()

        for _ in 0..<maxIterations {
            let cur = inputNode.outputFormat(forBus: 0)

            // Also cross-check against the HAL's nominal sample rate for the bound device.
            // On macOS 26.2 the node format can lag the HAL by one read interval.
            let nominalRate = deviceID.flatMap { nominalSampleRate($0) }
            let ratesAgree = nominalRate.map { abs($0 - cur.sampleRate) < 1.0 } ?? true

            if cur.sampleRate > 0 && cur.channelCount > 0 &&
               cur.sampleRate == prev.sampleRate && ratesAgree {
                let elapsedMs = Int(Date().timeIntervalSince(startMs) * 1000)
                Logger.step(.engBuild, .audio, [
                    "sr": .double(cur.sampleRate),
                    "ch": .int(Int(cur.channelCount)),
                    "settle_ms": .int(elapsedMs),
                    "flips": .int(flips)
                ])
                return cur
            }

            if cur.sampleRate != prev.sampleRate { flips += 1 }
            prev = cur
            Thread.sleep(forTimeInterval: pollInterval)
        }

        // Budget exhausted — return whatever we have if it has a non-zero rate.
        let final = inputNode.outputFormat(forBus: 0)
        if final.sampleRate > 0 && final.channelCount > 0 {
            Logger.event(.engBuild, .audio, [
                "sr": .double(final.sampleRate),
                "settle_ms": .int(Int(budgetSeconds * 1000)),
                "flips": .int(flips),
                "warn": .string("settle_budget_exceeded")
            ], level: .warning)
            return final
        }
        return nil
    }

    /// HAL nominal sample rate for a device. Used by `settledInputFormat` to cross-check the
    /// node's reported format against what the HAL itself believes it has negotiated.
    private static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate > 0 ? Double(rate) : nil
    }

    // MARK: - Device helpers (static)

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        // Never explicitly bind a CADefaultDeviceAggregate-* wrapper. CoreAudio creates these
        // transiently during device handoffs; pinning one re-enters the same broken default.
        // Return nil so the engine falls back to its own implicit default binding.
        if let uid = InputRoutePreflight.deviceUID(deviceID),
           uid.hasPrefix(kCADefaultDeviceAggregatePrefix) {
            Logger.step(.devSelect, .audio, ["id": .int(Int(deviceID)), "skip": .string("aggregate_wrapper")])
            return nil
        }

        return deviceID
    }

    @discardableResult
    private static func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) -> Bool {
        guard isValidInputDevice(deviceID), let au = inputNode.audioUnit else { return false }
        var id = deviceID
        return AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0, &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr
    }

    private static func isValidInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr && size > 0
    }

    // MARK: - Diagnostics

    private func emitPhaseTransition(from old: Phase, to new: Phase) {
        EventRingBuffer.shared.record(
            component: "AudioEngine",
            operation: "phase",
            kind: .state,
            metadata: [
                "from": .string(old.debugDescription),
                "to": .string(new.debugDescription),
                "gen": .int(generation)
            ]
        )
    }
}

// MARK: - Phase description

extension AudioEngineLifecycle.Phase: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .idle:              return "idle"
        case .building:          return "building"
        case .prepared:          return "prepared"
        case .starting:          return "starting"
        case .running(let gen):  return "running(gen=\(gen))"
        case .stopping:          return "stopping"
        case .abandoned:         return "abandoned"
        case .failed(let err):   return "failed(\(err.localizedDescription))"
        }
    }
}

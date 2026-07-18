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
        let q = lifecycleQueue
        var boundDeviceID: AudioDeviceID? = nil

        try await withCheckedThrowingContinuation { cont in
            q.async {
                do {
                    boundDeviceID = try AudioEngineLifecycle.buildGraph(engine: e, route: route, onBuffer: onBuffer)
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

    /// Sets up the engine graph: device binding, format validation with retry, tap installation.
    /// Runs synchronously on lifecycleQueue. Returns the device ID bound to the engine.
    @discardableResult
    private static func buildGraph(
        engine: AVAudioEngine,
        route: ResolvedInputRoute,
        onBuffer: @escaping ([Float]) -> Void
    ) throws -> AudioDeviceID? {
        let inputNode = engine.inputNode  // force AUHAL AudioUnit creation
        Logger.debug("Input node obtained (audioUnit: \(inputNode.audioUnit != nil))", subsystem: .audio)

        // Bind device
        var boundDeviceID: AudioDeviceID? = nil
        switch route {
        case .explicit(let uid, let deviceID):
            if setInputDevice(deviceID, on: inputNode) {
                Logger.debug("Bound explicit device: uid=\(uid) id=\(deviceID)", subsystem: .audio)
                boundDeviceID = deviceID
            } else {
                Logger.warning("Explicit device bind failed: uid=\(uid) id=\(deviceID)", subsystem: .audio)
                throw RecordingError.audioUnitFailed
            }
        case .systemDefault:
            if let defaultID = systemDefaultInputDeviceID() {
                Logger.debug("Using system default: id=\(defaultID)", subsystem: .audio)
                if setInputDevice(defaultID, on: inputNode) {
                    boundDeviceID = defaultID
                } else {
                    Logger.warning("Could not explicitly bind default device — using implicit routing", subsystem: .audio)
                }
            } else {
                Logger.debug("Using system default input device (could not resolve ID)", subsystem: .audio)
            }
        }

        // Prepare BEFORE querying format (allocates resources for the bound device)
        engine.prepare()

        // Query format — retry if HAL still initializing after sleep/wake
        var inputFormat = inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            Logger.warning("Initial format invalid (\(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch), retrying...", subsystem: .audio)
            for attempt in 1...5 {
                Thread.sleep(forTimeInterval: 0.1)  // blocks lifecycleQueue — acceptable on background queue
                inputFormat = inputNode.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 {
                    Logger.info("Format valid after retry \(attempt): \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch", subsystem: .audio)
                    break
                }
            }
        }
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            Logger.error("Invalid input format after retries: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels", subsystem: .audio)
            throw RecordingError.invalidFormat
        }
        Logger.debug("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels", subsystem: .audio)

        // Create 16kHz mono Float32 output format (whisper requirement)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        ) else { throw RecordingError.invalidFormat }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            Logger.error("Failed to create audio converter", subsystem: .audio)
            throw RecordingError.invalidFormat
        }
        converter.channelMap = [0]

        // Install tap — converter and outputFormat captured in closure for real-time callback
        let bufferSize: AVAudioFrameCount = 4096
        var tapErr: NSError?
        let tapOk = ObjCTry({
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
                let ratio = outputFormat.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
                var convErr: NSError?
                converter.convert(to: out, error: &convErr, withInputFrom: { _, status in
                    status.pointee = .haveData
                    return buffer
                })
                guard convErr == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
                let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
                onBuffer(samples)
            }
        }, &tapErr)

        guard tapOk else {
            Logger.error("Failed to install tap: \(tapErr?.localizedDescription ?? "unknown")", subsystem: .audio)
            throw RecordingError.audioUnitFailed
        }
        Logger.debug("Tap installed (bufferSize: \(bufferSize))", subsystem: .audio)

        return boundDeviceID
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
        return AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr ? deviceID : nil
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

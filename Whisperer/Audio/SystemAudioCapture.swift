//
//  SystemAudioCapture.swift
//  Whisperer
//
//  Captures a meeting's far-end audio — what the call app plays — through a Core Audio process
//  tap (macOS 14.2+): CATapDescription → AudioHardwareCreateProcessTap → a private aggregate
//  device that contains the tap → an IOProc on our own queue. Samples are mixed down to mono,
//  resampled to 16 kHz Float32 and handed to a `SystemAudioMixer`, which `AudioRecorder` folds
//  into the microphone stream.
//
//  The first start triggers the system's "Screen & System Audio Recording" prompt (text from
//  `NSAudioCaptureUsageDescription`). A denied permission is not an error here: the tap simply
//  delivers silence, which is why `MeetingCallAudioController` watches for digital silence.
//

import AVFoundation
import CoreAudio
import Foundation

nonisolated final class SystemAudioCapture: @unchecked Sendable {

    /// The aggregate device is private to this process, but `AudioDeviceManager` enumerates
    /// devices *in* this process — this prefix keeps it out of the microphone picker.
    static let aggregateUIDPrefix = "com.ivy.whisperer.call-audio."

    enum CaptureError: Error, CustomStringConvertible {
        case tapCreate(OSStatus)
        case tapFormat(OSStatus)
        case unsupportedFormat
        case noOutputDevice
        case aggregate(OSStatus)
        case ioProc(OSStatus)
        case start(OSStatus)

        var description: String {
            switch self {
            case .tapCreate(let s): return "tap create failed (\(s))"
            case .tapFormat(let s): return "tap format unreadable (\(s))"
            case .unsupportedFormat: return "tap format is not Float32"
            case .noOutputDevice: return "no output device"
            case .aggregate(let s): return "aggregate device failed (\(s))"
            case .ioProc(let s): return "IOProc failed (\(s))"
            case .start(let s): return "device start failed (\(s))"
            }
        }
    }

    private let mixer: SystemAudioMixer
    private let queue = DispatchQueue(label: "com.ivy.whisperer.call-audio", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?

    // Touched only on `queue` once started.
    private var converter: AVAudioConverter?
    private var monoInputFormat: AVAudioFormat?
    private var channelCount = 2
    private var isInterleaved = true
    /// The rate the tap's samples are converted from. It changes under a running meeting: AirPods
    /// playing a call at 48 kHz drop to the headset profile's 24 or 16 kHz the moment the meeting
    /// opens their microphone. Converting at the old rate made the far end twice as fast and full
    /// of gaps (2026-11-10, Zoom on AirPods Pro: 107 s of call audio in 207 s), so nothing in it
    /// could be transcribed or told apart as another speaker.
    private var inputRate: Double = 0
    private var formatListener: AudioObjectPropertyListenerBlock?
    // Measured rate, over consecutive callbacks only (a device switch leaves a gap).
    private var lastCallbackHost: UInt64 = 0
    private var measuredFrames = 0
    private var measuredSeconds: Double = 0
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!

    init(mixer: SystemAudioMixer) {
        self.mixer = mixer
    }

    deinit {
        // The IOProc block's temporary strong reference can make `queue` the deinit thread,
        // where draining `queue` would deadlock.
        stop(drain: false)
    }

    // MARK: - Start / stop

    func start(target: CallAudioTapTarget) throws {
        let description: CATapDescription
        switch target {
        case .app(_, let processes):
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        case .allExcept(let processes):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        }
        description.name = "Whisperer meeting call audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted   // the user must keep hearing the call

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr, newTap != kAudioObjectUnknown else { throw CaptureError.tapCreate(status) }
        tapID = newTap
        tapDescription = description

        do {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = Self.address(kAudioTapPropertyFormat)
            status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
            guard status == noErr else { throw CaptureError.tapFormat(status) }
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  asbd.mBitsPerChannel == 32,
                  asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
                throw CaptureError.unsupportedFormat
            }
            configure(asbd)
            Logger.info("Meeting call audio: tap format \(Int(asbd.mSampleRate)) Hz × \(asbd.mChannelsPerFrame)", subsystem: .audio)

            // The format changes when the output device does (AirPods into the headset profile).
            var formatAddress = Self.address(kAudioTapPropertyFormat)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reloadFormat(reason: "format changed") }
            if AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, queue, listener) == noErr {
                formatListener = listener
            }

            guard let outputID = Self.defaultOutputDeviceID(),
                  let outputUID = Self.stringProperty(outputID, kAudioDevicePropertyDeviceUID) else {
                throw CaptureError.noOutputDevice
            }

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Whisperer Call Audio",
                kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate)
            guard status == noErr, newAggregate != kAudioObjectUnknown else { throw CaptureError.aggregate(status) }
            aggregateID = newAggregate

            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inInputData, inInputTime, _, _ in
                self?.handleInput(inInputData, at: inInputTime.pointee)
            }
            guard status == noErr, let procID else { throw CaptureError.ioProc(status) }
            ioProcID = procID

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw CaptureError.start(status) }
        } catch {
            stop()
            throw error
        }
    }

    /// Re-points a per-app tap at the app's current processes — Chrome can start a new audio
    /// helper mid-call. Returns false when the HAL refused, in which case the tap keeps its old
    /// list.
    @discardableResult
    func updateProcesses(_ processes: [AudioObjectID]) -> Bool {
        guard tapID != kAudioObjectUnknown, let description = tapDescription else { return false }
        description.processes = processes
        var address = Self.address(kAudioTapPropertyDescription)
        var ref: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                       UInt32(MemoryLayout<CATapDescription>.size), ptr)
        }
        return status == noErr
    }

    /// Idempotent. Safe from any thread but `queue`.
    func stop(drain: Bool = true) {
        if let listener = formatListener, tapID != kAudioObjectUnknown {
            var address = Self.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, listener)
        }
        formatListener = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapDescription = nil
        // Let an IOProc block already queued finish before the caller moves on.
        if drain { queue.sync {} }
    }

    // MARK: - IOProc (on `queue`)

    // MARK: - Format

    /// Sets channel layout and the converter for `asbd`. On `queue` once started.
    private func configure(_ asbd: AudioStreamBasicDescription) {
        channelCount = Int(asbd.mChannelsPerFrame)
        isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        setInputRate(asbd.mSampleRate)
    }

    private func setInputRate(_ rate: Double) {
        inputRate = rate
        measuredFrames = 0
        measuredSeconds = 0
        if rate != outputFormat.sampleRate,
           let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) {
            monoInputFormat = mono
            converter = AVAudioConverter(from: mono, to: outputFormat)
        } else {
            monoInputFormat = nil
            converter = nil
        }
    }

    /// Re-reads the tap's format and switches to it when it changed. On `queue`.
    private func reloadFormat(reason: String) {
        guard tapID != kAudioObjectUnknown else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return }
        guard asbd.mSampleRate != inputRate || Int(asbd.mChannelsPerFrame) != channelCount else { return }
        Logger.info("Meeting call audio: \(reason) — \(Int(inputRate)) → \(Int(asbd.mSampleRate)) Hz × \(asbd.mChannelsPerFrame)", subsystem: .audio)
        configure(asbd)
    }

    /// The rate the samples really arrive at, from host time across consecutive callbacks. When it
    /// is off from the rate being converted by more than 15% for 1.5 s, the format is re-read, and
    /// if the tap still reports the old rate the measured one (snapped to a standard rate) is used.
    private func checkRate(frames: Int, at time: AudioTimeStamp) {
        guard time.mFlags.contains(.hostTimeValid), inputRate > 0 else { return }
        let host = time.mHostTime
        defer { lastCallbackHost = host }
        guard lastCallbackHost != 0, host > lastCallbackHost else { return }
        let gap = Double(AudioConvertHostTimeToNanos(host - lastCallbackHost)) / 1e9
        guard gap < 0.25 else { return }               // a pause or a device switch, not a rate
        measuredFrames += frames
        measuredSeconds += gap
        guard measuredSeconds >= 1.5 else { return }
        let measured = Double(measuredFrames) / measuredSeconds
        measuredFrames = 0
        measuredSeconds = 0
        guard abs(measured / inputRate - 1) > 0.15 else { return }
        reloadFormat(reason: "measured \(Int(measured)) Hz")
        guard abs(measured / inputRate - 1) > 0.15 else { return }
        let snapped = Self.nearestStandardRate(measured)
        Logger.warning("Meeting call audio: tap says \(Int(inputRate)) Hz but delivers \(Int(measured)) Hz — converting at \(Int(snapped))", subsystem: .audio)
        setInputRate(snapped)
    }

    static func nearestStandardRate(_ rate: Double) -> Double {
        [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
            .min { abs($0 - rate) < abs($1 - rate) }!
    }

    private func handleInput(_ bufferList: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var mono: [Float]
        if isInterleaved || buffers.count == 1 {
            guard let first = buffers.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let channels = isInterleaved ? max(1, Int(first.mNumberChannels)) : 1
            mono = SystemAudioMixer.downmixInterleaved(
                UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count),
                channels: channels)
        } else {
            let planes: [UnsafeBufferPointer<Float>] = buffers.compactMap { buffer in
                guard let data = buffer.mData else { return nil }
                return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                           count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            }
            mono = SystemAudioMixer.downmixPlanar(planes)
        }
        guard !mono.isEmpty else { return }
        // The first callback's frames precede the window; the count belongs to the interval
        // ending at this callback, which is what `checkRate` measures.
        checkRate(frames: mono.count, at: time)
        if let converter, let inFormat = monoInputFormat {
            mono = resample(mono, converter: converter, inFormat: inFormat)
        }
        mixer.append(mono)
    }

    private func resample(_ samples: [Float], converter: AVAudioConverter, inFormat: AVAudioFormat) -> [Float] {
        let frames = AVAudioFrameCount(samples.count)
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return [] }
        input.frameLength = frames
        samples.withUnsafeBufferPointer { ptr in
            input.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        let ratio = outputFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    // MARK: - HAL helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func uint32Property(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// Where the default output is playing, for the echo decision.
    static func currentOutputRoute() -> (route: CallAudioOutputRoute, name: String) {
        guard let device = defaultOutputDeviceID() else { return (.unknown, "none") }
        let transport = uint32Property(device, kAudioDevicePropertyTransportType) ?? 0
        let source = uint32Property(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        let name = stringProperty(device, kAudioObjectPropertyName) ?? "unknown"
        return (CallAudioOutputRoute.classify(transport: transport, dataSource: source, name: name), name)
    }
}

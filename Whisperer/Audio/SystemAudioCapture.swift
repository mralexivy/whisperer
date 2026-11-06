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
            channelCount = Int(asbd.mChannelsPerFrame)
            isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            if asbd.mSampleRate != outputFormat.sampleRate,
               let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
                                        channels: 1, interleaved: false) {
                monoInputFormat = mono
                converter = AVAudioConverter(from: mono, to: outputFormat)
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
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
                self?.handleInput(inInputData)
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

    private func handleInput(_ bufferList: UnsafePointer<AudioBufferList>) {
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

//
//  PrivacyShield.swift
//  Whisperer
//
//  Local experimental audio routing; state is published only through AppState.
//

import AppKit
import AVFoundation
import CoreAudio
import CoreML
import Foundation

// Serial control queue owns the native session. Core Audio callbacks and the C++
// processing worker never touch AppState, persistence, or transcription services.
final class PrivacyAudioSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ivy.whisperer.privacy.control", qos: .userInitiated)
    private var native: OpaquePointer?
    private var processor: PrivacyAudioProcessor?

    func start(input: AudioDeviceID, output: AudioDeviceID, model: URL?, strength: Float) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(throwing: CancellationError()); return }
                do {
                    let processor = try PrivacyAudioProcessor(modelURL: model, strength: strength)
                    guard let native = shield_audio_create() else { throw PrivacyShieldError.native(-7006) }
                    self.native = native; self.processor = processor
                    let status = shield_audio_start(native, input, output, { context, input, output, count in
                        guard let context, let input, let output else { return false }
                        return Unmanaged<PrivacyAudioProcessor>.fromOpaque(context).takeUnretainedValue().process(input, output, count: count)
                    }, Unmanaged.passUnretained(processor).toOpaque())
                    guard status == 0 else {
                        shield_audio_destroy(native); self.native = nil; self.processor = nil
                        throw PrivacyShieldError.native(status)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func metrics() async -> ShieldMetrics? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.native.map { shield_audio_metrics($0) })
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let native = self?.native { shield_audio_destroy(native) }
                self?.native = nil; self?.processor = nil
                continuation.resume()
            }
        }
    }
}

@MainActor
final class PrivacyShieldController {
    static let shared = PrivacyShieldController()
    private init() {}
    static let deviceUID = "com.ivy.whisperer.privacy-mic.v1"
    private var session: PrivacyAudioSession?
    private var monitor: Task<Void, Never>?
    private var generation = 0
    private var modelURL: URL?

    private var snapshot: PrivacyShieldSnapshot {
        get { AppState.shared.privacyShield }
        set { AppState.shared.privacyShield = newValue }
    }

    private static func inputFormat(_ device: AudioDeviceID) -> (rate: Double, transport: UInt32)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return (rate, transport)
    }

    func refreshDriver() {
        snapshot.driverInstalled = AudioDeviceManager.resolveDeviceIDByUID(Self.deviceUID) != nil
        AudioDeviceManager.shared.refreshDevices()
    }

    func chooseModel() {
        guard (snapshot.phase == .off || snapshot.phase == .muted), session == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an experimental compiled Core ML processor"
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, url.pathExtension == "mlmodelc" else { return }
        modelURL = url; snapshot.modelName = url.deletingPathExtension().lastPathComponent
    }

    func useBaseline() { guard (snapshot.phase == .off || snapshot.phase == .muted), session == nil else { return }; modelURL = nil; snapshot.modelName = nil }

    func start() {
        #if APP_STORE
        snapshot.message = "Privacy Shield requires the direct-download build and its audio driver."
        return
        #else
        guard snapshot.phase == .off || snapshot.phase == .muted, session == nil, !AppState.shared.privacyShieldInstallerBusy else { return }
        let app = AppState.shared
        guard app.state == .idle, app.activeMeetingSession == nil, app.pendingMeetingStarts == 0 else {
            snapshot.message = "Stop the current recording before enabling Privacy Shield."
            return
        }
        guard app.privacyShieldHeadphones else {
            snapshot.message = "Use headphones and confirm below. Speaker echo cancellation is not available in this version."
            return
        }
        refreshDriver()
        guard let output = AudioDeviceManager.resolveDeviceIDByUID(Self.deviceUID) else {
            snapshot.message = "Install the Whisperer audio driver, then refresh devices."
            return
        }
        guard let input = AudioDeviceManager.resolveDeviceIDByUID(app.privacyShieldInputUID), input != output else {
            snapshot.message = "Choose a connected physical microphone."
            return
        }
        guard let format = Self.inputFormat(input), format.transport != kAudioDeviceTransportTypeVirtual else {
            snapshot.message = "Choose a physical microphone rather than another virtual audio route."
            return
        }
        generation += 1; let token = generation
        snapshot.phase = .starting
        snapshot.message = "Starting. The virtual microphone stays silent until processed audio is ready."
        snapshot.resetMetrics()
        let runner = PrivacyAudioSession(); session = runner
        let selectedModel = modelURL
        let strength = Float(app.privacyShieldStrength)
        let uid = app.privacyShieldInputUID
        monitor = Task { [weak self] in
            guard let self else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard token == generation else { await runner.stop(); return }
            do {
                guard allowed else { throw PrivacyShieldError.unavailable("Microphone permission is required. Enable it in System Settings.") }
                try await runner.start(input: input, output: output, model: selectedModel, strength: strength)
                guard token == generation else { await runner.stop(); return }
                while !Task.isCancelled, token == generation {
                    guard AudioDeviceManager.resolveDeviceIDByUID(uid) == input,
                          AudioDeviceManager.resolveDeviceIDByUID(Self.deviceUID) == output,
                          Self.inputFormat(input)?.rate == format.rate else {
                        throw PrivacyShieldError.unavailable("An audio device disconnected or changed. The virtual microphone is muted; choose a microphone and retry.")
                    }
                    if let metrics = await runner.metrics() {
                        guard token == generation, !Task.isCancelled else { break }
                        guard metrics.error == 0 else { throw PrivacyShieldError.native(metrics.error) }
                        snapshot.blocks = metrics.processedBlocks
                        snapshot.processingMS = metrics.processingMilliseconds
                        snapshot.queuedMS = metrics.queuedMilliseconds
                        snapshot.maximumProcessingMS = metrics.maximumProcessingMilliseconds
                        snapshot.overBudgetBlocks = metrics.overBudgetBlocks
                        snapshot.underruns = metrics.underruns
                        if metrics.processedBlocks >= 3 {
                            snapshot.phase = .active
                            snapshot.message = "Experimental processing active. Select Whisperer Virtual Mic in your call. Resistance to transcription is unverified."
                        }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {
                if token == generation {
                    snapshot.phase = .muted
                    snapshot.message = error.localizedDescription
                    Logger.warning("Privacy Shield stopped: \(error.localizedDescription)", subsystem: .audio)
                }
            }
            await runner.stop()
            if token == generation { session = nil }
        }
        #endif
    }

    func stop() async {
        generation += 1
        let token = generation
        monitor?.cancel(); monitor = nil
        snapshot.phase = .stopping
        if let session { await session.stop() }
        guard token == generation else { return }
        session = nil
        snapshot.phase = .off
        snapshot.resetMetrics()
        snapshot.message = "Off. The virtual microphone is silent. Select your physical microphone in the call to resume unprocessed audio."
    }
}

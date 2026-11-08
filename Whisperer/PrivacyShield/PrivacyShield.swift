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

    func start(input: AudioDeviceID, output: AudioDeviceID, network: URL?, model: URL?, strength: Float,
               jamTranscription: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(throwing: CancellationError()); return }
                do {
                    let processor = try PrivacyAudioProcessor(networkURL: network, modelURL: model, strength: strength,
                                                              jamTranscription: jamTranscription)
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

    func setProcessing(_ enabled: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let native = self?.native { shield_audio_set_processing(native, enabled) }
                continuation.resume()
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
    private var requested = false
    private var routeNeedsConfiguration = false
    private var changingMode = false
    private let routes = AudioProcessMonitor()
    private static let enabledKey = "privacyShieldAutomaticEnabled"
    private nonisolated static let restoreKey = "privacyShieldRestoreInputUID"
    static let jamKey = "privacyShieldJamTranscription"

    /// Whether the shield also blocks transcription (the jammer). Off unless the user turns it on: it makes
    /// the voice sound robotic to listeners (author's listening check, 2026-11-08).
    static var jamsTranscription: Bool { UserDefaults.standard.object(forKey: jamKey) as? Bool ?? false }

    /// Changing the jammer restarts a running shield so the new setting applies to the live voice.
    func setJamsTranscription(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.jamKey)
        guard snapshot.isEnabled, snapshot.phase != .stopping else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.shutdown()
            self.start()
        }
    }

    private var snapshot: PrivacyShieldSnapshot {
        get { AppState.shared.privacyShield }
        set { AppState.shared.privacyShield = newValue }
    }

    private nonisolated static func inputFormat(_ device: AudioDeviceID) -> (rate: Double, transport: UInt32)? {
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
        snapshot.driverInstalled = Self.routingDriverReady()
        AudioDeviceManager.shared.refreshDevices()
    }

    // Query HAL away from the UI thread; never feed a virtual route back into itself.
    nonisolated static func physicalMicrophone() async -> AudioDeviceManager.AudioDevice? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDeviceManager.enumerateInputDevices().filter {
                    guard let format = inputFormat($0.id) else { return false }
                    return isPhysicalInput(transport: format.transport, rate: format.rate)
                }
                let preferred = AudioDeviceManager.currentDefaultInputDeviceID()
                let saved = UserDefaults.standard.string(forKey: restoreKey)
                continuation.resume(returning: devices.first { $0.id == preferred }
                    ?? devices.first { $0.uid == saved } ?? devices.first)
            }
        }
    }

    nonisolated static func isPhysicalInput(transport: UInt32, rate: Double) -> Bool {
        transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate
            && rate.isFinite && (8000...192000).contains(rate)
    }

    static func routingDriverReady() -> Bool {
        guard let device = AudioDeviceManager.resolveDeviceIDByUID(deviceUID) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func setDefaultInput(_ device: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        guard status == noErr, AudioDeviceManager.currentDefaultInputDeviceID() == device else {
            throw PrivacyShieldError.unavailable("Could not switch the system microphone. Your call may still use its previous input.")
        }
    }

    /// Never overwrite a microphone the user selected while we were running.
    @discardableResult
    private func restoreDefaultInput() -> Bool {
        guard let output = AudioDeviceManager.resolveDeviceIDByUID(Self.deviceUID),
              AudioDeviceManager.currentDefaultInputDeviceID() == output else { return true }
        guard let uid = UserDefaults.standard.string(forKey: Self.restoreKey),
              let input = AudioDeviceManager.resolveDeviceIDByUID(uid) else { return false }
        do { try Self.setDefaultInput(input); return true }
        catch { Logger.warning(error.localizedDescription, subsystem: .audio); return false }
    }

    func resumeAtLaunch() {
        // When armed, keep a stale virtual route silent until processed audio is
        // ready. Restoring raw input during crash recovery would expose first words.
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            restoreDefaultInput()
            return
        }
        guard Self.routingDriverReady(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            snapshot.phase = .muted
            snapshot.message = "Automatic mode is unavailable. Turn it off and on to finish setup."
            return
        }
        start()
    }

    func start() {
        #if APP_STORE
        snapshot.message = "Privacy Shield requires the direct-download build."
        #else
        guard !requested, !changingMode, !AppState.shared.privacyShieldInstallerBusy, snapshot.phase != .stopping else { return }
        let app = AppState.shared
        guard app.state == .idle, app.activeMeetingSession == nil, app.pendingMeetingStarts == 0 else {
            snapshot.message = "Stop the current recording before enabling Privacy Shield."
            return
        }
        requested = true
        routeNeedsConfiguration = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        if monitor != nil {
            snapshot.phase = .starting
            snapshot.message = "Enabling automatic processing…"
            return
        }
        generation += 1; let token = generation
        snapshot.phase = .starting
        snapshot.message = "Preparing automatic audio…"
        monitor = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard token == generation else { return }
                guard allowed else { throw PrivacyShieldError.unavailable("Allow microphone access in System Settings, then turn this on again.") }
                guard await prepareAudioSupport() else { throw PrivacyShieldError.unavailable(snapshot.message) }
                guard token == generation, !Task.isCancelled else { return }
                await runAutomatic(token: token)
            } catch {
                if token == generation {
                    requested = false
                    UserDefaults.standard.set(false, forKey: Self.enabledKey)
                    snapshot.phase = .off; snapshot.message = error.localizedDescription
                }
            }
            if token == generation { monitor = nil }
        }
        #endif
    }

    private func runAutomatic(token: Int) async {
        var failures = 0
        sessionLoop: while token == generation, !Task.isCancelled {
            let runner = PrivacyAudioSession()
            session = runner
            do {
                guard let microphone = await Self.physicalMicrophone(),
                      let format = Self.inputFormat(microphone.id),
                      let output = AudioDeviceManager.resolveDeviceIDByUID(Self.deviceUID) else {
                    throw PrivacyShieldError.unavailable("Waiting for a microphone. Reconnecting automatically…")
                }
                guard token == generation, !Task.isCancelled else { break }
                // Save before switching; survives a process crash without losing the source.
                UserDefaults.standard.set(microphone.uid, forKey: Self.restoreKey)
                snapshot.microphoneName = microphone.name; snapshot.resetMetrics()
                // Fail closed: without the trained protection network there is no protection to offer.
                guard let network = PrivacyAudioProcessor.bundledNetworkURL else {
                    throw PrivacyShieldError.unavailable("Voice protection isn't included in this build.")
                }
                try await runner.start(input: microphone.id, output: output, network: network, model: nil, strength: 1.0,
                                       jamTranscription: Self.jamsTranscription)
                guard token == generation, !Task.isCancelled else { await runner.stop(); break }
                await runner.setProcessing(requested)
                guard token == generation, !Task.isCancelled else { await runner.stop(); break }
                if requested && AudioDeviceManager.currentDefaultInputDeviceID() != output {
                    routeNeedsConfiguration = true
                } else if !requested {
                    restoreDefaultInput()
                }
                var lastReceived: UInt64 = 0, stalledPolls = 0
                var idlePolls = 0
                while token == generation, !Task.isCancelled {
                    guard AudioDeviceManager.resolveDeviceIDByUID(microphone.uid) == microphone.id,
                          AudioDeviceManager.resolveDeviceIDByUID(Self.deviceUID) == output,
                          Self.inputFormat(microphone.id)?.rate == format.rate else {
                        throw PrivacyShieldError.unavailable("Microphone changed. Reconnecting automatically…")
                    }
                    if requested, !routeNeedsConfiguration,
                       let current = AudioDeviceManager.currentDefaultInputDeviceID(), current != output,
                       let currentFormat = Self.inputFormat(current),
                       Self.isPhysicalInput(transport: currentFormat.transport, rate: currentFormat.rate) {
                        routeNeedsConfiguration = true
                        throw PrivacyShieldError.unavailable("Following your new microphone.")
                    }
                    guard let metrics = await runner.metrics() else { throw PrivacyShieldError.native(-7008) }
                    guard token == generation, !Task.isCancelled else { break }
                    if changingMode {
                        try await Task.sleep(for: .milliseconds(20))
                        continue
                    }
                    guard metrics.error == 0 else { throw PrivacyShieldError.native(metrics.error) }
                    await runner.setProcessing(requested)
                    guard token == generation, !Task.isCancelled else { break }
                    // Prime before selecting our route; no unprocessed startup frames reach a call.
                    if requested && routeNeedsConfiguration && metrics.processedBlocks >= 3 && metrics.receivedFrames > 0 {
                        try Self.setDefaultInput(output)
                        routeNeedsConfiguration = false
                    }
                    let inputs = routes.inputRoutes()
                    let usingRoute = inputs.filter { $0.devices.contains(output) }
                    let bypassing = inputs.filter { $0.devices != Set([output]) }
                    let routeStatus = PrivacyRouteStatus.evaluate(devices: inputs.map(\.devices), virtual: output,
                        hasSignal: metrics.receivedSignalFrames > 0)
                    stalledPolls = metrics.receivedFrames == lastReceived ? stalledPolls + 1 : 0
                    lastReceived = metrics.receivedFrames
                    guard stalledPolls < 12 else { throw PrivacyShieldError.native(-7008) }
                    snapshot.blocks = metrics.processedBlocks
                    snapshot.receivedFrames = metrics.receivedFrames
                    snapshot.processingMS = metrics.processingMilliseconds
                    snapshot.maximumProcessingMS = metrics.maximumProcessingMilliseconds
                    snapshot.overBudgetBlocks = metrics.overBudgetBlocks
                    snapshot.underruns = metrics.underruns
                    snapshot.queuedMS = metrics.queuedMilliseconds
                    if requested {
                        if routeStatus == .needsSelection {
                            snapshot.phase = .armed
                            let names = Set(bypassing.map { route in
                                NSRunningApplication.runningApplications(withBundleIdentifier: route.bundleID).first?.localizedName ?? route.bundleID
                            }).sorted().joined(separator: ", ")
                            snapshot.message = "\(names) is using another or unverified microphone. Choose Whisperer Virtual Mic there once."
                        } else if routeStatus == .verified {
                            snapshot.phase = .active
                            snapshot.message = "An app is using the processed microphone. Audio route verified."
                            failures = 0
                        } else if !routeNeedsConfiguration {
                            snapshot.phase = .armed
                            snapshot.message = usingRoute.isEmpty ? "Ready. Calls using the system microphone are processed automatically." : "Microphone in use. Speak to verify the audio."
                        }
                    } else {
                        snapshot.phase = .passthrough
                        snapshot.message = "Off. Your normal voice is passing through to the call."
                        idlePolls = usingRoute.isEmpty ? idlePolls + 1 : 0
                        if idlePolls >= 6 {
                            await runner.stop()
                            guard token == generation, !Task.isCancelled else { return }
                            session = nil
                            if requested { continue sessionLoop }
                            snapshot.phase = .off
                            snapshot.message = "Off. Your normal microphone is restored."
                            // A muted call may reopen its pinned virtual input later. Keep a
                            // lightweight watcher, not the hardware microphone, alive while off.
                            while token == generation, !Task.isCancelled, !requested,
                                  !routes.inputRoutes().contains(where: { $0.devices.contains(AudioDeviceManager.resolveDeviceIDByUID(Self.deviceUID) ?? output) }) {
                                try await Task.sleep(for: .milliseconds(500))
                            }
                            continue sessionLoop
                        }
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                if token == generation, !Task.isCancelled {
                    failures += 1
                    snapshot.phase = requested ? .muted : .passthrough
                    snapshot.message = "\(error.localizedDescription) Reconnecting automatically…"
                    Logger.warning("Privacy audio retry \(failures): \(error.localizedDescription)", subsystem: .audio)
                }
            }
            await runner.stop()
            guard token == generation, !Task.isCancelled else { break }
            session = nil
            // Back off without repeatedly prompting or restarting system audio.
            do { try await Task.sleep(for: .seconds(min(10, max(1, failures)))) } catch { break }
        }
    }

    func stop() async {
        guard !changingMode else { return }
        changingMode = true
        defer { changingMode = false }
        let wasStarting = snapshot.phase == .starting
        snapshot.phase = .stopping
        requested = false
        routeNeedsConfiguration = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        let restored = restoreDefaultInput()
        if monitor != nil, !wasStarting {
            if let session { await session.setProcessing(false) }
            snapshot.phase = .passthrough
            snapshot.message = restored ? "Off. Your normal voice is passing through." : "Off. Voice passes through; the previous microphone is disconnected."
            return
        }
        await shutdown()
        snapshot.message = restored ? "Off. Your normal microphone is restored." : "Off. Connect your microphone to restore normal audio."
    }

    func shutdown() async {
        requested = false
        generation += 1
        monitor?.cancel(); monitor = nil
        snapshot.phase = .stopping
        restoreDefaultInput()
        if let session { await session.stop() }
        session = nil
        snapshot.phase = .off; snapshot.resetMetrics()
    }
}

//
//  InputRoutePreflight.swift
//  Whisperer
//
//  Answers the question `InputHealthProbe` cannot: *before we even try to bind a device and
//  call `engine.prepare()`, is this device actually ready to capture?*
//
//  A Bluetooth device that has handed its link to another host (e.g. AirPods switched to an
//  iPhone) still passes every `InputHealthProbe` check — it reads alive, has input streams, is
//  unmuted, and has positive gain. The only thing that distinguishes it from a live device is
//  that `kAudioDevicePropertyDeviceIsRunningSomewhere` is false *and* its transport type is
//  Bluetooth or BLE.
//
//  Binding a cold Bluetooth device and calling `engine.prepare()` forces the HAL to bring the
//  mic link up from scratch — a 1.2–1.7 s round-trip that then settles at a different sample
//  rate, causing the tap-install assertion to fire. The correct response is to know this *before*
//  we burn an attempt, so the startup ladder can either wait the right amount or switch devices.
//
//  This type also catches `CADefaultDeviceAggregate-*` UIDs — transient wrappers CoreAudio
//  creates during a device handoff that the app should never bind explicitly. The prefix constant
//  is shared with `AudioDeviceManager` to prevent drift.
//
//  Shape mirrors `InputHealthProbe`: pure HAL reads, decision logic separated from readings, the
//  whole thing `nonisolated` and safe from any thread.
//

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Shared constant (also used by AudioDeviceManager)

/// UIDs that begin with this prefix are transient CoreAudio aggregate wrappers. Binding them
/// explicitly re-enters the same broken default instead of using the stable underlying device.
let kCADefaultDeviceAggregatePrefix = "CADefaultDeviceAggregate"

// MARK: - Readings

/// Raw HAL readings used for the preflight decision. Separated so the verdict logic is
/// unit-testable without hardware.
struct RoutePreflightFacts: Equatable {
    /// UID of the candidate device, or nil if unresolvable.
    var uid: String?
    /// Transport type (`kAudioDeviceTransportType*` constant, or 0 if unreadable).
    var transportType: UInt32 = 0
    /// Whether any process has the device running (input or output).
    var isRunningSomewhere: Bool = false
    /// Whether the device passes a basic `InputHealthProbe` check.
    var healthVerdict: InputHealthVerdict = .healthy
}

// MARK: - Verdict

/// How ready this route is for `buildGraph`.
enum RouteReadiness: Equatable {
    /// Good to go. Wired / built-in device, or a Bluetooth one already running.
    case ready
    /// Cold Bluetooth link. The device will come up, but needs time to settle.
    /// `estimatedMs` is our best guess at the settle window.
    case needsWarmup(estimatedMs: Int)
    /// The device has a real health problem (muted, gain zero, gone, etc.).
    /// Delegated directly from `InputHealthProbe`; reuse its `userMessage`.
    case unusable(InputHealthVerdict)
    /// Transient `CADefaultDeviceAggregate-*` wrapper. Never bind explicitly.
    case aggregateWrapper

    static func == (lhs: RouteReadiness, rhs: RouteReadiness) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready): return true
        case (.needsWarmup(let a), .needsWarmup(let b)): return a == b
        case (.unusable(let a), .unusable(let b)): return a == b
        case (.aggregateWrapper, .aggregateWrapper): return true
        default: return false
        }
    }

    /// Suggested extra settle delay (seconds) to wait before the *next* attempt after this
    /// result. Used by the startup ladder to size its between-attempt sleep.
    var suggestedSettleDelay: TimeInterval {
        switch self {
        case .ready:                 return 0.25   // nominal inter-attempt gap
        case .needsWarmup:           return 0.90   // give the BT link time to negotiate
        case .unusable, .aggregateWrapper: return 0.0  // skip immediately
        }
    }

    /// Whether we should bother attempting this route at all.
    var shouldAttempt: Bool {
        switch self {
        case .ready, .needsWarmup: return true
        case .unusable, .aggregateWrapper: return false
        }
    }

    /// Estimated first-buffer deadline (seconds after `startEngine()` succeeds) before which
    /// we expect audio to arrive. Bluetooth takes longer because the mic link comes up lazily.
    var firstBufferDeadline: TimeInterval {
        switch self {
        case .needsWarmup:  return 1.5
        case .ready:        return 0.7
        case .unusable, .aggregateWrapper: return 0.0
        }
    }
}

// MARK: - Probe

enum InputRoutePreflight {

    // MARK: Decision (pure — unit-testable without hardware)

    static func readiness(for facts: RoutePreflightFacts) -> RouteReadiness {
        // Aggregate wrappers first — they masquerade as real devices.
        if let uid = facts.uid, uid.hasPrefix(kCADefaultDeviceAggregatePrefix) {
            return .aggregateWrapper
        }

        // Delegate health checks to the existing probe verdict vocabulary.
        switch facts.healthVerdict {
        case .permissionDenied, .permissionNotDetermined, .deviceGone,
             .noInputStreams, .muted, .gainZero:
            return .unusable(facts.healthVerdict)
        case .healthy:
            break
        }

        // Cold Bluetooth: transport is BT/BLE *and* nothing is running.
        let isBluetooth = (facts.transportType == kAudioDeviceTransportTypeBluetooth ||
                           facts.transportType == kAudioDeviceTransportTypeBluetoothLE)
        if isBluetooth && !facts.isRunningSomewhere {
            // Measured settle window: 1200–1700 ms on macOS 26.2 with AirPods Pro.
            return .needsWarmup(estimatedMs: 1500)
        }

        return .ready
    }

    // MARK: Readings

    /// Pre-flight a `ResolvedInputRoute` and return the readiness verdict.
    /// Safe from any thread; performs only synchronous HAL property reads.
    static func preflight(route: ResolvedInputRoute) -> RouteReadiness {
        let deviceID: AudioDeviceID?
        let uid: String?

        switch route {
        case .systemDefault:
            deviceID = systemDefaultInputDeviceID()
            uid = deviceID.flatMap { deviceUID($0) }
        case .explicit(let u, let d):
            deviceID = d
            uid = u
        }

        var facts = RoutePreflightFacts()
        facts.uid = uid

        guard let devID = deviceID, devID != kAudioObjectUnknown else {
            // No device at all — treat as unusable.
            return .unusable(.deviceGone)
        }

        facts.transportType = transportType(devID)
        facts.isRunningSomewhere = isRunningSomewhere(devID)
        let (_, verdict) = InputHealthProbe.probe(deviceID: devID)
        facts.healthVerdict = verdict

        return readiness(for: facts)
    }

    // MARK: - Log fields

    static func logFields(_ facts: RoutePreflightFacts, _ readiness: RouteReadiness) -> [String: MetadataValue] {
        var fields: [String: MetadataValue] = [
            "transport": .string(transportName(facts.transportType)),
            "running": .bool(facts.isRunningSomewhere)
        ]
        if let uid = facts.uid { fields["uid"] = .string(uid) }
        switch readiness {
        case .ready:
            fields["preflight"] = .string("ready")
        case .needsWarmup(let ms):
            fields["preflight"] = .string("needs_warmup")
            fields["warmup_ms"] = .int(ms)
        case .unusable(let v):
            fields["preflight"] = .string("unusable")
            fields["reason"] = .string(v.logCode)
        case .aggregateWrapper:
            fields["preflight"] = .string("aggregate_wrapper")
        }
        return fields
    }

    // MARK: - HAL helpers (nonisolated, synchronous)

    static func systemDefaultInputDeviceID() -> AudioDeviceID? {
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
        return deviceID
    }

    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    static func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn:     return "built-in"
        case kAudioDeviceTransportTypeUSB:         return "usb"
        case kAudioDeviceTransportTypeBluetooth:   return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "ble"
        case kAudioDeviceTransportTypeHDMI:        return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "dp"
        case kAudioDeviceTransportTypeVirtual:     return "virtual"
        case kAudioDeviceTransportTypeAggregate:   return "aggregate"
        default:                                   return "0x\(String(type, radix: 16))"
        }
    }
}

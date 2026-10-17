// Privacy Shield presentation and error types.
import Foundation

struct PrivacyShieldSnapshot: Equatable {
    enum Phase: String { case off, starting, armed, active, muted, stopping, passthrough }
    var phase: Phase = .off
    var message = "Off. Your microphone is selected automatically when you turn this on."
    var blocks: UInt64 = 0
    var processingMS: Double = 0
    var maximumProcessingMS: Double = 0
    var overBudgetBlocks: UInt64 = 0
    var underruns: UInt64 = 0
    var queuedMS: Double = 0
    var driverInstalled = false
    var modelName: String?
    var microphoneName: String?
    var receivedFrames: UInt64 = 0
    mutating func resetMetrics() {
        receivedFrames = 0; blocks = 0; processingMS = 0; queuedMS = 0
        maximumProcessingMS = 0; overBudgetBlocks = 0; underruns = 0
    }
    var menuActionTitle: String {
        switch phase {
        case .off, .passthrough: return "Enable Privacy Shield"
        case .starting: return "Cancel Privacy Shield"
        case .active, .armed: return "Disable Privacy Shield"
        case .muted: return "Turn Off Privacy Shield (Muted)"
        case .stopping: return "Stopping Privacy Shield…"
        }
    }
    var isEnabled: Bool { phase != .off && phase != .passthrough }
    var blocksTranscription: Bool { isEnabled }
}

enum PrivacyShieldError: LocalizedError {
    case unavailable(String)
    case native(Int32)
    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .native(let code):
            switch code {
            case -7002, -7004, -7012, -7013: return "Audio could not keep up. The virtual microphone is muted. Retry when the Mac is less busy."
            case -7014: return "The selected device buffer is too large for low-latency processing. Choose a different microphone or reduce its buffer size."
            case -7008: return "The microphone stopped sending audio. The virtual microphone is muted."
            case -7009, -7011: return "The processor returned invalid audio. The virtual microphone is muted."
            case -7010: return "Processing exceeded its time budget. The virtual microphone is muted."
            default: return "Audio routing failed (\(code)). The virtual microphone is muted."
            }
        }
    }
}


// Shared by presentation and tests: mixed/unknown inputs are not verified routes.
enum PrivacyRouteStatus: Equatable {
    case waiting, verified, needsSelection
    static func evaluate(devices: [Set<UInt32>], virtual: UInt32, hasSignal: Bool) -> Self {
        if devices.contains(where: { $0 != Set([virtual]) }) { return .needsSelection }
        return !devices.isEmpty && hasSignal ? .verified : .waiting
    }
}

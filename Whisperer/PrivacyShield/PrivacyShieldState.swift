// Privacy Shield presentation and error types.
import Foundation

struct PrivacyShieldSnapshot: Equatable {
    enum Phase: String { case off, starting, active, muted, stopping }
    var phase: Phase = .off
    var message = "Experimental. Transcription resistance has not been validated."
    var blocks: UInt64 = 0
    var processingMS: Double = 0
    var queuedMS: Double = 0
    var driverInstalled = false
    var modelName: String?
    var blocksTranscription: Bool { phase != .off }
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
            case -7008: return "The microphone stopped sending audio. The virtual microphone is muted."
            case -7009, -7011: return "The processor returned invalid audio. The virtual microphone is muted."
            case -7010: return "Processing exceeded its time budget. The virtual microphone is muted."
            default: return "Audio routing failed (\(code)). The virtual microphone is muted."
            }
        }
    }
}


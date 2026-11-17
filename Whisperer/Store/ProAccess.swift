//
//  ProAccess.swift
//  Whisperer
//
//  What the $14.99 Pro purchase unlocks. The split is the one on whispererapp.com/pricing:
//  Basic ($4.99) is dictation, file transcription, history, the dictionary and Fast Polish;
//  Pro adds meetings, calendar sync, every AI feature and the MCP server.
//
//  Only the Mac App Store builds sell Pro. Direct builds (GitHub, local, tests) have no store,
//  so everything is unlocked there. Reading is allowed from any thread.
//

import Foundation

nonisolated enum ProFeature: CaseIterable, Sendable {
    /// Recording a meeting (and the live meeting transcript).
    case meetings
    /// Noticing that a call started and offering to record it.
    case meetingDetection
    /// Google / Microsoft / Apple calendar sync.
    case calendar
    /// Every language-model feature: meeting notes, Ask AI, the user's own AI, the built-in model, AI dictation modes.
    case ai
    /// The local MCP server.
    case mcp

    var title: String {
        switch self {
        case .meetings: return "Meetings"
        case .meetingDetection: return "Meeting detection"
        case .calendar: return "Calendar sync"
        case .ai: return "AI features"
        case .mcp: return "The MCP server"
        }
    }
}

nonisolated enum ProAccess {
    #if DEBUG
    /// Tests and previews: nil follows the real rule.
    nonisolated(unsafe) static var testOverride: Bool?
    #endif

    /// True when this build sells Pro and the user has not bought it.
    static var isLocked: Bool { !isPro }

    static var isPro: Bool {
        #if DEBUG
        if let testOverride { return testOverride }
        #endif
        #if APP_STORE
        return UserDefaults.standard.bool(forKey: StoreManager.proStatusKey)
        #else
        return true
        #endif
    }

    static func allows(_ feature: ProFeature) -> Bool { isPro }

    /// The sentence shown where a locked feature was asked for.
    static func lockedMessage(for feature: ProFeature) -> String {
        "\(feature.title) \(feature == .meetings || feature == .ai ? "are" : "is") part of Whisperer Pro. Upgrade in Settings."
    }
}

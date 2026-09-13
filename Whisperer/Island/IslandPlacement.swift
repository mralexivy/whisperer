//
//  IslandPlacement.swift
//  Whisperer
//
//  Placement options for the Island bar, plus the progressive reveal phase.
//  Declaring both here so IslandContentSizer can reference IslandRevealPhase without
//  a forward dependency on IslandRevealGate.
//

import Foundation

// MARK: - Reveal phase

nonisolated enum IslandRevealPhase: Equatable {
    case hidden
    /// Progressive sliver visible at the edge — intent suspected, not confirmed
    case sliver
    /// Full bar revealed — user is aiming at it
    case revealed
}

// MARK: - Placement

nonisolated enum IslandPlacement: String, CaseIterable, Identifiable {
    case topCenter    = "topCenter"
    case bottomCenter = "bottomCenter"
    case leftCenter   = "leftCenter"
    case rightCenter  = "rightCenter"

    var id: String { rawValue }

    var isVertical: Bool { self == .leftCenter || self == .rightCenter }

    var displayName: String {
        switch self {
        case .topCenter:    return "Top"
        case .bottomCenter: return "Bottom"
        case .leftCenter:   return "Left"
        case .rightCenter:  return "Right"
        }
    }

    /// SF Symbol for the settings diagram button
    var settingsGlyph: String {
        switch self {
        case .topCenter:    return "arrow.up.to.line"
        case .bottomCenter: return "arrow.down.to.line"
        case .leftCenter:   return "arrow.left.to.line"
        case .rightCenter:  return "arrow.right.to.line"
        }
    }

    // MARK: - Persistence (follow PolishFeatureFlags pattern: one place for key + default)

    static let defaultsKey  = "islandPlacement"
    static let defaultValue = IslandPlacement.bottomCenter

    static var current: IslandPlacement {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let p = IslandPlacement(rawValue: raw) else { return defaultValue }
        return p
    }

    static func save(_ placement: IslandPlacement) {
        UserDefaults.standard.set(placement.rawValue, forKey: defaultsKey)
    }
}

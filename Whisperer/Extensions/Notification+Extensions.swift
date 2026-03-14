//
//  Notification+Extensions.swift
//  Whisperer
//
//  Notification names for app-wide events
//

import Foundation

extension Notification.Name {
    static let switchToDictionaryTab = Notification.Name("switchToDictionaryTab")
    static let switchToAIModesTab = Notification.Name("switchToAIModesTab")
    static let dictionaryDidRebuild = Notification.Name("dictionaryDidRebuild")
    static let overlaySettingsChanged = Notification.Name("overlaySettingsChanged")
}

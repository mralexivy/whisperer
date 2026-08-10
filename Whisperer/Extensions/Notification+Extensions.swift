//
//  Notification+Extensions.swift
//  Whisperer
//
//  Notification names for app-wide events
//

import Foundation

extension NSNotification.Name {
    static let switchToDictionaryTab = Notification.Name("switchToDictionaryTab")
    static let switchToAIModesTab          = Notification.Name("switchToAIModesTab")
    static let switchToMeetingStudioTab    = Notification.Name("switchToMeetingStudioTab")
    static let dictionaryDidRebuild = Notification.Name("dictionaryDidRebuild")
    static let overlaySettingsChanged = Notification.Name("overlaySettingsChanged")
    static let overlayContentHeightChanged = Notification.Name("overlayContentHeightChanged")
    static let meetingOverviewDidGenerate  = Notification.Name("meetingOverviewDidGenerate")
    static let meetingOverviewDidFail      = Notification.Name("meetingOverviewDidFail")
    static let meetingRAGIndexingCompleted = Notification.Name("meetingRAGIndexingCompleted")
    /// object: the meeting UUID, userInfo["title"]: the generated title.
    static let meetingTitleDidGenerate     = Notification.Name("meetingTitleDidGenerate")
}

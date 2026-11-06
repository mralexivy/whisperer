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
    static let switchToFileTranscriptionTab = Notification.Name("switchToFileTranscriptionTab")
    static let switchToLLMTab              = Notification.Name("switchToLLMTab")
    /// A connected AI failed and the meeting was handled on this Mac instead. `object` is the meeting id.
    static let connectedAIDidFallBack      = Notification.Name("connectedAIDidFallBack")
    /// A meeting's notes changed outside the view showing them (an AI app added one over MCP).
    /// `object` is the meeting id, `userInfo["notes"]` the full new list.
    static let meetingNotesDidChange       = Notification.Name("meetingNotesDidChange")
    static let dictionaryDidRebuild = Notification.Name("dictionaryDidRebuild")
    static let overlaySettingsChanged  = Notification.Name("overlaySettingsChanged")
    static let islandPlacementChanged  = Notification.Name("islandPlacementChanged")
    static let overlayContentHeightChanged = Notification.Name("overlayContentHeightChanged")
    static let meetingOverviewDidGenerate  = Notification.Name("meetingOverviewDidGenerate")
    static let meetingOverviewDidFail      = Notification.Name("meetingOverviewDidFail")
    /// object: the meeting UUID, userInfo["title"]: the generated title.
    static let meetingTitleDidGenerate     = Notification.Name("meetingTitleDidGenerate")
    /// object: the meeting UUID, userInfo["segments"]: `[MeetingSegment]` after the LLM polish
    /// pass. Posted exactly once at the end of a run — the transcript is one NSTextView, so each
    /// post costs a full text-storage rebuild and clears any in-progress selection.
    static let meetingSegmentsDidRefine    = Notification.Name("meetingSegmentsDidRefine")
}

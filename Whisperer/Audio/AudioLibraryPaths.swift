//
//  AudioLibraryPaths.swift
//  Whisperer
//
//  Where every recording lives. One place, so a recording is never written to one folder and
//  looked for in another.
//
//      Application Support/Whisperer/
//          Recordings/            dictation audio, by readable name
//          Recordings/Meetings/   meeting audio — recorded here from the first second, never moved
//          Meetings/              meeting data: pending text, chat, processing jobs (no audio)
//          Sessions/              a dictation's audio while it records; moved to Recordings/
//
//  Builds before 2026-11-11 recorded meetings into Sessions/ and moved them to Meetings/ at stop;
//  a meeting that never reached a normal stop kept its file in Sessions/, which the 7-day sweep
//  then deleted. `MeetingManager.migrateAudioLayout()` brings those files here once, and
//  `MeetingManager.locateAudio` still finds a file in any older folder.
//

import Foundation

nonisolated enum AudioLibraryPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer")
    }
    static var recordings: URL { root.appendingPathComponent("Recordings") }
    static var meetingRecordings: URL { recordings.appendingPathComponent("Meetings") }
    static var meetingData: URL { root.appendingPathComponent("Meetings") }
    static var sessions: URL { root.appendingPathComponent("Sessions") }

    /// Every folder a meeting's audio has lived in, newest layout first.
    static var meetingAudioFolders: [URL] { [meetingRecordings, meetingData, sessions, recordings] }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

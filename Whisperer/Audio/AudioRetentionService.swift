//
//  AudioRetentionService.swift
//  Whisperer
//
//  Background sweep that enforces the Data Management retention setting and clears
//  orphaned session audio.
//
//  ### Why this exists
//  `autoDeleteAfterDays` shipped as a picker wired to nothing — the Data Management card
//  promised "Transcriptions older than the selected period will be automatically removed"
//  and no code ever read the key. The only cleanup in the app was a synchronous
//  `SessionStorage.deleteOrphanedSessions()` on the main thread at launch, which ran once
//  per launch (a menu bar app stays up for weeks), touched only `Sessions/`, and fired
//  *before* crash recovery had finished with the rows pointing at those files.
//
//  ### What a sweep deletes
//  Whole records, never just the audio: the CoreData row, the recording, and for a meeting
//  its `.wax` vector index and `<uuid>-chat.json` too. A library entry with a dead play
//  button is worse than no entry. Deletion goes through the owning manager
//  (`HistoryManager.deleteTranscriptions(olderThan:)`, `MeetingManager.deleteMeeting`) so
//  there is one delete path per record type, not two that can drift.
//

import Foundation
import Combine

@MainActor
final class AudioRetentionService {
    static let shared = AudioRetentionService()

    /// Never / 7 / 30 / 90 / 365 days. `0` means Never and is the default — an app update
    /// must never silently delete a library the user has been building.
    static let retentionDaysKey = "autoDeleteAfterDays"

    /// Long enough that the sweep is invisible, short enough that a machine left running for
    /// a month still enforces the setting.
    private static let sweepInterval: TimeInterval = 6 * 3600

    /// Session files this old belong to a recording that was never finalized. Unchanged from
    /// the behaviour this service absorbed.
    private static let orphanSessionAge: TimeInterval = 7 * 24 * 3600

    private var sweepTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var lastRetentionDays: Int
    private var isSweeping = false

    private init() {
        lastRetentionDays = UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    // MARK: - Lifecycle

    /// Start the repeating sweep. Called from `AppDelegate.setupComponents()`, which already
    /// runs behind `AudioStartupGate` — the launch sweep is a separate entry point
    /// (`runLaunchSweep`) so it can be ordered after crash recovery.
    func start() {
        guard sweepTask == nil else { return }

        // A picker change should take effect now, not in up to six hours.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let days = UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
                guard days != self.lastRetentionDays else { return }
                self.lastRetentionDays = days
                await self.sweep(reason: "setting changed")
            }
        }

        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.sweepInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.sweep(reason: "scheduled")
            }
        }
    }

    /// The one-shot sweep at launch. Must be called **after** `HistoryManager` and
    /// `MeetingManager` have finished recovering interrupted sessions — otherwise the orphan
    /// pass can unlink audio belonging to a row that is still being finalized.
    func runLaunchSweep() async {
        await sweep(reason: "launch")
    }

    func prepareForShutdown() {
        sweepTask?.cancel()
        sweepTask = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
    }

    // MARK: - Sweep

    private func sweep(reason: String) async {
        // Never sweep from a test host. The XCTest bundle runs inside `whisperer.app` under the
        // real bundle id, so this deletes the *user's* transcriptions, meetings and audio —
        // permanently, from a `xcodebuild test` run. Guarded at the sweep itself rather than at
        // the three call sites (`start`'s timer, its defaults observer, `runLaunchSweep`) so no
        // future entry point can reintroduce the hazard.
        if AppEnvironment.isRunningTests {
            Logger.info("Retention sweep (\(reason)) skipped — test environment", subsystem: .app)
            return
        }
        guard !isSweeping else { return }

        if let blocker = currentBlocker {
            Logger.debug("Retention sweep (\(reason)) skipped — \(blocker)", subsystem: .app)
            return
        }

        isSweeping = true
        defer { isSweeping = false }

        // Always runs, independent of the retention setting: these files are leftovers no
        // record refers to, not part of anyone's library.
        let orphans = await Task.detached(priority: .background) {
            SessionStorage.deleteOrphanedSessions(olderThan: Self.orphanSessionAge)
        }.value

        var transcriptionCount = 0
        var meetingCount = 0
        var bytes = orphans.bytes

        let days = UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
        if days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)

            let removed = await HistoryManager.shared.deleteTranscriptions(olderThan: cutoff)
            transcriptionCount = removed.count
            bytes += removed.bytes

            // Re-check the gate between the two halves: an hour-long meeting library can take
            // a while, and the user may have started recording in the meantime.
            for expired in await MeetingManager.shared.expiredMeetings(before: cutoff) {
                guard currentBlocker == nil else {
                    Logger.debug("Retention sweep paused mid-run — resuming next cycle", subsystem: .app)
                    break
                }
                await MeetingManager.shared.deleteMeeting(meetingID: expired.id)
                meetingCount += 1
                bytes += expired.audioBytes
            }
        }

        let total = orphans.count + transcriptionCount + meetingCount
        guard total > 0 else {
            Logger.debug("Retention sweep (\(reason)): nothing to remove", subsystem: .app)
            return
        }
        Logger.info(
            "Retention sweep (\(reason)): \(transcriptionCount) transcription(s), \(meetingCount) meeting(s), "
            + "\(orphans.count) orphaned session file(s), \(Self.format(bytes)) reclaimed",
            subsystem: .app
        )
    }

    /// Why bulk work on the audio library must not run right now, or nil when it is safe.
    /// Deleting or rewriting a record while the pipeline is mid-flight risks touching audio
    /// something still holds open. Shared with `AudioLibraryCompactor`, which has the same
    /// requirement for the same reason.
    var currentBlocker: String? {
        let appState = AppState.shared
        if appState.state != .idle { return "a recording is in progress" }
        if appState.activeMeetingSession != nil { return "a meeting is active" }
        if MeetingTranscriptRefiner.shared.activeMeetingID != nil { return "a transcript refine is running" }
        return nil
    }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

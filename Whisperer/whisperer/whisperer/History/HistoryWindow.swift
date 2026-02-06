//
//  HistoryWindow.swift
//  Whisperer
//
//  NSWindow subclass for history display
//

import AppKit
import SwiftUI

class HistoryWindow: NSWindow {

    init() {
        // Create window with standard style
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Configure window
        self.title = "Transcription History"
        self.minSize = NSSize(width: 700, height: 500)
        self.center()

        // Set content view to SwiftUI
        let historyView = HistoryWindowView()
        let hostingView = NSHostingView(rootView: historyView)
        self.contentView = hostingView

        // Make sure window appears in mission control and window list
        self.collectionBehavior = [.managed, .participatesInCycle]

        // Set delegate for window lifecycle events
        self.delegate = self
    }
}

// MARK: - Window Delegate

extension HistoryWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Window will be hidden but not deallocated
        Logger.debug("History window closed", subsystem: .app)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Refresh data when window becomes active
        Task { @MainActor in
            await HistoryManager.shared.loadTranscriptions()
        }
    }
}

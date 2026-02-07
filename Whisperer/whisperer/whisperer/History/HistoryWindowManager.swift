//
//  HistoryWindowManager.swift
//  Whisperer
//
//  Singleton for managing history window show/hide/toggle
//

import AppKit
import SwiftUI

class HistoryWindowManager {
    static let shared = HistoryWindowManager()

    private var historyWindow: HistoryWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {
        // Window created lazily on first show
    }

    deinit {
        removeObserver()
    }

    func showWindow() {
        // Ensure we're on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showWindow()
            }
            return
        }

        // Check if window is still valid
        if historyWindow == nil || historyWindow?.isVisible == false && historyWindow?.contentView == nil {
            createWindow()
        }

        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideWindow() {
        historyWindow?.orderOut(nil)
    }

    func toggleWindow() {
        if let window = historyWindow, window.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    private func createWindow() {
        // Remove existing observer if any
        removeObserver()

        // Create new window
        historyWindow = HistoryWindow()

        // Restore window position if saved
        if let frameString = UserDefaults.standard.string(forKey: "historyWindowFrame") {
            let frame = NSRectFromString(frameString)
            historyWindow?.setFrame(frame, display: true)
        }

        // Save position and clean up on close
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: historyWindow,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let window = notification.object as? HistoryWindow else { return }

            // Save window position
            let frameString = NSStringFromRect(window.frame)
            UserDefaults.standard.set(frameString, forKey: "historyWindowFrame")

            // Clean up
            self.removeObserver()
            self.historyWindow = nil
        }
    }

    private func removeObserver() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
    }
}

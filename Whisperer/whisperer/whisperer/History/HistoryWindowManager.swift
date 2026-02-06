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

    private init() {
        // Window created lazily on first show
    }

    func showWindow() {
        if historyWindow == nil {
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
        historyWindow = HistoryWindow()

        // Restore window position if saved
        if let frameString = UserDefaults.standard.string(forKey: "historyWindowFrame") {
            let frame = NSRectFromString(frameString)
            historyWindow?.setFrame(frame, display: true)
        }

        // Save position on close
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: historyWindow,
            queue: .main
        ) { [weak self] _ in
            if let window = self?.historyWindow {
                let frameString = NSStringFromRect(window.frame)
                UserDefaults.standard.set(frameString, forKey: "historyWindowFrame")
            }
        }
    }
}

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

        // Close any orphaned HistoryWindow instances (e.g. from macOS window restoration)
        // that aren't managed by us — they appear as stale, non-interactive zombie windows
        for window in NSApp.windows where window is HistoryWindow && window !== historyWindow {
            window.orderOut(nil)
            window.close()
        }

        // Create window lazily on first use (keep it alive for reuse)
        if historyWindow == nil {
            createWindow()
        }

        // Temporarily float above all windows, then reset to normal
        // so the window doesn't permanently stay above other apps
        historyWindow?.level = .floating
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.level = .normal
    }

    /// Shows workspace and dismisses the menu bar popover window
    func showWindowAndDismissMenu() {
        // Dismiss the MenuBarExtra window first
        dismissMenuBarWindow()
        showWindow()
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

        // Restore window position if saved, enforcing minimum size
        if let frameString = UserDefaults.standard.string(forKey: "historyWindowFrame"),
           let window = historyWindow {
            var frame = NSRectFromString(frameString)
            let minSize = window.minSize
            frame.size.width = max(frame.size.width, minSize.width)
            frame.size.height = max(frame.size.height, minSize.height)
            window.setFrame(frame, display: true)
        }

        // Save position on close - but DON'T release the window
        // Releasing during close causes crash in NSWindowTransformAnimation dealloc
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: historyWindow,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? HistoryWindow else { return }

            // Save window position
            let frameString = NSStringFromRect(window.frame)
            UserDefaults.standard.set(frameString, forKey: "historyWindowFrame")

            // Don't nil out historyWindow - keep it for reuse
            // This avoids the crash in NSWindowTransformAnimation dealloc
        }
    }

    private func removeObserver() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
    }

    private func dismissMenuBarWindow() {
        // The MenuBarExtra .window style creates an NSPanel.
        // Find it by excluding our own windows (HistoryWindow and OverlayPanel).
        for window in NSApp.windows where window.isVisible {
            // Skip our own history window
            if window === historyWindow { continue }
            // Skip overlay panels (non-activating NSPanels for recording UI and picker)
            if window is OverlayPanel { continue }
            if window is TranscriptionPickerPanel { continue }

            // The MenuBarExtra window is an NSPanel with a specific size (360x580)
            // or at a high window level. Match by type + level.
            if window is NSPanel {
                window.orderOut(nil)
                return
            }
        }
    }
}

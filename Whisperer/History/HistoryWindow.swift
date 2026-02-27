//
//  HistoryWindow.swift
//  Whisperer
//
//  NSWindow subclass for history display
//

import AppKit
import SwiftUI

// Notification for sidebar toggle
extension NSNotification.Name {
    static let toggleWorkspaceSidebar = NSNotification.Name("ToggleWorkspaceSidebarNotification")
}

class HistoryWindow: NSWindow {

    init() {
        // Create window with standard style
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Configure window
        self.title = "Workspace"
        self.minSize = NSSize(width: 700, height: 700)
        self.center()

        // Force dark appearance and blend titlebar with content
        self.appearance = NSAppearance(named: .darkAqua)
        self.titlebarAppearsTransparent = true
        self.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)
        self.hasShadow = false

        // Add toolbar with sidebar toggle at leading edge
        let toolbar = NSToolbar(identifier: "WorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        self.toolbarStyle = .unified
        self.titleVisibility = .hidden

        // Set content view to SwiftUI
        let historyView = HistoryWindowView()
        let hostingView = NSHostingView(rootView: historyView)
        self.contentView = hostingView

        // Remove visible window border by configuring content view layer
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0).cgColor
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.borderWidth = 0
        hostingView.layer?.borderColor = NSColor.clear.cgColor

        // Make sure window appears in mission control and window list
        self.collectionBehavior = [.managed, .participatesInCycle]

        // CRITICAL: Prevent AppKit from releasing window on close
        // We keep the window alive for reuse
        self.isReleasedWhenClosed = false

        // Set delegate for window lifecycle events
        self.delegate = self
    }

    @objc func toggleSidebar(_ sender: Any?) {
        NotificationCenter.default.post(name: .toggleWorkspaceSidebar, object: nil)
    }
}

// MARK: - Toolbar Delegate

extension HistoryWindow: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == .sidebarToggle {
            let item = NSToolbarItem(itemIdentifier: .sidebarToggle)
            item.label = "Toggle Sidebar"
            item.toolTip = "Show or hide the sidebar"

            // Plain borderless button — no rounded background
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggleSidebar(_:))
            item.view = button

            return item
        }
        return nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarToggle, .flexibleSpace]
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("SidebarToggle")
}

// MARK: - Window Delegate

extension HistoryWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Window will be hidden but not deallocated
        Logger.debug("Workspace closed", subsystem: .app)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Refresh data when window becomes active
        Task { @MainActor in
            await HistoryManager.shared.loadTranscriptions()
        }
    }
}

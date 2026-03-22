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

    private static let navyColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)
    private var localKeyMonitor: Any?
    private var savedToolbar: NSToolbar?

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
        self.titlebarSeparatorStyle = .none
        self.backgroundColor = Self.navyColor
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

        // Layer-backed for dark background — no masksToBounds/cornerRadius
        // (CoreAnimation clipping triggers Tahoe text compositing bug)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = Self.navyColor.cgColor

        // Make sure window appears in mission control, window list, and supports fullscreen
        self.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]

        // CRITICAL: Prevent AppKit from releasing window on close
        // We keep the window alive for reuse
        self.isReleasedWhenClosed = false

        // Disable macOS window restoration — restored windows bypass HistoryWindowManager
        // and appear as unmanaged zombie windows that can't be interacted with
        self.isRestorable = false

        // Set delegate for window lifecycle events
        self.delegate = self

        // Ctrl+Cmd+F fullscreen toggle — local monitor captures the shortcut
        // even when NSHostingView has focus (keyDown override doesn't reach NSWindow)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self else { return event }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command],
               event.charactersIgnoringModifiers == "f" {
                self.toggleFullScreen(nil)
                return nil
            }
            return event
        }
    }

    deinit {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
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

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Remove toolbar entirely — its NSVisualEffectView causes the white bar.
        // Traffic lights auto-hide in fullscreen so toolbar isn't needed.
        savedToolbar = toolbar
        toolbar = nil
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Restore toolbar for normal windowed mode
        toolbar = savedToolbar
        toolbarStyle = .unified
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        backgroundColor = HistoryWindow.navyColor
    }
}

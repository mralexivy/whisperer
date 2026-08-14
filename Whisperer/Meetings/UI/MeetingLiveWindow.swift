//
//  MeetingLiveWindow.swift
//  Whisperer
//
//  Compact always-on-top window that owns the live meeting experience.
//

import AppKit
import SwiftUI

final class MeetingLiveWindow: NSWindow {
    static let windowWidth: CGFloat = 400
    static let collapsedHeight: CGFloat = 56
    /// Gap to the screen edges. The window is a side rail, so the same value is used on all
    /// three sides it touches.
    static let screenMargin: CGFloat = 16
    /// Only used for the initial `contentRect`; `applyInitialFrame` immediately replaces it with
    /// a height derived from the screen — see `preferredFrame(on:)`.
    static let fallbackHeight: CGFloat = 560

    /// The window's resting shape: a full-height rail down the right edge of `screen`.
    ///
    /// A meeting transcript is a single tall column, and the whole point of this surface is to
    /// watch it accrue — a 560pt box showed three cards and threw the rest into a scroll the user
    /// had to chase. Right edge rather than centre so it sits beside the call rather than over it.
    static func preferredFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let height = max(collapsedHeight, visible.height - screenMargin * 2)
        return NSRect(x: visible.maxX - windowWidth - screenMargin,
                      y: visible.maxY - height - screenMargin,
                      width: windowWidth,
                      height: height)
    }

    /// Height to restore to when the user expands again, and the height persisted on close —
    /// saving the collapsed frame would reopen the window as a bare header strip.
    private var expandedHeight: CGFloat = MeetingLiveWindow.fallbackHeight
    private(set) var isCollapsed = false

    init(session: MeetingSession) {
        super.init(
            contentRect: NSRect(x: 0, y: 0,
                                width: MeetingLiveWindow.windowWidth,
                                height: MeetingLiveWindow.fallbackHeight),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.isRestorable = false
        // Width is fixed — every measurement in the compact layout assumes one column.
        self.minSize = NSSize(width: MeetingLiveWindow.windowWidth,
                              height: MeetingLiveWindow.collapsedHeight)
        // No practical height ceiling — the resting shape is already the full height of the
        // display, and a hardcoded one (it was 1400) clips the window on a tall external monitor.
        self.maxSize = NSSize(width: MeetingLiveWindow.windowWidth, height: .greatestFiniteMagnitude)

        let root = MeetingLiveWindowView(
            session: session,
            onClose: { [weak self] in self?.close() },
            onCollapseChanged: { [weak self] collapsed in self?.setCollapsed(collapsed) }
        )

        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        // No masksToBounds/cornerRadius — CoreAnimation clipping triggers the Tahoe text
        // compositing bug. Rounding is done with SwiftUI .clipShape() in the root view.
        self.contentView = hostingView
    }

    /// Collapse/expand keeps the **top** edge pinned so the header does not jump under the
    /// pointer that just clicked the chevron.
    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        if collapsed { expandedHeight = frame.height }
        isCollapsed = collapsed

        let target = collapsed ? MeetingLiveWindow.collapsedHeight : expandedHeight
        let newFrame = NSRect(x: frame.origin.x,
                              y: frame.origin.y + frame.height - target,
                              width: frame.width,
                              height: target)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    // Key so the title field and note editors accept text; never main, so the app the user is
    // actually meeting in keeps its main-window chrome.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Manager

@MainActor
final class MeetingLiveWindowManager {
    static let shared = MeetingLiveWindowManager()

    private var window: MeetingLiveWindow?
    private var closeObserver: NSObjectProtocol?

    /// Held strongly on purpose. `AppState.activeMeetingSession` is nilled once the tail chunk
    /// lands, but this window keeps rendering through naming and summarizing.
    private var session: MeetingSession?

    private init() {}

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Brings the live window up for `session`. Passing nil reuses the session already on
    /// screen — that is the HUD's "Open Meeting Window" recovery path.
    func show(session: MeetingSession?) {
        let target = session ?? self.session
        guard let target else {
            Logger.warning("MeetingLiveWindow.show called with no session", subsystem: .ui)
            return
        }

        // A different session means a different recording: rebuild rather than reuse, since the
        // root view binds its session at construction.
        if window == nil || self.session !== target {
            teardownWindow()
            create(for: target)
        }

        window?.orderFrontRegardless()
        AppState.shared.meetingWindowIsVisible = true
        Logger.info("Meeting live window shown", subsystem: .ui)
    }

    func close() {
        window?.close()
    }

    // MARK: - Lifecycle

    private func create(for session: MeetingSession) {
        closeOrphanedWindows()

        self.session = session
        let newWindow = MeetingLiveWindow(session: session)
        window = newWindow
        applyInitialFrame(to: newWindow)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] notification in
            guard notification.object is MeetingLiveWindow else { return }
            // Hand the recording UI back to the HUD — this is the only surface left.
            MainActor.assumeIsolated {
                AppState.shared.meetingWindowIsVisible = false
                self?.teardownWindow()
            }
            Logger.info("Meeting live window closed", subsystem: .ui)
        }
    }

    private func teardownWindow() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window = nil
        session = nil
    }

    /// Parks the window as a full-height rail on the right of the screen the user is working on.
    ///
    /// **Deliberately not restored from a saved frame.** This used to persist the frame on close
    /// and restore it whenever it still intersected any display — which meant one stale 560pt box
    /// saved by an earlier build permanently defeated `preferredFrame(on:)`, and no amount of
    /// changing the resting shape could ever be seen. The rail is a derived shape, not a user
    /// preference: it depends on the screen, and the user can still drag or resize it for the
    /// session. Restoring position across launches would need to be per-display anyway, which is
    /// more machinery than a window that has exactly one correct place is worth.
    private func applyInitialFrame(to window: MeetingLiveWindow) {
        // Same screen-picking rule the HUD uses: the display holding the pointer is where the
        // user is actually working.
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        else { return }

        window.setFrame(MeetingLiveWindow.preferredFrame(on: screen), display: false)
    }

    /// macOS window restoration can resurrect a zombie copy that renders but never responds.
    private func closeOrphanedWindows() {
        let orphans = NSApp.windows.filter { $0 is MeetingLiveWindow && $0 !== window }
        guard !orphans.isEmpty else { return }
        Logger.warning("Closing \(orphans.count) orphaned MeetingLiveWindow(s)", subsystem: .ui)
        for orphan in orphans {
            orphan.orderOut(nil)
            orphan.close()
        }
    }
}

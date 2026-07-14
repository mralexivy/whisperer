//
//  OnboardingWindow.swift
//  Whisperer
//
//  Custom borderless dark onboarding window with rounded corners.
//  Opens automatically on first launch.
//

import AppKit
import SwiftUI

class OnboardingWindow: NSWindow {

    init(initialPage: Int = 0) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.center()
        self.isReleasedWhenClosed = false
        self.level = .floating
        self.collectionBehavior = [.managed]
        self.isMovableByWindowBackground = true

        let onboardingView = OnboardingView(initialPage: initialPage, onComplete: { [weak self] in
            self?.close()
        })
        let hostingView = NSHostingView(rootView: onboardingView)
        hostingView.wantsLayer = true
        // No masksToBounds/cornerRadius — CoreAnimation clipping triggers Tahoe text bug
        // Rounding handled by SwiftUI .clipShape() in OnboardingView
        self.contentView = hostingView
    }

    // Allow dragging from anywhere in the window
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()

    private var window: OnboardingWindow?

    private init() {}

    func showIfNeeded() {
        guard !AppState.shared.hasCompletedOnboarding else { return }

        DispatchQueue.main.async { [weak self] in
            self?.show()
        }
    }

    func show(startingAtPage page: Int = 0) {
        if window == nil {
            window = OnboardingWindow(initialPage: page)
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }
}

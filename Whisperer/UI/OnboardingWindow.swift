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

    init() {
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

        let onboardingView = OnboardingView(onComplete: { [weak self] in
            self?.close()
        })
        let hostingView = NSHostingView(rootView: onboardingView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 20
        hostingView.layer?.masksToBounds = true
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

    func show() {
        if window == nil {
            window = OnboardingWindow()
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }
}

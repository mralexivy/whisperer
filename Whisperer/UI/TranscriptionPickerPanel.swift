//
//  TranscriptionPickerPanel.swift
//  Whisperer
//
//  Non-activating floating panel for the transcription picker overlay.
//

import AppKit
import SwiftUI
import Combine

class TranscriptionPickerPanel: NSPanel {
    private var visibilityCancellable: AnyCancellable?

    init() {
        // Dynamic height — will be resized when content changes
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configure panel behavior — matches OverlayPanel pattern
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isMovableByWindowBackground = false
        self.backgroundColor = NSColor.clear
        self.isOpaque = false
        self.hasShadow = false

        // Create SwiftUI content
        let pickerView = TranscriptionPickerView()
            .frame(maxWidth: .infinity)
            .background(Color.clear)

        let hostingView = NSHostingView(rootView: pickerView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // Container for layout
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.contentView = container

        // Start hidden
        self.alphaValue = 0.0
        self.orderOut(nil)

        // Observe picker state visibility changes
        visibilityCancellable = TranscriptionPickerState.shared.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                self?.updateVisibility(shouldShow: isVisible)
            }
    }

    private func positionAtCenter() {
        guard let screen = NSScreen.main else { return }

        let screenRect = screen.visibleFrame
        let panelWidth: CGFloat = 380
        // Dynamic height: header(50) + divider(1) + items(54 each) + footer(40) + padding
        let itemCount = min(TranscriptionPickerState.shared.items.count, 10)
        let panelHeight = CGFloat(50 + 1 + itemCount * 54 + 12 + 40)

        let xPos = screenRect.origin.x + (screenRect.width - panelWidth) / 2
        let yPos = screenRect.origin.y + (screenRect.height - panelHeight) / 2

        self.setFrame(
            NSRect(x: xPos, y: yPos, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    private func updateVisibility(shouldShow: Bool) {
        if shouldShow && !self.isVisible {
            positionAtCenter()
            self.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.animator().alphaValue = 1.0
            }
        } else if !shouldShow && self.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.animator().alphaValue = 0.0
            } completionHandler: {
                self.orderOut(nil)
                self.alphaValue = 1.0  // Reset for next show
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        visibilityCancellable?.cancel()
    }
}

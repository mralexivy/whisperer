//
//  MeetingSourceIcon.swift
//  Whisperer
//
//  Renders the real macOS app icon for the meeting source (Zoom, Slack, Chrome…).
//  Falls back to the SF Symbol registered in MeetingDetector when the app isn't installed.
//  Shows nothing when bundleID is nil — rows without a source keep their current layout.
//

import AppKit
import SwiftUI

struct MeetingSourceIcon: View {
    let bundleID: String?
    let appName: String?
    var size: CGFloat = 14

    var body: some View {
        if let bundleID {
            resolvedIcon(for: bundleID)
                .help(appName ?? "")
                .accessibilityLabel(appName ?? "Meeting source")
        }
    }

    @ViewBuilder
    private func resolvedIcon(for bundleID: String) -> some View {
        if let nsImage = AppIconCache.image(for: bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            let fb = MeetingDetector.shared.fallbackIcon(for: bundleID)
            Image(systemName: fb.symbol)
                .font(.system(size: size * 0.75, weight: .medium))
                .foregroundColor(fb.color)
                .frame(width: size, height: size)
        }
    }
}

// MeetingSourceIconCache has been merged into AppIconCache (Whisperer/Core/AppIconCache.swift).

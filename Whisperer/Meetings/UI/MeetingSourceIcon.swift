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
        if let nsImage = MeetingSourceIconCache.image(for: bundleID) {
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

// MARK: - Cache

/// Thread-safe (main-actor) LaunchServices icon cache.
///
/// `NSWorkspace.icon(forFile:)` hits LaunchServices and is visually noticeable if called
/// per-body-evaluation inside a scrolling `LazyVStack`. Both hits and misses are memoised;
/// a miss stores `nil` so the SF Symbol fallback appears instantly on subsequent renders.
@MainActor
enum MeetingSourceIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func image(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

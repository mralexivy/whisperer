//
//  AppIconCache.swift
//  Whisperer
//
//  Shared, main-actor-isolated icon resolution for any app identified by bundle ID.
//
//  Lookup order (first hit wins, all outcomes are memoised):
//    1. In-memory cache             — free after the first lookup per launch
//    2. NSWorkspace LaunchServices  — current, live icon (app still installed)
//    3. Disk snapshot               — AppSupport/Whisperer/AppIcons/<bundleID>.png
//                                    written at dictation time; survives app uninstall
//    4. nil                         — caller shows its own fallback
//

import AppKit
import Foundation

// MARK: - AppIconCache

@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]

    /// Returns the best available icon for the given bundle ID, or nil if none is found.
    static func image(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }

        // 1. LaunchServices — works while the app is installed
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let img = NSWorkspace.shared.icon(forFile: appURL.path)
            cache[bundleID] = img
            return img
        }

        // 2. Disk snapshot — covers uninstalled apps
        if let img = AppIconSnapshotStore.loadSnapshot(bundleID: bundleID) {
            cache[bundleID] = img
            return img
        }

        // Memoise the miss so we never hit disk/LaunchServices again this launch
        cache[bundleID] = nil
        return nil
    }

    /// Pre-populate the in-memory cache from a known NSImage (e.g. one already loaded at dictation
    /// time). Does not overwrite an existing entry.
    static func prime(bundleID: String, image: NSImage) {
        if cache[bundleID] == nil {
            cache[bundleID] = image
        }
    }
}

// MARK: - AppIconSnapshotStore

/// Writes and reads small PNG snapshots of app icons to disk so they survive app uninstall.
///
/// The directory is bounded to `maxSnapshots` files; oldest-by-modification-date entries are
/// pruned on the first write of each launch.
enum AppIconSnapshotStore {
    private static let iconSize = CGSize(width: 64, height: 64)
    private static let maxSnapshots = 150

    /// Set of bundle IDs already confirmed written this launch — avoids repeated FileManager hits.
    private static var writtenThisLaunch: Set<String> = []
    private static var hasPruned = false

    static var snapshotsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Whisperer/AppIcons")
    }

    // MARK: Write

    /// Stores a 64×64 PNG snapshot for `bundleID`. Safe to call from any non-main queue.
    static func store(_ icon: NSImage, bundleID: String) {
        guard !writtenThisLaunch.contains(bundleID) else { return }

        let dir = snapshotsDirectory
        let filename = sanitize(bundleID) + ".png"
        let url = dir.appendingPathComponent(filename)

        // Skip if the snapshot already exists
        if FileManager.default.fileExists(atPath: url.path) {
            writtenThisLaunch.insert(bundleID)
            return
        }

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // One-time prune per launch
        if !hasPruned {
            hasPruned = true
            pruneOldSnapshots(in: dir)
        }

        guard let png = render(icon, size: iconSize) else { return }

        do {
            try png.write(to: url, options: .atomic)
            writtenThisLaunch.insert(bundleID)
            Logger.debug("AppIconSnapshotStore: wrote \(filename)", subsystem: .app)
        } catch {
            Logger.error("AppIconSnapshotStore: failed to write \(filename): \(error)", subsystem: .app)
        }
    }

    // MARK: Read

    static func loadSnapshot(bundleID: String) -> NSImage? {
        let url = snapshotsDirectory.appendingPathComponent(sanitize(bundleID) + ".png")
        guard FileManager.default.fileExists(atPath: url.path),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }

    // MARK: Helpers

    private static func sanitize(_ bundleID: String) -> String {
        // Bundle IDs are reverse-DNS (e.g. com.apple.Safari). Replace any unsafe filename chars.
        bundleID.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .replacingOccurrences(of: "..", with: ".")
    }

    private static func render(_ icon: NSImage, size: CGSize) -> Data? {
        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy,
                  fraction: 1.0)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    private static func pruneOldSnapshots(in dir: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let pngs = contents.filter { $0.pathExtension == "png" }
        guard pngs.count > maxSnapshots else { return }

        // Sort oldest first, delete the excess
        let sorted = pngs.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate < bDate
        }
        let toDelete = sorted.prefix(pngs.count - maxSnapshots)
        for url in toDelete {
            try? FileManager.default.removeItem(at: url)
        }
        Logger.debug("AppIconSnapshotStore: pruned \(toDelete.count) old snapshots", subsystem: .app)
    }
}

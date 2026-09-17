//
//  DockPresenceMonitor.swift
//  Whisperer
//
//  Tracks whether the Dock is actually rendered on the Space the user is looking at.
//
//  Why this exists instead of just reading NSScreen.visibleFrame:
//    `visibleFrame` reserves the Dock's height on EVERY Space, including Spaces where the Dock
//    is not drawn. It is a per-screen property, not a per-Space one, and it never changes when
//    you switch Spaces. It therefore cannot answer "is the Dock in the way right now".
//
//  Why this exists instead of just observing activeSpaceDidChangeNotification:
//    macOS posts that notification AFTER the Space transition animation completes. Anything that
//    repositions in response to it is, by construction, a frame late — the Island visibly sits at
//    the old offset for the duration of the swipe and then jumps. The Dock's own window leaves the
//    window server's on-screen list DURING the animation, so polling that is the earlier signal.
//
//  Cost: the naive `CGWindowListCopyWindowInfo` scan is ~780 µs. Resolving the Dock's window IDs
//  once and then querying only those with `CGWindowListCreateDescriptionFromArray` is ~104 µs,
//  which is ~0.6% of one core at 60 Hz. Measured on an M-series 14" MBP.
//

import AppKit
import CoreGraphics

@MainActor
final class DockPresenceMonitor {

    static let shared = DockPresenceMonitor()

    /// Poll interval. 60 Hz so the Island tracks the Space-switch animation rather than lagging it.
    private static let interval: DispatchTimeInterval = .milliseconds(16)

    /// Whether the Dock is currently drawn on the active Space.
    private(set) var isDockOnScreen: Bool

    /// Fired on the main actor whenever `isDockOnScreen` flips. Set by IslandPanelController.
    var onChange: ((Bool) -> Void)?

    /// Cached Dock window numbers. Re-resolved if the Dock restarts and its windows change ID.
    private var dockWindowIDs: [CGWindowID]
    private var timer: DispatchSourceTimer?

    private init() {
        dockWindowIDs = Self.resolveDockWindowIDs()
        isDockOnScreen = Self.probe(ids: dockWindowIDs) ?? Self.fullScan()
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.resume()
        timer = t
        Logger.debug("DockPresenceMonitor started — dockOnScreen=\(isDockOnScreen)", subsystem: .ui)
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - Polling

    private func tick() {
        var present = Self.probe(ids: dockWindowIDs)

        // `nil` means none of the cached IDs exist any more — the Dock was relaunched (or we
        // never resolved any). Re-resolve and retry once before falling back to the full scan.
        if present == nil {
            dockWindowIDs = Self.resolveDockWindowIDs()
            present = Self.probe(ids: dockWindowIDs) ?? Self.fullScan()
        }

        guard let present, present != isDockOnScreen else { return }
        isDockOnScreen = present
        onChange?(present)
    }

    // MARK: - Window-server queries

    /// Asks about only the cached Dock windows. Returns `nil` when none of them still exist,
    /// which is the signal to re-resolve.
    private static func probe(ids: [CGWindowID]) -> Bool? {
        guard !ids.isEmpty else { return nil }
        var boxed: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &boxed, ids.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              !list.isEmpty else { return nil }
        return list.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
    }

    /// Full window-list scan. Only used to seed the cache and as a last-resort fallback.
    private static func fullScan() -> Bool {
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return true   // assume present so we never tuck the Island under the Dock
        }
        return list.contains { $0[kCGWindowOwnerName as String] as? String == "Dock" }
    }

    private static func resolveDockWindowIDs() -> [CGWindowID] {
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionAll)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap {
            guard $0[kCGWindowOwnerName as String] as? String == "Dock",
                  let number = $0[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return number
        }
    }
}

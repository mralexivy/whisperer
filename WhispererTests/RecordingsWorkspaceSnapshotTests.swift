import XCTest
import SwiftUI
import AppKit
@testable import whisperer

/// Opt-in: renders the unified workspace on the real library (`TEST_RUNNER_RECORDINGS_DIR=<folder>`).
@MainActor
final class RecordingsWorkspaceSnapshotTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func pump(_ seconds: Double, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }

    func testRenderWorkspace() throws {
        guard let dir = ProcessInfo.processInfo.environment["RECORDINGS_DIR"] else { throw XCTSkip("set TEST_RUNNER_RECORDINGS_DIR") }
        let model = RecordingsWorkspaceModel.shared
        let host = NSHostingView(rootView: RecordingsWorkspaceView().frame(width: 1320, height: 820))
        host.frame = NSRect(x: 0, y: 0, width: 1320, height: 820)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        Self.keepAlive += [window, host]
        pump(6) { !model.items.isEmpty }

        func shot(_ name: String, kind: RecordingKind?, wait: Double = 4) throws {
            if let kind, let item = model.items.first(where: { $0.kind == kind }) { model.open(item.id) }
            pump(wait)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        try shot("1-first", kind: nil)
        try shot("2-dictation", kind: .dictation)
        try shot("3-meeting", kind: .meeting, wait: 6)
        try shot("4-file", kind: .file)
        UserDefaults.standard.set(false, forKey: "recordings.sidebarVisible")
        try shot("5-compact", kind: .dictation, wait: 3)
        UserDefaults.standard.removeObject(forKey: "recordings.sidebarVisible")
        print("RECORDINGS items=\(model.items.count) selected=\(String(describing: model.selectedID?.key))")
    }
}

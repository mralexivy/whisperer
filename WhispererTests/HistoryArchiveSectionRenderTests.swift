//
//  HistoryArchiveSectionRenderTests.swift
//  WhispererTests
//
//  Renders the real settings card in each state to PNGs (opt-in) and checks the states themselves.
//
//    TEST_RUNNER_RENDER_DIR=<folder>
//

import XCTest
import SwiftUI
import AppKit
@testable import whisperer

@MainActor
final class HistoryArchiveSectionRenderTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    func testRendersEveryState() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set TEST_RUNNER_RENDER_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, HistoryArchiveModel.State)] = [
            ("idle", .idle),
            ("working", .working(phase: "Compressing", fraction: 0.6)),
            ("finished", .finished("Exported 62 transcriptions and 8 meetings (2.4 MB).")),
            ("failed", .failed("This file is not a Whisperer history archive.")),
        ]
        for scheme in [ColorScheme.dark, .light] {
            for (name, state) in states {
                let model = HistoryArchiveModel()
                model.state = state
                Self.keepAlive.append(model)
                let view = HistoryArchiveSection(colorScheme: scheme, model: model)
                    .padding(24)
                    .frame(width: 720)
                    .background(WhispererColors.background(scheme))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 720, height: 10)
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(scheme == .dark ? "dark" : "light")-\(name).png"))
                Self.keepAlive.append(window)
            }
        }
    }

    func testBusyModelRefusesASecondOperation() {
        let model = HistoryArchiveModel()
        Self.keepAlive.append(model)
        model.state = .working(phase: "Compressing", fraction: 0.5)
        XCTAssertTrue(model.isBusy)
        model.state = .finished("done")
        XCTAssertFalse(model.isBusy)
    }
}

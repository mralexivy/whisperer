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

    private func render(_ model: HistoryArchiveModel, scheme: ColorScheme, name: String, dir: String) throws {
        Self.keepAlive.append(model)
        let view = HistoryArchiveSection(colorScheme: scheme, model: model)
            .padding(24)
            .frame(width: 760)
            .background(WhispererColors.background(scheme))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 10)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        Self.keepAlive.append(window)
    }

    func testRendersEveryState() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set TEST_RUNNER_RENDER_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func estimate(parts: Int) -> HistoryArchive.Estimate {
            var e = HistoryArchive.Estimate()
            e.counts = [.dictations: 1_240, .meetings: 86, .dictionary: 312, .commandChats: 12, .statistics: 1]
            e.audioBytes = 3_400_000_000; e.textBytes = 18_000_000; e.audioFiles = 1_326; e.parts = parts
            return e
        }
        let idle = HistoryArchiveModel(); try render(idle, scheme: .dark, name: "idle", dir: dir)

        let export = HistoryArchiveModel(); export.panel = .export
        export.setEstimateForTesting(estimate(parts: 1)); try render(export, scheme: .dark, name: "export", dir: dir)

        let split = HistoryArchiveModel(); split.panel = .export; split.split = .gb1; split.range = .custom
        split.setEstimateForTesting(estimate(parts: 4)); try render(split, scheme: .dark, name: "export-split-custom", dir: dir)

        let working = HistoryArchiveModel(); working.panel = .export
        working.setEstimateForTesting(estimate(parts: 4))
        working.state = .working(phase: "Part 2 of 4", fraction: 0.41, detail: "Dictations 380 of 620"); try render(working, scheme: .dark, name: "export-working", dir: dir)

        let done = HistoryArchiveModel()
        done.state = .finished(lines: ["Exported 1,240 dictations, 86 meetings, 312 dictionary words.", "3.4 GB in 4 files. Copy them all to your other Mac and choose Import history there — in any order."],
                               revealing: [URL(fileURLWithPath: "/tmp/x.aar")]); try render(done, scheme: .dark, name: "export-done", dir: dir)

        let cloud = HistoryArchiveModel(); cloud.panel = .cloud; try render(cloud, scheme: .dark, name: "cloud", dir: dir)

        let pick = HistoryArchiveModel(); pick.panel = .import; try render(pick, scheme: .dark, name: "import-empty", dir: dir)

        let files = HistoryArchiveModel(); files.panel = .import
        func manifest(part: Int) -> HistoryArchive.Manifest {
            .init(format: 2, app: "Whisperer", appVersion: "2.0", createdAt: Date(), device: "Alex’s MacBook Pro",
                  setID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, part: part, parts: 4,
                  counts: ["dictations": 310, "meetings": 21, "dictionary": part == 1 ? 312 : 0, "statistics": part == 1 ? 1 : 0],
                  includesAudio: true, audioFiles: 331, audioBytes: 850_000_000, unpackedBytes: 860_000_000, entryCount: 340,
                  oldest: Date(timeIntervalSinceNow: -86_400 * 200), newest: Date(timeIntervalSinceNow: -86_400 * 120))
        }
        files.setFilesForTesting([
            .init(url: URL(fileURLWithPath: "/tmp/Whisperer History 2026-11-12 – part 1 of 4.aar"), manifest: manifest(part: 1), error: nil),
            .init(url: URL(fileURLWithPath: "/tmp/Whisperer History 2026-11-12 – part 2 of 4.aar"), manifest: manifest(part: 2), error: nil),
            .init(url: URL(fileURLWithPath: "/tmp/notes.aar"), manifest: nil, error: "This file is not a Whisperer history archive."),
        ])
        try render(files, scheme: .dark, name: "import-files", dir: dir)

        let importDone = HistoryArchiveModel()
        importDone.state = .finished(lines: ["Added 620 dictations, 42 meetings, 312 dictionary words.", "18 items were already here and were left as they are.", "Records such as your best streak were kept at the higher value."], revealing: [])
        try render(importDone, scheme: .dark, name: "import-done", dir: dir)

        let failed = HistoryArchiveModel()
        failed.state = .failed("Not enough free space: this needs about 4.2 GB and 1.1 GB is available. Free some space, or export in smaller parts.")
        try render(failed, scheme: .dark, name: "failed", dir: dir)
    }

    func testBusyModelRefusesASecondOperation() {
        let model = HistoryArchiveModel()
        Self.keepAlive.append(model)
        model.state = .working(phase: "Compressing", fraction: 0.5, detail: nil)
        XCTAssertTrue(model.isBusy)
        model.state = .finished(lines: ["done"], revealing: [])
        XCTAssertFalse(model.isBusy)
    }
}

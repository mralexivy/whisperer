//
//  StorageUsageTests.swift
//  WhispererTests
//
//  The measurement (what is filed under which kind, sizes on disk), the bar geometry, and the
//  section rendered in each state.
//

import XCTest
import SwiftUI
import AppKit
@testable import whisperer

@MainActor
final class StorageUsageTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    // MARK: Classification

    func testTheLibraryIsFiledByKind() {
        let c = StorageUsage.classifyLibrary
        XCTAssertEqual(c("Recordings/2026-11-01_hello.opus"), .dictationRecordings)
        XCTAssertEqual(c("Recordings/Meetings/ABC.opus"), .meetingRecordings)
        XCTAssertEqual(c("Sessions/live.caf"), .meetingRecordings)
        XCTAssertEqual(c("Meetings/ABC.m4a"), .meetingRecordings)
        XCTAssertEqual(c("Meetings/ABC-chat.json"), .transcripts)
        XCTAssertEqual(c("history.sqlite"), .transcripts)
        XCTAssertEqual(c("history.sqlite-wal"), .transcripts)
        XCTAssertEqual(c("ChatHistory/sessions.json"), .transcripts)
        XCTAssertEqual(c("ggml-large-v3-turbo-q5_0.bin"), .models)
        XCTAssertEqual(c("PolishModel/weights.safetensors"), .models)
        XCTAssertEqual(c("whisperkit/models/x/y.mlmodelc/weights"), .models)
        XCTAssertEqual(c("AppIcons/a.png"), .caches)
    }

    func testScanCountsAllocatedBytesAndFilesPerKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Storage-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for dir in ["Recordings/Meetings", "Meetings", "PolishModel"] { try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        try Data(count: 300_000).write(to: root.appendingPathComponent("Recordings/a.opus"))
        try Data(count: 100_000).write(to: root.appendingPathComponent("Recordings/b.opus"))
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("Recordings/Meetings/m.opus"))
        try Data(count: 10_000).write(to: root.appendingPathComponent("history.sqlite"))
        try Data(count: 5_000_000).write(to: root.appendingPathComponent("PolishModel/w.safetensors"))
        let breakdown = StorageUsage.scan([.init(root: root, classify: StorageUsage.classifyLibrary)])

        XCTAssertEqual(breakdown.slice(.dictationRecordings).files, 2)
        XCTAssertEqual(breakdown.slice(.meetingRecordings).files, 1)
        XCTAssertGreaterThanOrEqual(breakdown.slice(.dictationRecordings).bytes, 400_000, "allocated size is never below the length")
        XCTAssertLessThan(breakdown.slice(.dictationRecordings).bytes, 400_000 + 2 * 65_536)
        XCTAssertGreaterThanOrEqual(breakdown.slice(.models).bytes, 5_000_000)
        XCTAssertEqual(breakdown.slice(.caches).bytes, 0)
        XCTAssertEqual(breakdown.total, breakdown.slices.reduce(0) { $0 + $1.bytes })
        XCTAssertGreaterThan(breakdown.diskTotal, breakdown.diskAvailable)
        XCTAssertGreaterThanOrEqual(breakdown.otherUsed, 0)
    }

    func testScanOfAMissingFolderIsEmptyNotAnError() {
        let b = StorageUsage.scan([.init(root: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), classify: { _ in .caches })])
        XCTAssertEqual(b.total, 0)
    }

    func testScanOfTheRealLibraryIsFastAndConsistent() {
        let started = Date()
        let b = StorageUsage.scan()
        let ms = Date().timeIntervalSince(started) * 1000
        print("[Storage] real library: \(b.slices.map { "\($0.category.rawValue)=\(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))/\($0.files)f" }.joined(separator: " ")); disk \(b.diskName ?? "?") \(ByteCountFormatter.string(fromByteCount: b.diskTotal, countStyle: .file)); \(Int(ms)) ms")
        XCTAssertLessThan(ms, 5_000)
        XCTAssertLessThanOrEqual(b.total, b.diskTotal)
    }

    // MARK: Geometry

    func testBarWidthsFillTheWidthAndKeepThinSlicesVisible() {
        let values: [Int64] = [3_000_000_000, 40_000_000, 0, 1_500_000_000, 900_000]
        let widths = StorageUsage.widths(for: values, width: 600, spacing: 3, minimum: 8)
        XCTAssertEqual(widths[2], 0, "an empty kind takes no room")
        XCTAssertGreaterThanOrEqual(widths[1], 8)
        XCTAssertGreaterThanOrEqual(widths[4], 8)
        let drawn = widths.filter { $0 > 0 }
        XCTAssertEqual(drawn.reduce(0, +) + 3 * CGFloat(drawn.count - 1), 600, accuracy: 0.01)
        XCTAssertGreaterThan(widths[0], widths[3], "bigger stays bigger")
    }

    func testBarWidthsOfOneSliceFillEverything() {
        XCTAssertEqual(StorageUsage.widths(for: [0, 5, 0], width: 300, spacing: 3, minimum: 8), [0, 300, 0])
        XCTAssertEqual(StorageUsage.widths(for: [0, 0], width: 300, spacing: 3, minimum: 8), [0, 0])
    }

    // MARK: Rendering

    private func render(_ model: StorageUsageModel, name: String, dir: String, hover: StorageCategory? = nil) throws {
        Self.keepAlive.append(model)
        let view = StorageUsageSection(colorScheme: .dark, model: model).padding(24).frame(width: 760)
            .background(WhispererColors.background(.dark)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 10)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        // Let the segments draw in before the picture is taken.
        let until = Date().addingTimeInterval(1.2)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        Self.keepAlive.append(window)
    }

    func testRendersTheSectionInEachState() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set TEST_RUNNER_RENDER_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func breakdown(_ gb: [Double], total: Double = 494, free: Double = 212) -> StorageBreakdown {
            let slices = zip(StorageCategory.allCases, gb).map { StorageSlice(category: $0, bytes: Int64($1 * 1_000_000_000), files: Int($1 * 400)) }
            return StorageBreakdown(slices: slices, diskName: "Macintosh HD", diskTotal: Int64(total * 1e9), diskAvailable: Int64(free * 1e9))
        }
        let heavy = StorageUsageModel(); heavy.setForTesting(breakdown([2.1, 0.9, 0.05, 3.9, 0.6])); try render(heavy, name: "storage-heavy", dir: dir)
        let light = StorageUsageModel(); light.setForTesting(breakdown([0.0, 0.004, 0.0005, 0.55, 0.02])); try render(light, name: "storage-light", dir: dir)
        let scanning = StorageUsageModel(); scanning.setForTesting(.empty, scanning: true, scanned: false); try render(scanning, name: "storage-scanning", dir: dir)
        let tight = StorageUsageModel(); tight.setForTesting(breakdown([6.2, 3.1, 0.3, 5.4, 1.2], total: 256, free: 9)); try render(tight, name: "storage-tight", dir: dir)
    }
}

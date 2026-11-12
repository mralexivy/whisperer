//
//  HistoryArchiveSectionClickTests.swift
//  WhispererTests
//
//  The Move History card, clicked with real mouse events in a real window (the LLM page pattern),
//  and the model driven end to end without the file panels: export → pick the file → import.
//

import AppKit
import SwiftUI
import CoreData
import XCTest
@testable import whisperer

@MainActor
final class HistoryArchiveSectionClickTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private var window: NSWindow!
    private var model: HistoryArchiveModel!

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func host(_ model: HistoryArchiveModel) {
        let hosting = NSHostingView(rootView: HistoryArchiveSection(colorScheme: .dark, model: model).padding(24).frame(width: 800))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 800, height: 1800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.setFrame(CGRect(x: 40, y: 40, width: 800, height: 1800), display: true)
        self.window = window; self.model = model
        Self.keepAlive += [model, hosting, window]
        pump(0.5)
    }

    private func frame(_ id: String) -> CGRect? { UITestFrames.frames[UITestFrames.key(scope: "transfer", id: id)] }

    private func click(_ id: String, x: CGFloat = 0.5, y: CGFloat = 0.5, file: StaticString = #filePath, line: UInt = #line) throws {
        pump(0.4)
        guard let f = frame(id) else {
            XCTFail("no frame for \(id); have \(UITestFrames.frames.keys.filter { $0.hasPrefix("transfer") }.sorted())", file: file, line: line)
            return
        }
        let height = window.contentView?.bounds.height ?? 0
        let point = NSPoint(x: f.minX + f.width * x, y: height - (f.minY + f.height * y))
        for (type, hold) in [(NSEvent.EventType.mouseMoved, 0.15), (.leftMouseDown, 0.2), (.leftMouseUp, 0.05)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            pump(hold)
        }
        pump(0.5)
    }

    // MARK: - Clicks

    func testClickingTheRowsUnfoldsEachPanelInPlace() throws {
        host(HistoryArchiveModel())
        XCTAssertEqual(model.panel, .none)
        try click("transfer.row.export", x: 0.3)
        XCTAssertEqual(model.panel, .export)
        XCTAssertNotNil(frame("transfer.export.run"), "the export panel unfolds under its row")
        try click("transfer.row.import", x: 0.3)
        XCTAssertEqual(model.panel, .import, "one panel at a time")
        XCTAssertNotNil(frame("transfer.import.choose"), "an empty import offers the picker")
        try click("transfer.row.import", x: 0.3)
        XCTAssertEqual(model.panel, .none, "clicking the open row folds it")
    }

    func testClickingTheChipsChangesTheScope() throws {
        host(HistoryArchiveModel())
        try click("transfer.row.export", x: 0.3)
        try click("transfer.split.1 GB parts")
        XCTAssertEqual(model.split, .gb1)
        XCTAssertEqual(model.exportOptions.maxPartBytes, 1_000_000_000)
        try click("transfer.range.Past 30 days")
        XCTAssertEqual(model.range, .last30)
        XCTAssertNotNil(model.exportOptions.from)
        try click("transfer.range.Custom")
        XCTAssertEqual(model.range, .custom)
        XCTAssertNotNil(model.exportOptions.to)
        try click("transfer.range.All time")
        XCTAssertNil(model.exportOptions.from)
    }

    func testTurningACategoryOffReachesTheOptionsAndAnEmptySelectionDisablesExport() throws {
        host(HistoryArchiveModel())
        try click("transfer.row.export", x: 0.3)
        XCTAssertTrue(model.exportOptions.categories.contains(.meetings))
        try click("transfer.export.category.meetings", x: 0.97)           // the switch sits at the right edge
        XCTAssertFalse(model.categories.contains(.meetings))
        model.categories = []
        pump(0.4)
        XCTAssertTrue(model.exportOptions.categories.isEmpty)
        XCTAssertNil(model.estimate, "nothing selected, nothing to count")
    }

    // MARK: - Model, end to end

    /// Yields the main actor (the test body holds it; a nested run loop would not let the model's own
    /// tasks run) until `done` or the deadline.
    private func wait(seconds: Double = 15, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func library(_ name: String) throws -> (env: HistoryArchive.Environment, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveModel-\(name)-\(UUID().uuidString)")
        let rec = root.appendingPathComponent("Recordings"), meet = root.appendingPathComponent("Recordings/Meetings")
        let data = root.appendingPathComponent("Meetings"), tmp = root.appendingPathComponent("tmp")
        for d in [rec, meet, data, tmp] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let db = HistoryDatabase(inMemory: true)
        Self.keepAlive.append(db)
        let suite = "ArchiveModel-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (HistoryArchive.Environment(database: db, recordings: rec, meetingRecordings: meet, meetingData: data,
                                           chatHistory: root.appendingPathComponent("ChatHistory"), staging: tmp,
                                           defaults: UserDefaults(suiteName: suite)!, locateMeetingAudio: { _ in nil },
                                           freeSpace: { _ in .max }), root)
    }

    func testExportThenPickTheFileThenImport() async throws {
        let a = try library("a"), b = try library("b")
        let ctx = a.env.database.newBackgroundContext()
        try await ctx.perform {
            for i in 0..<25 {
                let e = TranscriptionEntity(context: ctx)
                e.id = UUID(); e.timestamp = Date(timeIntervalSince1970: 1_790_000_000 + Double(i)); e.createdAt = e.timestamp
                e.lastModifiedAt = e.timestamp; e.transcription = "hello \(i)"; e.language = "en"; e.modelUsed = "V3"; e.wordCount = 2
            }
            try ctx.save()
        }
        let source = HistoryArchiveModel(environment: a.env)
        Self.keepAlive.append(source)
        let target = a.root.appendingPathComponent("moved.aar")
        source.startExport(to: target)
        try await wait { if case .working = source.state { return false } else { return source.state != .idle } }
        guard case .finished(let lines, _) = source.state else { return XCTFail("export did not finish: \(source.state)") }
        XCTAssertTrue(lines[0].contains("25 dictations"), lines[0])

        let dest = HistoryArchiveModel(environment: b.env)
        Self.keepAlive.append(dest)
        await dest.add([target])
        XCTAssertEqual(dest.readableFiles.count, 1)
        XCTAssertEqual(dest.importTotal(.dictations), 25)
        XCTAssertEqual(dest.presentCategories, [.dictations])
        dest.startImport()
        try await wait { if case .working = dest.state { return false } else { return dest.state != .idle } }
        guard case .finished(let result, _) = dest.state else { return XCTFail("import did not finish: \(dest.state)") }
        XCTAssertTrue(result[0].contains("25 dictations"), result[0])
        XCTAssertTrue(dest.files.isEmpty, "the list clears after a successful import")
        let c2 = b.env.database.newBackgroundContext()
        let n = try await c2.perform { try c2.count(for: NSFetchRequest<NSManagedObject>(entityName: "TranscriptionEntity")) }
        XCTAssertEqual(n, 25)
    }

    func testABadFileShowsItsErrorAndCannotBeImported() async throws {
        let b = try library("b")
        let junk = b.root.appendingPathComponent("junk.aar")
        try Data("nope".utf8).write(to: junk)
        let model = HistoryArchiveModel(environment: b.env)
        Self.keepAlive.append(model)
        await model.add([junk])
        XCTAssertEqual(model.files.count, 1)
        XCTAssertNotNil(model.files[0].error)
        XCTAssertTrue(model.readableFiles.isEmpty)
        model.startImport()
        XCTAssertEqual(model.state, .idle, "nothing readable, nothing starts")
    }

    func testCancellingStopsAnExportAndTheModelReturnsToIdle() async throws {
        let a = try library("a")
        let ctx = a.env.database.newBackgroundContext()
        try await ctx.perform {
            for i in 0..<300 {
                let e = TranscriptionEntity(context: ctx)
                e.id = UUID(); e.timestamp = Date(timeIntervalSince1970: 1_790_000_000 + Double(i)); e.createdAt = e.timestamp
                e.lastModifiedAt = e.timestamp; e.transcription = String(repeating: "word ", count: 400); e.language = "en"; e.modelUsed = "V3"; e.wordCount = 400
            }
            try ctx.save()
        }
        let model = HistoryArchiveModel(environment: a.env)
        Self.keepAlive.append(model)
        model.split = .mb250
        model.startExport(to: a.root.appendingPathComponent("never.aar"))
        model.cancel()
        try await wait { !model.isBusy }
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("never.aar").path))
    }
}

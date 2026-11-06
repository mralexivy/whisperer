//
//  ModelDownloadTests.swift
//  WhispererTests
//
//  The per-model download record and the row that shows it. No network: the record is driven
//  through the same calls the downloaders make, and the row is clicked with real mouse events
//  (LLMPageClickTests pattern).
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class ModelDownloadTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private let asset = ModelAsset.whisper(.tiny)
    private let other = ModelAsset.qwen3
    private var scope = ""

    override func tearDown() {
        let app = AppState.shared
        for a in [asset, other] {
            app.cancelDownload(a)
            app.dismissDownloadFailure(a)
        }
        super.tearDown()
    }

    // MARK: - Progress record

    func testFractionIsClampedAndNeverGoesBackwards() {
        var p = ModelDownloadProgress()
        p.update(fraction: 0.4, bytesWritten: nil, bytesExpected: nil, approximateTotal: 1000)
        p.update(fraction: 0.2, bytesWritten: nil, bytesExpected: nil, approximateTotal: 1000)
        XCTAssertEqual(p.fraction, 0.4, "a snapshot re-weighting its total must not move the bar back")
        p.update(fraction: .nan, bytesWritten: nil, bytesExpected: nil, approximateTotal: 1000)
        XCTAssertEqual(p.fraction, 0.4)
        p.update(fraction: 7, bytesWritten: nil, bytesExpected: nil, approximateTotal: 1000)
        XCTAssertEqual(p.fraction, 1)
        XCTAssertEqual(p.phase, .finishing, "all bytes in reads as finishing, not 100% forever")
    }

    func testRetryRestartsTheBarButKeepsTheStartTime() {
        var p = ModelDownloadProgress(startedAt: Date(timeIntervalSince1970: 0))
        p.update(fraction: 0.6, bytesWritten: 600, bytesExpected: 1000, approximateTotal: 1000)
        p.restart(phase: .retrying(attempt: 2, of: 3))
        XCTAssertEqual(p.fraction, 0)
        XCTAssertEqual(p.phase, .retrying(attempt: 2, of: 3))
        XCTAssertEqual(p.startedAt, Date(timeIntervalSince1970: 0))
    }

    func testDetailTextNamesEveryPhase() {
        var p = ModelDownloadProgress()
        XCTAssertEqual(p.detailText(approximateTotal: 1), "Starting download…")
        p.phase = .waitingForNetwork
        XCTAssertEqual(p.detailText(approximateTotal: 1), "Waiting for network…")
        p.phase = .retrying(attempt: 2, of: 3)
        XCTAssertTrue(p.detailText(approximateTotal: 1).contains("2/3"))
        p.phase = .finishing
        XCTAssertEqual(p.detailText(approximateTotal: 1), "Finishing up…")
    }

    func testDetailTextShowsBytesAndTimeLeft() {
        let start = Date()
        var p = ModelDownloadProgress(startedAt: start)
        p.update(fraction: 0.1, bytesWritten: 100_000_000, bytesExpected: 1_000_000_000,
                 approximateTotal: 1, now: start.addingTimeInterval(10))
        let text = p.detailText(approximateTotal: 1)
        XCTAssertTrue(text.contains("of"), text)
        XCTAssertTrue(text.contains("left"), "10 MB/s for 900 MB leaves a time estimate: \(text)")
    }

    func testRemainingTimeWording() {
        XCTAssertEqual(ModelDownloadProgress.format(remaining: 20), "less than a minute left")
        XCTAssertEqual(ModelDownloadProgress.format(remaining: 300), "about 5 min left")
    }

    // MARK: - Failure wording

    func testFailuresSayWhatToDo() {
        XCTAssertTrue(ModelDownloadFailure.message(for: URLError(.notConnectedToInternet)).contains("internet"))
        XCTAssertTrue(ModelDownloadFailure.message(for: URLError(.timedOut)).contains("timed out"))
        XCTAssertTrue(ModelDownloadFailure.message(
            for: ModelDownloadError.maxRetriesExhausted(lastError: URLError(.networkConnectionLost))).contains("internet"),
                      "the retry wrapper must not hide the real cause")
        XCTAssertTrue(ModelDownloadFailure.isCancellation(CancellationError()))
        XCTAssertTrue(ModelDownloadFailure.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(ModelDownloadFailure.isCancellation(URLError(.timedOut)))
    }

    // MARK: - AppState bookkeeping

    /// Two downloads at once each keep their own progress — the bug behind every "the bar shows
    /// the wrong number" report was a single shared percent.
    func testConcurrentDownloadsKeepTheirOwnProgress() {
        let app = AppState.shared
        app.beginModelDownload(asset)
        app.beginModelDownload(other)
        app.handleTransferEvent(.progress(written: 30, expected: 100), for: asset)
        XCTAssertEqual(app.modelDownloads[asset]?.fraction ?? -1, 0.3, accuracy: 0.001)
        XCTAssertEqual(app.modelDownloads[other]?.fraction, 0, "one model's bytes must not move another's bar")
    }

    func testDownloadsNeverBlockModelSelectionOrRecording() {
        let app = AppState.shared
        let busyBefore = app.isModelBusy
        app.beginModelDownload(asset)
        XCTAssertEqual(app.isModelBusy, busyBefore, "a download must not freeze the Models tab")
        XCTAssertNotEqual(app.state, .downloadingModel(progress: 0))
        if case .downloadingModel = app.state { XCTFail("a download must never block dictation") }
    }

    func testFailureIsKeptUntilRetryAndCancelIsSilent() {
        let app = AppState.shared
        app.beginModelDownload(asset)
        app.finishModelDownload(asset, error: URLError(.notConnectedToInternet))
        XCTAssertNil(app.modelDownloads[asset])
        XCTAssertNotNil(app.modelDownloadFailures[asset])

        app.beginModelDownload(asset)
        XCTAssertNil(app.modelDownloadFailures[asset], "retrying clears the old failure")
        app.cancelDownload(asset)
        app.finishModelDownload(asset, error: URLError(.cancelled))
        XCTAssertNil(app.modelDownloads[asset])
        XCTAssertNil(app.modelDownloadFailures[asset], "the user's own cancel is not a failure")
    }

    func testNetworkWaitAndRetryShowInTheRecord() {
        let app = AppState.shared
        app.beginModelDownload(asset)
        app.handleTransferEvent(.waitingForNetwork, for: asset)
        XCTAssertEqual(app.modelDownloads[asset]?.phase, .waitingForNetwork)
        app.handleTransferEvent(.progress(written: 10, expected: 100), for: asset)
        XCTAssertEqual(app.modelDownloads[asset]?.phase, .downloading, "bytes flowing again clears the wait")
        app.handleTransferEvent(.retrying(attempt: 2, of: 3), for: asset)
        XCTAssertEqual(app.modelDownloads[asset]?.phase, .retrying(attempt: 2, of: 3))
    }

    /// Late progress from a cancelled download must not bring its row back.
    func testProgressAfterCancelIsIgnored() {
        let app = AppState.shared
        app.beginModelDownload(asset)
        app.cancelDownload(asset)
        app.handleTransferEvent(.progress(written: 50, expected: 100), for: asset)
        XCTAssertNil(app.modelDownloads[asset])
    }

    func testEverySelectableEngineMapsToItsOwnAsset() {
        let app = AppState.shared
        let saved = app.selectedBackendType
        defer { app.selectedBackendType = saved }
        app.selectedBackendType = .qwen3asr
        XCTAssertEqual(app.selectedEngineAsset, .qwen3)
        app.selectedBackendType = .parakeet
        XCTAssertEqual(app.selectedEngineAsset, .parakeet(app.selectedParakeetModel))
        app.selectedBackendType = .whisperKit
        XCTAssertEqual(app.selectedEngineAsset, .whisperKit,
                       "WhisperKit users used to be handed the Whisper file's state")
        app.selectedBackendType = .whisperCpp
        XCTAssertEqual(app.selectedEngineAsset, .whisper(app.selectedModel))
    }

    // MARK: - Row, clicked with real mouse events

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func hostRow() -> NSWindow {
        scope = "modelrow-\(UUID().uuidString)"
        let view = ModelMenuItem(model: .tiny)
            .frame(width: 360)
            .padding(20)
            .environment(\.uiTestScope, scope)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 400, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.setFrame(CGRect(x: 40, y: 40, width: 400, height: 160), display: true)
        Self.keepAlive += [hosting, window]
        pump(0.4)
        return window
    }

    private func frame(_ id: String, in window: NSWindow) -> CGRect? {
        UITestFrames.frames[UITestFrames.key(scope: scope, id: id)]
    }

    private func click(_ id: String, in window: NSWindow) throws {
        pump(0.4)
        let f = try XCTUnwrap(frame(id, in: window),
                              "no frame for \(id); have \(UITestFrames.frames.keys.filter { $0.contains("model.") }.sorted())")
        let height = window.contentView?.bounds.height ?? 0
        let point = NSPoint(x: f.midX, y: height - f.midY)
        for (type, hold) in [(NSEvent.EventType.mouseMoved, 0.15), (.leftMouseDown, 0.2), (.leftMouseUp, 0.05)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            pump(hold)
        }
        pump(0.4)
    }

    /// Cancel is a sibling of the row's button, so clicking it cancels — it used to sit inside
    /// the row's own button.
    func testClickingCancelStopsTheDownload() throws {
        let app = AppState.shared
        app.beginModelDownload(asset)
        app.handleTransferEvent(.progress(written: 40, expected: 100), for: asset)
        let window = hostRow()
        try click("model.\(asset.testID).cancel", in: window)
        XCTAssertNil(app.modelDownloads[asset], "clicking Cancel ends the download")
        XCTAssertNil(app.modelDownloadFailures[asset])
        window.orderOut(nil)
    }

    func testFailedDownloadOffersRetryInTheRow() {
        let app = AppState.shared
        app.beginModelDownload(asset)
        app.finishModelDownload(asset, error: URLError(.timedOut))
        let window = hostRow()
        pump(0.3)
        XCTAssertNotNil(frame("model.\(asset.testID).retry", in: window), "a failure shows Retry on its own row")
        XCTAssertNil(frame("model.\(asset.testID).cancel", in: window))
        window.orderOut(nil)
    }
}

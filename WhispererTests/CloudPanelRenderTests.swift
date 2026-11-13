//
//  CloudPanelRenderTests.swift
//  WhispererTests
//
//  Renders the real Move History card with the Cloud panel open, once per account state, to PNGs (opt-in):
//
//    TEST_RUNNER_RENDER_DIR=<folder>
//
//  The plan picker is a stand-in (Apple's SubscriptionStoreView cannot load products in a test).
//

import XCTest
import SwiftUI
import AppKit
@testable import whisperer

@MainActor
final class CloudPanelRenderTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func render(_ name: String, dir: String, state: CloudAccountState, info: CloudAccountInfo? = nil, pending: Bool = false,
                        sync: CloudSyncStatus = .idle, pendingChanges: Int = 0, lastSynced: Date? = nil, advancedOpen: Bool = false,
                        resubscribe: Bool = false, keyConfirmed: Bool = false, keyEntry: String = "") throws {
        let account = StubCloudAccount(state: state, info: info)
        account.isPurchasePending = pending
        let source = RenderSyncSource(status: sync, pending: pendingChanges, last: lastSynced)
        let recorder = PanelRecorder()
        let model = CloudPanelModel(account: account, sync: source, environment: recorder.environment(for: account))
        model.advancedOpen = advancedOpen
        model.showsPlans = resubscribe
        model.keyConfirmed = keyConfirmed
        model.keyEntry = keyEntry
        let archive = HistoryArchiveModel()
        archive.panel = .cloud
        Self.keepAlive += [account, source, recorder, model, archive]

        let view = HistoryArchiveSection(colorScheme: .dark, model: archive, cloudModel: model)
            .padding(24).frame(width: 760)
            .background(WhispererColors.background(.dark))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 10)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 2600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 2600)
        let until = Date().addingTimeInterval(0.8)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        let size = NSSize(width: 760, height: host.fittingSize.height)
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        Self.keepAlive += [host, window]
    }

    func testRendersEveryState() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("set TEST_RUNNER_RENDER_DIR") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        CloudFeature.testOverride = true
        defer { CloudFeature.testOverride = nil }
        let now = CloudPanelFixtures.now
        let info = CloudPanelFixtures.info()

        try render("01-intro", dir: dir, state: .notSubscribed)
        try render("02-awaiting-approval", dir: dir, state: .notSubscribed, pending: true)
        try render("03-purchasing", dir: dir, state: .purchasing)
        try render("04-creating-account", dir: dir, state: .creatingAccount)
        try render("05-creating-library", dir: dir, state: .creatingLibrary)
        try render("06-confirming", dir: dir, state: .confirming)
        try render("07-resetting", dir: dir, state: .resetting)
        try render("08-offer-key", dir: dir, state: .offerRecoveryKey)
        try render("09-show-key", dir: dir, state: .showRecoveryKey(StubCloudAccount.sampleKey))
        try render("10-show-key-confirmed", dir: dir, state: .showRecoveryKey(StubCloudAccount.sampleKey), keyConfirmed: true)
        try render("11-ready", dir: dir, state: .ready, info: info, lastSynced: now.addingTimeInterval(-240))
        try render("12-ready-syncing", dir: dir, state: .ready, info: info, sync: .syncing(progress: 0.42), pendingChanges: 318, lastSynced: nil)
        try render("13-ready-paused", dir: dir, state: .ready, info: CloudPanelFixtures.info(autoRenew: false, recovery: false), sync: .paused, pendingChanges: 12, lastSynced: now.addingTimeInterval(-7_200))
        try render("14-ready-over-quota", dir: dir, state: .ready, info: CloudPanelFixtures.info(storedGB: 26.8), sync: .overQuota, pendingChanges: 40, lastSynced: now.addingTimeInterval(-86_400))
        try render("15-ready-offline-advanced", dir: dir, state: .ready, info: CloudPanelFixtures.info(storedGB: 23.1), sync: .offline, pendingChanges: 3, lastSynced: now.addingTimeInterval(-3_600), advancedOpen: true)
        try render("16-ready-error", dir: dir, state: .ready, info: info, sync: .error("The server did not answer. It will try again shortly."), lastSynced: now.addingTimeInterval(-600))
        try render("17-ready-loading", dir: dir, state: .ready, info: nil)
        let lapsed = CloudPanelFixtures.info(state: .lapsed, deleteAfter: now.addingTimeInterval(52 * 86_400))
        try render("20-readonly-expired", dir: dir, state: .readOnly(.expired), info: lapsed)
        try render("21-readonly-expired-resubscribe", dir: dir, state: .readOnly(.expired), info: lapsed, resubscribe: true)
        try render("22-readonly-payment-retry", dir: dir, state: .readOnly(.paymentRetry), info: CloudPanelFixtures.info(state: .grace))
        try render("23-readonly-refunded", dir: dir, state: .readOnly(.refunded), info: lapsed)
        try render("24-readonly-sealed", dir: dir, state: .readOnly(.sealed), info: CloudPanelFixtures.info(state: .sealed, deleteAfter: now.addingTimeInterval(9 * 86_400)))
        try render("25-readonly-removed", dir: dir, state: .readOnly(.removed), info: nil)
        try render("26-readonly-over-quota", dir: dir, state: .readOnly(.expired), info: CloudPanelFixtures.info(storedGB: 27.5, state: .lapsed, deleteAfter: now.addingTimeInterval(20 * 86_400)))
        try render("30-enrol-pending", dir: dir, state: .enrolPending)
        try render("31-needs-key", dir: dir, state: .needsKey(CloudNeedsKey(recoveryAvailable: true)))
        try render("32-needs-key-typing", dir: dir, state: .needsKey(CloudNeedsKey(recoveryAvailable: true)), keyEntry: "5Z7B-2K9D-QQ3M")
        try render("33-needs-key-wrong-recovery", dir: dir, state: .needsKey(CloudNeedsKey(recoveryAvailable: true, wrongRecoveryKey: true)), keyEntry: "5Z7B-2K9D-QQ3M")
        try render("34-needs-key-wrong-key-no-recovery", dir: dir, state: .needsKey(CloudNeedsKey(recoveryAvailable: false, wrongKey: true)), advancedOpen: true)
        try render("40-device-revoked", dir: dir, state: .deviceRevoked)
        let problems: [(String, CloudAccountProblem)] = [("offline", .offline), ("device-limit", .deviceLimit), ("too-many-pending", .tooManyPending),
            ("rate-limited", .rateLimited(retryAfter: 240)), ("wrong-product", .wrongProduct), ("keychain", .keychain), ("server", .server(code: "internal_error"))]
        for (i, item) in problems.enumerated() { try render("5\(i)-unavailable-\(item.0)", dir: dir, state: .unavailable(item.1)) }
    }
}

@MainActor
final class RenderSyncSource: CloudSyncStatusSource {
    @Published var status: CloudSyncStatus
    let lastSyncedAt: Date?
    let pendingChanges: Int
    init(status: CloudSyncStatus, pending: Int, last: Date?) { self.status = status; pendingChanges = pending; lastSyncedAt = last }
    func pause() { status = .paused }
    func resume() { status = .idle }
    func syncNow() async {}
}

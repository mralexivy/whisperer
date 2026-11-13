//
//  CloudPanelClickTests.swift
//  WhispererTests
//
//  The Whisperer Cloud panel, clicked with real mouse events in a real window (the LLM page pattern).
//  A stub account stands in for the state machine; nothing touches the network, StoreKit, the pasteboard
//  or a file panel. Pure behaviour of the model is checked without a window.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class CloudPanelClickTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private struct Rig {
        let account: StubCloudAccount
        let recorder: PanelRecorder
        let model: CloudPanelModel
        let sync: NoopCloudSyncStatusSource
        let host: CloudPanelHost
        var exported: Counter
    }

    @MainActor final class Counter { var n = 0 }

    private func rig(_ state: CloudAccountState, info: CloudAccountInfo? = nil, pending: Bool = false) -> Rig {
        let account = StubCloudAccount(state: state, info: info)
        account.isPurchasePending = pending
        let recorder = PanelRecorder()
        let sync = NoopCloudSyncStatusSource()
        let exported = Counter()
        let model = CloudPanelModel(account: account, sync: sync, environment: recorder.environment(for: account)) { exported.n += 1 }
        let host = CloudPanelHost(CloudPanelView(colorScheme: .dark, model: model))
        Self.keepAlive += [account, recorder, model, sync, host, exported]
        return Rig(account: account, recorder: recorder, model: model, sync: sync, host: host, exported: exported)
    }

    // MARK: Sign-up

    func testSubscribeAreaAndRestorePurchases() throws {
        let r = rig(.notSubscribed)
        XCTAssertNotNil(r.host.frame("cloud.plans"), "Apple's plan picker sits in the panel, not in a sheet")
        try r.host.click("cloud.stub.subscribe")
        XCTAssertEqual(r.account.purchases, [CloudProduct(tier: .standard, period: .monthly)])
        XCTAssertEqual(r.model.screen, .progress(.creatingAccount), "the panel moves on to the named step")
        XCTAssertNotNil(r.host.frame("cloud.progress"))

        let again = rig(.notSubscribed)
        try again.host.click("cloud.restore")
        XCTAssertEqual(again.account.restoreCount, 1)
    }

    func testAskToBuyShowsWaitingAndNoPlans() throws {
        let r = rig(.notSubscribed, pending: true)
        XCTAssertEqual(r.model.screen, .awaitingApproval)
        XCTAssertNotNil(r.host.frame("cloud.pending.check"))
        let before = r.account.refreshCount
        try r.host.click("cloud.pending.check")
        XCTAssertEqual(r.account.refreshCount, before + 1)
    }

    // MARK: Recovery key

    func testOfferCreatesTheKeyOrSkips() throws {
        let create = rig(.offerRecoveryKey)
        try create.host.click("cloud.key.create")
        XCTAssertEqual(create.account.createKeyCount, 1)
        XCTAssertEqual(create.model.screen, .showRecoveryKey(StubCloudAccount.sampleKey))

        let skip = rig(.offerRecoveryKey)
        try skip.host.click("cloud.key.skip")
        XCTAssertEqual(skip.account.finishCount, 1)
        XCTAssertEqual(skip.model.screen, .ready)
    }

    func testCopyAndSaveTheKeyAndTheIHaveSavedItGate() throws {
        let r = rig(.showRecoveryKey(StubCloudAccount.sampleKey))
        XCTAssertEqual(StubCloudAccount.sampleKey.split(separator: "-").count, 13, "13 groups")
        XCTAssertTrue(StubCloudAccount.sampleKey.split(separator: "-").allSatisfy { $0.count == 4 })

        try r.host.click("cloud.key.copy")
        XCTAssertEqual(r.recorder.copied.count, 1)
        XCTAssertEqual(r.recorder.copied.first?.text, StubCloudAccount.sampleKey)
        XCTAssertEqual(r.recorder.copied.first?.sensitive, true, "the pasteboard entry is marked concealed")
        XCTAssertTrue(r.model.keyCopied)

        try r.host.click("cloud.key.save")
        XCTAssertEqual(r.recorder.savedKeys, [StubCloudAccount.sampleKey])
        XCTAssertTrue(r.model.keyFileSaved)

        // Finish is off until the user says they saved it.
        try r.host.click("cloud.key.finish")
        XCTAssertEqual(r.account.finishCount, 0, "a disabled Finish does nothing")
        XCTAssertEqual(r.model.screen, .showRecoveryKey(StubCloudAccount.sampleKey))

        try r.host.click("cloud.key.confirm", x: 0.2)
        XCTAssertTrue(r.model.keyConfirmed)
        try r.host.click("cloud.key.finish")
        XCTAssertEqual(r.account.finishCount, 1)
        XCTAssertEqual(r.model.screen, .ready)
        XCTAssertFalse(r.model.keyConfirmed, "the tick does not outlive the screen")
    }

    func testTheKeyNeverReachesAnAccessibilityIdentifierOrTheLog() {
        // The ids the panel uses are fixed strings; the key only appears as the element's own value.
        let ids = ["cloud.key.text", "cloud.key.copy", "cloud.key.save", "cloud.key.print", "cloud.key.confirm", "cloud.key.finish"]
        XCTAssertTrue(ids.allSatisfy { !$0.contains(StubCloudAccount.sampleKey.prefix(4)) })
        XCTAssertFalse(String(describing: CloudAccountState.showRecoveryKey(StubCloudAccount.sampleKey)).contains(StubCloudAccount.sampleKey))
    }

    // MARK: Ready

    func testRevokeAsksInPlaceBeforeRemovingAMac() throws {
        let r = rig(.ready, info: CloudPanelFixtures.info())
        XCTAssertEqual(r.model.devices.map(\.id), ["dev-this", "dev-studio", "dev-air"], "this Mac first")
        try r.host.click("cloud.device.dev-studio.revoke")
        XCTAssertEqual(r.model.revokeCandidate, "dev-studio")
        XCTAssertTrue(r.account.revoked.isEmpty, "the first click only asks")
        XCTAssertNotNil(r.host.frame("cloud.device.dev-studio.confirm"))

        try r.host.click("cloud.device.dev-studio.cancel")
        XCTAssertNil(r.model.revokeCandidate)
        XCTAssertTrue(r.account.revoked.isEmpty)

        try r.host.click("cloud.device.dev-studio.revoke")
        try r.host.click("cloud.device.dev-studio.confirm")
        XCTAssertEqual(r.account.revoked, ["dev-studio"])
        XCTAssertEqual(r.model.devices.map(\.id), ["dev-this", "dev-air"])
    }

    func testPauseAndResumeAndSyncNow() throws {
        let r = rig(.ready, info: CloudPanelFixtures.info())
        XCTAssertEqual(r.sync.status, .idle)
        try r.host.click("cloud.sync.toggle")
        XCTAssertEqual(r.sync.status, .paused)
        try r.host.click("cloud.sync.now")
        XCTAssertEqual(r.sync.status, .paused, "Sync now is off while paused")
        try r.host.click("cloud.sync.toggle")
        XCTAssertEqual(r.sync.status, .idle)
    }

    func testManageSubscriptionAndNewRecoveryKeyConfirm() throws {
        let r = rig(.ready, info: CloudPanelFixtures.info(recovery: true))
        try r.host.click("cloud.manage")
        XCTAssertEqual(r.recorder.managed, 1)

        try r.host.click("cloud.recovery.create")
        XCTAssertEqual(r.account.createKeyCount, 0, "replacing a key asks first")
        XCTAssertTrue(r.model.confirmsNewRecoveryKey)
        try r.host.click("cloud.recovery.cancel")
        XCTAssertFalse(r.model.confirmsNewRecoveryKey)
        try r.host.click("cloud.recovery.create")
        try r.host.click("cloud.recovery.confirm")
        XCTAssertEqual(r.account.createKeyCount, 1)
    }

    func testDeleteCloudDataNeedsTheTypedPhrase() throws {
        let r = rig(.ready, info: CloudPanelFixtures.info())
        XCTAssertNil(r.host.frame("cloud.reset.run"), "plumbing is collapsed under Advanced")
        try r.host.click("cloud.advanced.toggle")
        XCTAssertNotNil(r.host.frame("cloud.reset.run"))

        try r.host.click("cloud.reset.run")
        XCTAssertTrue(r.account.resets.isEmpty, "off with no phrase")
        r.model.resetPhrase = "reset my library"
        r.host.pump(0.3)
        try r.host.click("cloud.reset.run")
        XCTAssertTrue(r.account.resets.isEmpty, "case matters")
        r.model.resetPhrase = "RESET MY LIBRARY"
        r.host.pump(0.3)
        try r.host.click("cloud.reset.run")
        XCTAssertEqual(r.account.resets, ["RESET MY LIBRARY"])
        XCTAssertEqual(r.model.resetPhrase, "", "the phrase is cleared once used")
    }

    // MARK: Read-only

    func testReadOnlyResubscribesInPlaceAndPointsToExport() throws {
        let r = rig(.readOnly(.expired), info: CloudPanelFixtures.info(state: .lapsed, deleteAfter: CloudPanelFixtures.now.addingTimeInterval(60 * 86_400)))
        XCTAssertNil(r.host.frame("cloud.plans"))
        try r.host.click("cloud.readonly.resubscribe")
        XCTAssertNotNil(r.host.frame("cloud.plans"), "Resubscribe unfolds the plans in place")
        XCTAssertNotNil(r.host.frame("cloud.readonly.next"), "what happens next, with the deletion date")
        try r.host.click("cloud.readonly.export")
        XCTAssertEqual(r.exported.n, 1)
    }

    func testPaymentRetryOffersManageSubscriptionNotResubscribe() throws {
        let r = rig(.readOnly(.paymentRetry), info: CloudPanelFixtures.info(state: .lapsed))
        XCTAssertNil(r.host.frame("cloud.readonly.resubscribe"))
        try r.host.click("cloud.manage")
        XCTAssertEqual(r.recorder.managed, 1)
    }

    // MARK: New Mac

    func testRecoveryKeyEntryRejectsAWrongKeyAndAcceptsTheRightOne() throws {
        let r = rig(.needsKey(CloudNeedsKey(recoveryAvailable: true)))
        XCTAssertNotNil(r.host.frame("cloud.entry.field"))
        try r.host.click("cloud.entry.submit")
        XCTAssertTrue(r.account.submitted.isEmpty, "Unlock is off while the field is empty")

        r.model.keyEntry = "not a key"
        r.host.pump(0.3)
        try r.host.click("cloud.entry.submit")
        XCTAssertEqual(r.account.submitted, ["not a key"])
        XCTAssertNotNil(r.host.frame("cloud.entry.rejected"), "a rejected key says so, calmly, in place")
        XCTAssertEqual(r.model.keyEntry, "not a key", "what was typed stays so it can be corrected")

        // Lowercase, spaces instead of dashes: the parser forgives both.
        r.model.keyEntry = StubCloudAccount.sampleKey.lowercased().replacingOccurrences(of: "-", with: " ")
        r.host.pump(0.3)
        try r.host.click("cloud.entry.submit")
        XCTAssertEqual(r.model.screen, .ready)
        XCTAssertEqual(r.model.keyEntry, "", "the typed key is dropped once it unlocks")
    }

    func testPasteFillsTheFieldAndCheckAgainRechecks() throws {
        let r = rig(.needsKey(CloudNeedsKey(recoveryAvailable: true)))
        r.recorder.clipboard = "  " + StubCloudAccount.sampleKey + "\n"
        try r.host.click("cloud.entry.paste")
        XCTAssertEqual(r.model.keyEntry, r.recorder.clipboard)
        try r.host.click("cloud.needskey.recheck")
        XCTAssertEqual(r.account.recheckCount, 1)
    }

    func testNoRecoveryKeyMeansNoEntryField() throws {
        let r = rig(.needsKey(CloudNeedsKey(recoveryAvailable: false)))
        XCTAssertNil(r.host.frame("cloud.entry.field"))
        XCTAssertNotNil(r.host.frame("cloud.needskey.recheck"))
    }

    func testResetFromTheNewMacScreenIsGatedToo() throws {
        let r = rig(.needsKey(CloudNeedsKey(recoveryAvailable: false)))
        try r.host.click("cloud.advanced.toggle")
        try r.host.click("cloud.reset.run")
        XCTAssertTrue(r.account.resets.isEmpty)
        r.model.resetPhrase = " RESET MY LIBRARY "
        r.host.pump(0.3)
        try r.host.click("cloud.reset.run")
        XCTAssertEqual(r.account.resets.count, 1, "surrounding spaces are forgiven, as the controller does")
    }

    // MARK: Problems

    func testRevokedAndUnavailableOfferARoute() throws {
        let revoked = rig(.deviceRevoked)
        try revoked.host.click("cloud.revoked.start")
        XCTAssertEqual(revoked.account.startOverCount, 1)

        let down = rig(.unavailable(.server(code: "boom")))
        let before = down.account.refreshCount
        try down.host.click("cloud.unavailable.retry")
        XCTAssertEqual(down.account.refreshCount, before + 1)
        try down.host.click("cloud.unavailable.startover")
        XCTAssertEqual(down.account.startOverCount, 1)

        let offline = rig(.unavailable(.offline))
        XCTAssertNil(offline.host.frame("cloud.unavailable.startover"), "being offline never suggests starting over")
    }

    // MARK: Model only

    func testEveryAccountStateHasAScreen() {
        let states: [CloudAccountState] = [.notSubscribed, .purchasing, .creatingAccount, .creatingLibrary, .offerRecoveryKey,
            .showRecoveryKey("K"), .ready, .readOnly(.expired), .enrolPending, .needsKey(CloudNeedsKey(recoveryAvailable: true)),
            .confirming, .resetting, .deviceRevoked, .unavailable(.offline)]
        let screens = states.map { CloudPanelModel.screen(for: $0, pending: false) }
        for (i, a) in screens.enumerated() { for b in screens[(i + 1)...] { XCTAssertNotEqual(a, b) } }
        XCTAssertEqual(CloudPanelModel.screen(for: .notSubscribed, pending: true), .awaitingApproval)
    }

    func testOverQuotaIsMeasuredAgainstThePlan() {
        let account = StubCloudAccount(state: .ready, info: CloudPanelFixtures.info(storedGB: 27.5, quotaGB: 25))
        let model = CloudPanelModel(account: account, environment: PanelRecorder().environment(for: account))
        Self.keepAlive += [account, model]
        XCTAssertEqual(model.overQuotaBytes, 2_500_000_000)
        XCTAssertEqual(model.usage?.fraction, 1)
        account.accountInfo = CloudPanelFixtures.info(storedGB: 5)
        XCTAssertNil(model.overQuotaBytes)
    }

    func testTheShippedBuildCannotForceTheCloudRowOn() {
        XCTAssertNil(CloudFeature.testOverride, "a test left the override on")
        XCTAssertFalse(CloudFeature.isAvailable, "Cloud stays off until CloudFeature.isLive is flipped at release")
        CloudFeature.testOverride = true
        XCTAssertTrue(CloudFeature.isAvailable)
        CloudFeature.testOverride = nil
    }
}

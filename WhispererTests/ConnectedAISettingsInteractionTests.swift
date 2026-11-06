//
//  ConnectedAISettingsInteractionTests.swift
//  WhispererTests
//
//  Clicks on the Connected AI settings page, end to end through the code the buttons call.
//
//  Every control on `ConnectedAIPageView` forwards to `ConnectedAIPageController` (chooser
//  chips → `select` / `chooseLocal`, card buttons → `perform`, consent sheet → `allowConsent`
//  / `cancelConsent`). These tests drive that controller against an isolated store, assert the
//  routing state and which sheet is up, and render the page in each state to prove the view
//  builds from it. (Driving SwiftUI through the accessibility tree from inside the test host
//  deadlocks — an in-process AX request waits on the main run loop it is blocking — and the
//  project has no UI-test bundle.)
//

import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class ConnectedAISettingsInteractionTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func makeController() -> (ConnectedAIPageController, ConnectedAIStore) {
        let store = ConnectedAIStore(
            defaults: UserDefaults(suiteName: "ConnectedAIInteraction-\(UUID().uuidString)")!,
            keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        let controller = ConnectedAIPageController(store: store)
        var opened: [URL] = []
        var copied: [String] = []
        controller.openURL = { opened.append($0) }
        controller.copyToPasteboard = { copied.append($0) }
        Self.keepAlive += [store, controller]
        return (controller, store)
    }

    private func render(_ store: ConnectedAIStore, file: StaticString = #filePath, line: UInt = #line) {
        let view = LLMPageView(colorScheme: .dark, store: store).frame(width: 1000)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 1600)
        hosting.layoutSubtreeIfNeeded()
        Self.keepAlive.append(hosting)
        XCTAssertGreaterThan(hosting.fittingSize.height, 400, "page renders in this state", file: file, line: line)
    }

    // MARK: - Chooser + consent

    func testChoosingUnconsentedProviderOpensConsentAndRoutesNothing() {
        let (c, store) = makeController()
        store._setReadinessForTesting(.ready(detail: "m"), for: .anthropicKey)
        XCTAssertTrue(c.isChooserEnabled(.anthropicKey))

        c.select(.anthropicKey)
        XCTAssertEqual(c.consentFor, .anthropicKey, "consent sheet is presented")
        XCTAssertNil(store.activeProviderID, "nothing routes before Allow")
        render(store)

        c.allowConsent(.anthropicKey)
        XCTAssertNil(c.consentFor, "sheet dismissed")
        XCTAssertEqual(store.activeProviderID, .anthropicKey)
        XCTAssertTrue(c.chooserFootnote.contains("Anthropic API"))
        render(store)
    }

    func testCancellingConsentLeavesLocal() {
        let (c, store) = makeController()
        c.select(.geminiKey)
        c.cancelConsent()
        XCTAssertNil(c.consentFor)
        XCTAssertFalse(store.hasConsent(.geminiKey))
        XCTAssertNil(store.activeProviderID)
        XCTAssertTrue(c.chooserFootnote.contains("run on this Mac"))
    }

    func testConsentedProviderIsUsedWithoutSecondPrompt() {
        let (c, store) = makeController()
        store.grantConsent(.openAIKey)
        c.select(.openAIKey)
        XCTAssertNil(c.consentFor)
        XCTAssertEqual(store.activeProviderID, .openAIKey)
    }

    func testChooseLocalAndKeepLocal() {
        let (c, store) = makeController()
        store.grantConsent(.openAIKey)
        c.select(.openAIKey)
        c.chooseLocal()
        XCTAssertNil(store.activeProviderID)

        c.select(.openAIKey)
        store.keepLocalOnly = true          // the Privacy switch binds straight to this
        XCTAssertNil(store.activeProviderID)
        XCTAssertTrue(c.chooserFootnote.contains("nothing is sent"))
        render(store)
        c.select(.openAIKey)                // choosing a provider again turns local-only off
        XCTAssertFalse(store.keepLocalOnly)
        XCTAssertEqual(store.activeProviderID, .openAIKey)
    }

    func testChooserChipDisabledUntilReady() {
        let (c, store) = makeController()
        XCTAssertFalse(c.isChooserEnabled(.claudeCode), "unchecked provider can't be chosen")
        store._setReadinessForTesting(.notSignedIn(hint: "claude auth login"), for: .claudeCode)
        XCTAssertFalse(c.isChooserEnabled(.claudeCode))
        store._setReadinessForTesting(.ready(detail: nil), for: .claudeCode)
        XCTAssertTrue(c.isChooserEnabled(.claudeCode))
    }

    // MARK: - Card buttons

    func testInUseCardOffersStopAndRevoke() {
        let (c, store) = makeController()
        store._setReadinessForTesting(.ready(detail: nil), for: .anthropicKey)
        store.grantConsent(.anthropicKey)
        c.perform(.useForMeetings, id: .anthropicKey)
        let card = c.cardModel(.anthropicKey)
        XCTAssertTrue(card.isInUse)
        XCTAssertEqual(card.primary, .stopUsing)
        XCTAssertEqual(c.actionLabel(card.primary!, id: .anthropicKey), "Stop using")

        c.perform(.stopUsing, id: .anthropicKey)
        XCTAssertNil(store.activeProviderID)
        XCTAssertTrue(store.hasConsent(.anthropicKey), "stopping keeps the permission")

        c.perform(.useForMeetings, id: .anthropicKey)
        c.perform(.revokePermission, id: .anthropicKey)
        XCTAssertFalse(store.hasConsent(.anthropicKey))
        XCTAssertNil(store.selectedProvider, "revoking also stops using the provider")
    }

    func testAddKeyOpensKeySheetAndRemoveKeyClearsIt() async throws {
        let (c, store) = makeController()
        c.perform(.enterKey, id: .anthropicKey)
        XCTAssertEqual(c.keyEditorFor, .anthropicKey)
        XCTAssertEqual(c.actionLabel(.enterKey, id: .anthropicKey), "Add key…")

        store.setAPIKey("sk-ant-test", for: .anthropicKey)
        guard store.apiKey(for: .anthropicKey) != nil else {
            throw XCTSkip("Keychain not readable from this test host right now")
        }
        XCTAssertEqual(c.actionLabel(.enterKey, id: .anthropicKey), "Edit key…")
        await store.refreshReadiness(.anthropicKey)
        XCTAssertTrue(c.cardModel(.anthropicKey).secondary.contains(.removeKey))
        store.grantConsent(.anthropicKey)
        c.select(.anthropicKey)

        await c.perform(.removeKey, id: .anthropicKey)?.value
        XCTAssertNil(store.apiKey(for: .anthropicKey))
        XCTAssertNil(store.selectedProvider, "removing the key in use stops using it")
        XCTAssertEqual(store.readiness[.anthropicKey], .needsKey)
        render(store)
    }

    func testCopySignInCommandAndInstall() {
        let (c, _) = makeController()
        var copied: [String] = []
        var opened: [URL] = []
        c.copyToPasteboard = { copied.append($0) }
        c.openURL = { opened.append($0) }

        c.perform(.copySignInCommand("claude auth login"), id: .claudeCode)
        XCTAssertEqual(copied, ["claude auth login"])
        XCTAssertEqual(c.actionLabel(.copySignInCommand("x"), id: .claudeCode), "Copied — run it in Terminal")

        let url = URL(string: "https://code.claude.com/docs/en/setup")!
        c.perform(.install(url), id: .claudeCode)
        XCTAssertEqual(opened, [url])
    }

    func testTestButtonReportsFailureOnCard() async {
        let (c, store) = makeController()
        // No key stored: the test request fails without touching the network.
        await c.perform(.test, id: .geminiKey)?.value
        XCTAssertNotNil(c.testMessages[.geminiKey])
        XCTAssertNotEqual(c.testMessages[.geminiKey], "Testing…")
        XCTAssertEqual(store.readiness[.geminiKey], .unavailable("Key rejected"))
        XCTAssertEqual(c.cardModel(.geminiKey).primary, .enterKey, "a rejected key card asks for a key")
    }

    func testEveryProviderCardRendersInEveryState() {
        let states: [ProviderReadiness?] = [nil, .ready(detail: "d"), .notInstalled, .notSignedIn(hint: "h"),
                                            .needsKey, .quotaExhausted(until: Date()), .unavailable("x")]
        for state in states {
            let (c, store) = makeController()
            for id in store.availableProviders {
                store._setReadinessForTesting(state, for: id)
                let card = c.cardModel(id)
                if let primary = card.primary { XCTAssertFalse(c.actionLabel(primary, id: id).isEmpty) }
            }
            render(store)
        }
    }

    // MARK: - Rows (LLM page)

    func testTappingReadyUnconsentedRowOpensInlineConsent() {
        let (c, store) = makeController()
        store._setReadinessForTesting(.ready(detail: nil), for: .anthropicKey)
        c.rowTapped(.anthropicKey)
        XCTAssertEqual(c.panel(for: .anthropicKey), .consent)
        XCTAssertNil(store.activeProviderID)
        c.allowConsent(.anthropicKey)
        XCTAssertEqual(store.activeProviderID, .anthropicKey)
        XCTAssertEqual(c.panel(for: .anthropicKey), .none, "panel closes once allowed")
    }

    func testTappingNotReadyRowTogglesSetup() {
        let (c, store) = makeController()
        store._setReadinessForTesting(.notSignedIn(hint: "claude auth login"), for: .claudeCode)
        c.rowTapped(.claudeCode)
        XCTAssertEqual(c.panel(for: .claudeCode), .setup)
        c.rowTapped(.claudeCode)
        XCTAssertEqual(c.panel(for: .claudeCode), .none, "a second tap closes it")
        XCTAssertNil(store.activeProviderID)
    }

    func testTappingRowInUseOpensManagePanel() {
        let (c, store) = makeController()
        store._setReadinessForTesting(.ready(detail: nil), for: .openAIKey)
        store.grantConsent(.openAIKey)
        c.rowTapped(.openAIKey)
        XCTAssertEqual(store.activeProviderID, .openAIKey)
        XCTAssertEqual(c.panel(for: .openAIKey), .none)
        c.rowTapped(.openAIKey)
        XCTAssertEqual(c.panel(for: .openAIKey), .manage)
        c.perform(.revokePermission, id: .openAIKey)
        XCTAssertNil(store.activeProviderID)
        XCTAssertEqual(c.panel(for: .openAIKey), .none)
    }

    func testLocalTappedClearsKeepLocalAndPanels() {
        let (c, store) = makeController()
        store.keepLocalOnly = true
        c.expanded = .claudeCode
        c.localTapped()
        XCTAssertFalse(store.keepLocalOnly)
        XCTAssertNil(c.expanded)
        XCTAssertNil(store.activeProviderID)
    }

    func testSaveKeyThenConsent() async throws {
        let (c, store) = makeController()
        c.rowTapped(.geminiKey)                       // not ready → setup with key field
        XCTAssertEqual(c.panel(for: .geminiKey), .setup)
        c.keyDrafts[.geminiKey] = "g-key-123"
        await c.saveKey(.geminiKey).value
        guard store.apiKey(for: .geminiKey) != nil else { throw XCTSkip("Keychain not readable from this test host right now") }
        XCTAssertTrue(store.readiness[.geminiKey]?.isReady == true)
        XCTAssertEqual(c.panel(for: .geminiKey), .consent, "a working key moves straight on to consent")
        XCTAssertNil(c.keyDrafts[.geminiKey], "the typed key is not kept in memory after saving")
    }

    func testPageListsEveryAvailableProviderOnce() {
        let (c, store) = makeController()
        let shown = c.subscriptionProviders + c.apiKeyProviders
        XCTAssertEqual(Set(shown), Set(store.availableProviders))
        XCTAssertEqual(shown.count, store.availableProviders.count)
        XCTAssertTrue(c.apiKeyProviders.allSatisfy { $0.kind == .apiKey })
    }
}

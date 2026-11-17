import XCTest
import StoreKitTest
@testable import whisperer

/// The App Store build with and without the $14.99 Pro purchase, driven through a real (simulated) StoreKit purchase:
/// before it meetings, calendar, AI and MCP are closed; after it they are open; the base app is never closed.
@MainActor
final class ProPurchaseFlowTests: XCTestCase {
    private var session: SKTestSession!

    /// Only the tests that really buy something start the simulated store.
    private func startStore() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "WhispererPro", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func setUp() async throws {
        ProAccess.testSellsPro = true            // behave like the Mac App Store build
        ProAccess.testOverride = nil
        UserDefaults.standard.removeObject(forKey: StoreManager.proStatusKey)
        StoreManager.shared.isPro = false
    }

    override func tearDown() async throws {
        ProAccess.testSellsPro = false
        ProAccess.testOverride = nil
        session?.clearTransactions()
        UserDefaults.standard.removeObject(forKey: StoreManager.proStatusKey)
        StoreManager.shared.isPro = false
    }

    func testEveryProFeatureIsClosedUntilTheStorePurchase() async throws {
        try startStore()
        for feature in ProFeature.allCases { XCTAssertFalse(ProAccess.allows(feature), "\(feature) must be locked before purchase") }

        let store = StoreManager.shared
        await store.loadProducts()
        XCTAssertEqual(store.proPackProduct?.id, "com.ivy.whisperer.pro")
        XCTAssertEqual(store.proPackPrice, "$14.99")

        // The system purchase sheet cannot be shown from a test; the simulated store completes the purchase and the app
        // must recognise the transaction it finds.
        _ = try await session.buyProduct(identifier: "com.ivy.whisperer.pro")
        await store.checkPurchased()

        XCTAssertTrue(store.isPro)
        for feature in ProFeature.allCases { XCTAssertTrue(ProAccess.allows(feature), "\(feature) must open after purchase") }
        XCTAssertTrue(UserDefaults.standard.bool(forKey: StoreManager.proStatusKey), "the unlock survives a relaunch")
    }

    func testRestoreFindsAnEarlierPurchaseOnANewMac() async throws {
        try startStore()
        let store = StoreManager.shared
        await store.loadProducts()
        _ = try await session.buyProduct(identifier: "com.ivy.whisperer.pro")
        // A fresh install: nothing cached, the purchase only exists in the App Store account.
        UserDefaults.standard.removeObject(forKey: StoreManager.proStatusKey)
        store.isPro = false
        XCTAssertFalse(ProAccess.isPro)

        await store.checkPurchased()

        XCTAssertTrue(store.isPro)
        XCTAssertTrue(ProAccess.isPro)
    }

    func testTheOldProductIdAlsoUnlocks() async throws {
        // Users who bought `propack` in an earlier build keep Pro: either id entitles.
        XCTAssertTrue(["com.ivy.whisperer.pro", "com.ivy.whisperer.propack"].allSatisfy { id in
            StoreManager.entitlingIds.contains(id)
        })
    }

    func testCancelledPurchaseLeavesTheButtonUsable() async throws {
        try startStore()
        session.askToBuyEnabled = false
        let store = StoreManager.shared
        await store.loadProducts()
        session.failTransactionsEnabled = true
        _ = try? await store.purchase()
        XCTAssertFalse(store.isPurchasing, "a failed or cancelled purchase must not leave the button stuck on Processing")
        XCTAssertFalse(ProAccess.isPro)
        session.failTransactionsEnabled = false
    }

    func testBaseAppStaysOpenWithoutPro() {
        // What Basic ($4.99) keeps: nothing in ProFeature covers dictation, files, history, dictionary or Fast Polish.
        XCTAssertEqual(Set(ProFeature.allCases.map(\.title)), ["Meetings", "Meeting detection", "Calendar sync", "AI features", "The MCP server"])
    }
}

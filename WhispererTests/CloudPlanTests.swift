//
//  CloudPlanTests.swift
//  WhispererTests
//
//  The catalogue, the access states and the account token — everything about Whisperer Cloud purchases
//  that can be checked without the App Store.
//

import XCTest
import StoreKit
@testable import whisperer

final class CloudPlanTests: XCTestCase {

    func testProductIDsRoundTripAndMatchTheServerCatalogue() {
        for tier in CloudTier.allCases {
            for period in [CloudPeriod.monthly, .yearly] {
                let product = CloudProduct(tier: tier, period: period)
                XCTAssertEqual(CloudProduct(id: product.id), product)
            }
        }
        XCTAssertEqual(CloudProduct(tier: .standard, period: .yearly).id, "com.ivy.whisperer.cloud.standard.yearly")
    }

    func testOnlyWhispererCloudIDsParse() {
        for bad in ["com.ivy.whisperer.propack", "com.ivy.whisperer.cloud.", "com.ivy.whisperer.cloud.starter",
                    "com.ivy.whisperer.cloud.huge.monthly", "com.ivy.whisperer.cloud.starter.weekly",
                    "com.ivy.whisperer.cloud.starter.monthly.extra", "com.other.cloud.starter.monthly"] {
            XCTAssertNil(CloudProduct(id: bad), bad)
        }
    }

    func testLaunchCatalogueIsThreeTiersTwoPeriodsInDisplayOrder() {
        XCTAssertEqual(CloudProduct.launchIDs.count, 6)
        XCTAssertFalse(CloudProduct.launchIDs.contains { $0.contains(".max.") }, "Max is not on sale yet")
        let shuffled = CloudProduct.launchIDs.reversed().sorted(by: CloudProduct.displayOrder)
        XCTAssertEqual(shuffled, CloudProduct.launchIDs)
        XCTAssertEqual(CloudProduct.launchIDs.first, "com.ivy.whisperer.cloud.starter.monthly")
    }

    func testTiersMatchTheServerLimits() {
        XCTAssertEqual(CloudTier.allCases.map(\.storageGB), [5, 25, 100, 500])
        XCTAssertEqual(CloudTier.allCases.map(\.deviceLimit), [2, 4, 8, 8])
        XCTAssertEqual(CloudTier.allCases.sorted(), CloudTier.allCases)
    }

    func testEveryRenewalStateMapsToTheRightAccess() {
        XCTAssertEqual(CloudAccess(.subscribed), .active)
        XCTAssertEqual(CloudAccess(.inGracePeriod), .grace)
        XCTAssertEqual(CloudAccess(.inBillingRetryPeriod), .retry)
        XCTAssertEqual(CloudAccess(.expired), .expired)
        XCTAssertEqual(CloudAccess(.revoked), .revoked)
    }

    func testOnlyPaidUpStatesMayWriteButEverythingKeepsReading() {
        XCTAssertTrue(CloudAccess.active.canWrite)
        XCTAssertTrue(CloudAccess.grace.canWrite)
        for state in [CloudAccess.none, .retry, .expired, .revoked] { XCTAssertFalse(state.canWrite, "\(state)") }
        for state in [CloudAccess.active, .grace, .retry, .expired, .revoked] { XCTAssertTrue(state.canRead, "\(state)") }
        XCTAssertFalse(CloudAccess.none.canRead)
    }

    func testTheStrongestStateWinsWhenAGroupReportsSeveral() {
        XCTAssertEqual(CloudAccess.strongest([.expired, .active, .revoked]), .active)
        XCTAssertEqual(CloudAccess.strongest([.expired, .retry]), .retry)
        XCTAssertEqual(CloudAccess.strongest([]), .none)
    }

    func testTheCloudIsNotAvailableUntilItIsLiveAndOnlyInTheStoreBuild() {
        XCTAssertFalse(CloudFeature.isLive, "flip isLive only at release")
        XCTAssertFalse(CloudFeature.isAvailable)
        #if !APP_STORE
        XCTAssertFalse(CloudFeature.isStoreBuild, "the direct build must never offer Cloud")
        #endif
    }

    func testAccountTokenIsStableOnceCreated() throws {
        let service = "com.ivy.whisperer.cloud.account-token.test.\(UUID().uuidString)"
        defer { CloudAccountToken.delete(service: service) }
        guard let first = CloudAccountToken.current(service: service) else {
            throw XCTSkip("the test host has no data-protection keychain access")
        }
        XCTAssertEqual(CloudAccountToken.current(service: service), first)
    }
}

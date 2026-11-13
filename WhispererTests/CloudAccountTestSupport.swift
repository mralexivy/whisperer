import Foundation
@testable import whisperer

/// A purchase source for tests: `jws` is what `currentTransactionJWS()` returns; `onPurchase` runs on purchase.
@MainActor
final class FakePurchasing: CloudPurchasing {
    var access: CloudAccess = .active
    var jws: String?
    var outcome: CloudPurchaseOutcome? = .purchased
    var onPurchase: ((CloudProduct) async -> String?)?
    private(set) var purchases: [CloudProduct] = []
    private(set) var refreshCount = 0

    init(jws: String? = nil) { self.jws = jws }

    func purchase(_ product: CloudProduct) async -> CloudPurchaseOutcome? {
        purchases.append(product)
        if let onPurchase, let minted = await onPurchase(product) { jws = minted }
        return outcome
    }

    func currentTransactionJWS() async -> String? { jws }
    func refresh() async { refreshCount += 1 }
}

nonisolated enum CloudTestJSON {
    static let accountId = String(repeating: "a", count: 32)

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// The body of POST /v1/accounts, /v1/devices/confirm and /v1/session, as the Go server writes it.
    static func session(device: String, epoch: Int = 1, token: String = "tok-1", expiresIn: TimeInterval = 3600, state: String = "active",
                        readOnly: Bool = false, libraryExists: Bool, keyVersion: Int = 1, recovery: Bool = false, now: Date = Date()) -> String {
        """
        {"accountId":"\(accountId)","deviceId":"\(device)","epoch":\(epoch),"token":"\(token)","expiresAt":"\(iso(now.addingTimeInterval(expiresIn)))",
        "state":"\(state)","readOnly":\(readOnly),"plan":{"name":"standard","storedBytes":26843545600,"monthlyDownloadBytes":53687091200,"monthlyUploadGrants":50000},
        "paidUntil":"\(iso(now.addingTimeInterval(86400)))","library":{"exists":\(libraryExists),"keyVersion":\(libraryExists ? keyVersion : 0),"recoveryAvailable":\(recovery)},
        "serverTime":"\(iso(now))"}
        """
    }

    static func enrollment(device: String, challenge: String = String(repeating: "ab", count: 16), exists: Bool, keyVersion: Int = 1, recovery: Bool = false, now: Date = Date()) -> String {
        """
        {"deviceId":"\(device)","library":{"exists":\(exists),"keyVersion":\(exists ? keyVersion : 0),"recoveryAvailable":\(recovery)},
        "enrollChallenge":"\(challenge)","expiresAt":"\(iso(now.addingTimeInterval(7 * 86400)))"}
        """
    }

    static func error(_ code: String, _ extra: String = "") -> String { #"{"error":"\#(code)","message":"m"\#(extra)}"# }

    static let nonce = String(repeating: "0f", count: 32)
    static func challenge() -> String { #"{"nonce":"\#(nonce)","serverTime":"\#(iso(Date()))"}"# }
}

nonisolated extension CloudStubProtocol.Reply {
    static func err(_ status: Int, _ code: String, _ extra: String = "") -> CloudStubProtocol.Reply {
        .json(CloudTestJSON.error(code, extra), status: status)
    }
}

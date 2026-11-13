import XCTest
import CryptoKit
@testable import whisperer

// MARK: - Pure decisions

final class CloudAccountDecisionTests: XCTestCase {
    private func ring(_ versions: [UInt8]) throws -> CloudKeyRing {
        var r = CloudKeyRing()
        for v in versions { try r.insert(Data(repeating: v, count: 32), version: v) }
        return r
    }

    func testKeyDecision() throws {
        let none = CloudLibraryInfo(exists: false, keyVersion: 0, recoveryAvailable: false)
        let v1 = CloudLibraryInfo(exists: true, keyVersion: 1, recoveryAvailable: false)
        let v2 = CloudLibraryInfo(exists: true, keyVersion: 2, recoveryAvailable: true)
        XCTAssertEqual(CloudKeyDecision.decide(library: none, ring: CloudKeyRing()), .noLibrary)
        XCTAssertEqual(CloudKeyDecision.decide(library: none, ring: try ring([1])), .noLibrary, "a stale key never wins over the server's word")
        XCTAssertEqual(CloudKeyDecision.decide(library: v1, ring: CloudKeyRing()), .needsKey, "a library with no local key is never given a new one")
        XCTAssertEqual(CloudKeyDecision.decide(library: v1, ring: try ring([1])), .prove(version: 1))
        XCTAssertEqual(CloudKeyDecision.decide(library: v2, ring: try ring([1])), .needsKey, "an older key does not open a newer library")
        XCTAssertEqual(CloudKeyDecision.decide(library: v2, ring: try ring([1, 2])), .prove(version: 2))
        XCTAssertEqual(CloudKeyDecision.decide(library: CloudLibraryInfo(exists: true, keyVersion: 999, recoveryAvailable: false), ring: try ring([1])), .needsKey)
    }

    func testReadOnlyReasonFollowsTheServerAndRefinesWithStoreKit() {
        XCTAssertEqual(CloudReadOnlyReason.from(server: .lapsed, local: .expired), .expired)
        XCTAssertEqual(CloudReadOnlyReason.from(server: .lapsed, local: .retry), .paymentRetry)
        XCTAssertEqual(CloudReadOnlyReason.from(server: .lapsed, local: .revoked), .refunded)
        XCTAssertEqual(CloudReadOnlyReason.from(server: .lapsed, local: .none), .expired)
        XCTAssertEqual(CloudReadOnlyReason.from(server: .sealed, local: .retry), .sealed)
        XCTAssertEqual(CloudReadOnlyReason.from(server: .softDeleted, local: .active), .removed)
        XCTAssertEqual(CloudReadOnlyReason.from(server: .deleted, local: .active), .removed)
    }

    func testProblemMapping() {
        func api(_ status: Int, _ code: String, retry: TimeInterval? = nil) -> CloudAPIError { CloudAPIError(status: status, code: code, message: "", retryAfter: retry, body: Data()) }
        XCTAssertEqual(CloudAccountProblem(.offline), .offline)
        XCTAssertEqual(CloudAccountProblem(api(403, "device_limit")), .deviceLimit)
        XCTAssertEqual(CloudAccountProblem(api(429, "too_many_pending")), .tooManyPending)
        XCTAssertEqual(CloudAccountProblem(api(429, "rate_limited", retry: 3600)), .rateLimited(retryAfter: 3600))
        XCTAssertEqual(CloudAccountProblem(api(403, "wrong_product")), .wrongProduct)
        XCTAssertEqual(CloudAccountProblem(api(500, "internal")), .server(code: "internal"))
    }

    func testResetPhraseMustBeExact() {
        XCTAssertTrue(CloudResetPhrase.matches("RESET MY LIBRARY"))
        XCTAssertTrue(CloudResetPhrase.matches("  RESET MY LIBRARY\n"))
        XCTAssertFalse(CloudResetPhrase.matches("reset my library"))
        XCTAssertFalse(CloudResetPhrase.matches("RESET MY LIBRAR"))
        XCTAssertFalse(CloudResetPhrase.matches(""))
    }

    func testStateDescriptionNeverContainsTheRecoveryKey() throws {
        let key = try CloudRecoveryKey.encode(try CloudRecoveryKey.generate())
        let state = CloudAccountState.showRecoveryKey(key)
        XCTAssertFalse("\(state)".contains(key))
        XCTAssertFalse(String(describing: state).contains(key))
    }
}

// MARK: - Controller against a scripted server

@MainActor
final class CloudAccountControllerTests: XCTestCase {
    private let base = URL(string: "https://api.test")!
    private var deviceKeychain: InMemoryCloudKeychain!
    private var keychain: InMemoryCloudKeychain!
    private var keys: CloudKeyStore!
    private var purchasing: FakePurchasing!
    private var clock = CloudLocked<Date>(Date())
    private var epochDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        deviceKeychain = InMemoryCloudKeychain()
        keychain = InMemoryCloudKeychain()
        keys = CloudKeyStore(keychain: keychain)
        purchasing = FakePurchasing(jws: "jws.value")
        epochDefaults = UserDefaults(suiteName: "ctl-epoch-\(UUID().uuidString)")
        clock = CloudLocked(Date())
    }

    override func tearDown() async throws {
        CloudStubProtocol.uninstall()
        try await super.tearDown()
    }

    private func controller() -> CloudAccountController {
        let clock = self.clock
        return CloudAccountController(http: CloudHTTP(baseURL: base, session: CloudStubProtocol.session()), purchasing: purchasing, keyStore: keys,
                                      deviceKeychain: deviceKeychain, deviceKeyService: "ctl-tests", keyEpochDefaults: epochDefaults, now: { clock.snapshot })
    }

    private func deviceKey() throws -> CloudDeviceKey { try CloudDeviceKey.loadOrCreate(keychain: deviceKeychain, service: "ctl-tests") }

    /// Routes by "METHOD path"; unknown routes fail the test. The challenge route is always answered.
    private func serve(_ routes: [String: @Sendable (Data) -> CloudStubProtocol.Reply], log: CloudLocked<[String]> = CloudLocked([])) {
        CloudStubProtocol.install { request, body in
            let key = "\(request.httpMethod ?? "") \(request.url!.path)"
            log.with { $0.append(key) }
            if request.url!.path == "/v1/auth/challenge" { return .json(CloudTestJSON.challenge()) }
            guard let route = routes[key] else { XCTFail("unexpected request \(key)"); return .err(500, "unexpected") }
            return route(body)
        }
    }

    private nonisolated func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    private func masterKeyBytes() throws -> Data {
        try XCTUnwrap(try keys.loadRing().keys[1])
    }

    // MARK: first Mac

    func testNewPurchaseCreatesAccountThenLibraryThenOffersTheRecoveryKey() async throws {
        let device = try deviceKey().deviceId
        let keyCountWhenAccountCreated = CloudLocked(-1)
        let libraryBody = CloudLocked<[String: Any]>([:])
        let keychain = self.keychain!
        let log = CloudLocked<[String]>([])
        serve([
            "POST /v1/accounts": { _ in
                keyCountWhenAccountCreated.with { $0 = (try? CloudKeyStore(keychain: keychain).loadRing().versions.count) ?? -2 }
                return .json(CloudTestJSON.session(device: device, libraryExists: false), status: 201)
            },
            "POST /v1/library": { body in libraryBody.with { $0 = self.object(body) }; return .json(#"{"keyVersion":1}"#, status: 201) },
        ], log: log)
        let c = controller()
        XCTAssertEqual(c.state, .notSubscribed)
        purchasing.jws = nil
        purchasing.onPurchase = { _ in "minted.jws" }
        await c.purchase(CloudProduct(tier: .standard, period: .monthly))

        XCTAssertEqual(c.state, .offerRecoveryKey)
        XCTAssertEqual(purchasing.purchases, [CloudProduct(tier: .standard, period: .monthly)])
        XCTAssertEqual(keyCountWhenAccountCreated.snapshot, 0, "no key exists until the server says there is no library")
        XCTAssertEqual(log.snapshot.filter { $0 == "POST /v1/library" }.count, 1)
        // The verifier sent to the server is SHA-256(authKey) of the key now in the keychain.
        let master = SymmetricKey(data: try masterKeyBytes())
        XCTAssertEqual(libraryBody.snapshot["keyVerifier"] as? String, CloudCrypto.verifier(authKey: CloudCrypto.authKey(master: master)).cloudHex)
        XCTAssertEqual(c.identity?.accountId, CloudTestJSON.accountId)
        XCTAssertEqual(c.identity?.epoch, 1)
        XCTAssertEqual(c.identity?.deviceId, device)
    }

    func testLibraryExistsConflictDiscardsTheGeneratedKeyAndWaitsForTheWinnersKey() async throws {
        let device = try deviceKey().deviceId
        serve([
            "POST /v1/accounts": { _ in .json(CloudTestJSON.session(device: device, libraryExists: false), status: 201) },
            "POST /v1/library": { _ in .err(409, "library_exists", #","library":{"exists":true,"keyVersion":1,"recoveryAvailable":true}"#) },
        ])
        let c = controller()
        await c.purchase(CloudProduct(tier: .standard, period: .monthly))
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: true)))
        XCTAssertTrue(try keys.loadRing().isEmpty, "the key generated for the lost race is discarded")
    }

    func testLibraryConflictLeavesAKeyThatArrivedFromICloudAlone() async throws {
        let device = try deviceKey().deviceId
        let winners = Data(repeating: 0x42, count: 32)
        let keychain = self.keychain!
        serve([
            "POST /v1/accounts": { _ in .json(CloudTestJSON.session(device: device, libraryExists: false), status: 201) },
            "POST /v1/library": { _ in
                // iCloud Keychain delivers the winner's key into the same slot while our request is in flight.
                try? CloudKeyStore(keychain: keychain).save(winners, version: 1)
                return .err(409, "library_exists", #","library":{"exists":true,"keyVersion":1,"recoveryAvailable":false}"#)
            },
        ])
        let c = controller()
        await c.purchase(CloudProduct(tier: .standard, period: .monthly))
        XCTAssertEqual(try keys.loadRing().keys[1], winners)
        XCTAssertEqual(c.state, .ready, "the winner's key opens the library: nothing to wait for")
    }

    func testNeverCreatesAKeyWhenTheLibraryAlreadyExists() async throws {
        let device = try deviceKey().deviceId
        let log = CloudLocked<[String]>([])
        serve(["POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, libraryExists: true, recovery: false)) }], log: log)
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: false)))
        XCTAssertTrue(try keys.loadRing().isEmpty)
        XCTAssertFalse(log.snapshot.contains("POST /v1/library"))
    }

    func testRecoveryKeyIsWrappedUploadedAndShownOnce() async throws {
        let device = try deviceKey().deviceId
        let put = CloudLocked<[String: Any]>([:])
        serve([
            "POST /v1/accounts": { _ in .json(CloudTestJSON.session(device: device, libraryExists: false), status: 201) },
            "POST /v1/library": { _ in .json(#"{"keyVersion":1}"#, status: 201) },
            "PUT /v1/library/recovery": { body in put.with { $0 = self.object(body) }; return CloudStubProtocol.Reply(status: 204) },
        ])
        let c = controller()
        await c.purchase(CloudProduct(tier: .standard, period: .monthly))
        XCTAssertEqual(c.state, .offerRecoveryKey)
        await c.createRecoveryKey()
        guard case .showRecoveryKey(let text) = c.state else { return XCTFail("\(c.state)") }

        // The wrapped blob unwraps with the shown key, under the account id carried in kdf.
        let recovery = try CloudRecoveryKey.decode(text)
        let wrapped = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(put.snapshot["wrapped"] as? String)))
        let accountId = try XCTUnwrap(CloudRecoveryBlobCodec.accountId(fromKdf: try XCTUnwrap(put.snapshot["kdf"] as? String)))
        let ring = try CloudRecoveryKey.unwrap(wrapped, recoveryKey: recovery, accountId: accountId, keyVersion: 1)
        XCTAssertEqual(ring.keys[1], try masterKeyBytes())
        XCTAssertFalse(try XCTUnwrap(put.snapshot["keyProof"] as? String).isEmpty)

        c.finishRecoveryKey()
        XCTAssertEqual(c.state, .ready)
    }

    func testSkippingTheRecoveryKeyGoesToReady() async throws {
        let device = try deviceKey().deviceId
        serve([
            "POST /v1/accounts": { _ in .json(CloudTestJSON.session(device: device, libraryExists: false), status: 201) },
            "POST /v1/library": { _ in .json(#"{"keyVersion":1}"#, status: 201) },
        ])
        let c = controller()
        await c.purchase(CloudProduct(tier: .standard, period: .monthly))
        c.finishRecoveryKey()
        XCTAssertEqual(c.state, .ready)
    }

    func testPurchaseOutcomes() async {
        let c = controller()
        purchasing.outcome = .cancelled
        await c.purchase(CloudProduct(tier: .starter, period: .yearly))
        XCTAssertEqual(c.state, .notSubscribed)
        purchasing.outcome = .pending
        await c.purchase(CloudProduct(tier: .starter, period: .yearly))
        XCTAssertEqual(c.state, .notSubscribed)
        XCTAssertTrue(c.isPurchasePending)
        purchasing.outcome = nil
        await c.purchase(CloudProduct(tier: .starter, period: .yearly))
        XCTAssertEqual(c.state, .notSubscribed)
        XCTAssertNotNil(c.lastError)
    }

    func testNoSubscriptionMeansNotSubscribedWithoutAnyAccountCall() async throws {
        purchasing.jws = nil
        let log = CloudLocked<[String]>([])
        serve(["POST /v1/session": { _ in .err(404, "unknown_device") }], log: log)
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .notSubscribed)
        XCTAssertFalse(log.snapshot.contains("POST /v1/accounts"))
    }

    // MARK: new Mac

    func testNewMacWithTheKeyInKeychainProvesItAndBecomesReady() async throws {
        let device = try deviceKey().deviceId
        let master = Data(repeating: 7, count: 32)
        try keys.save(master, version: 1)
        let challenge = String(repeating: "cd", count: 16)
        let confirmBody = CloudLocked<[String: Any]>([:])
        serve([
            "POST /v1/session": { _ in .err(404, "unknown_device") },
            "POST /v1/accounts": { _ in .err(409, "already_bound") },
            "POST /v1/devices": { _ in .json(CloudTestJSON.enrollment(device: device, challenge: challenge, exists: true)) },
            "POST /v1/devices/confirm": { body in confirmBody.with { $0 = self.object(body) }; return .json(CloudTestJSON.session(device: device, libraryExists: true)) },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .ready)
        let expected = try CloudCrypto.keyProof(authKey: CloudCrypto.authKey(master: SymmetricKey(data: master)), challengeHex: challenge, deviceId: device)
        XCTAssertEqual(confirmBody.snapshot["keyProof"] as? String, expected)
        XCTAssertEqual(c.identity?.deviceId, device)
    }

    func testNewMacWithoutTheKeyWaitsAndRechecksWhenTheKeyArrives() async throws {
        let device = try deviceKey().deviceId
        let confirms = CloudLocked(0)
        serve([
            "POST /v1/session": { _ in .err(403, "device_pending") },
            "POST /v1/devices": { _ in .json(CloudTestJSON.enrollment(device: device, exists: true, recovery: true)) },
            "POST /v1/devices/confirm": { _ in confirms.with { $0 += 1 }; return .json(CloudTestJSON.session(device: device, libraryExists: true)) },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: true)))
        XCTAssertEqual(confirms.snapshot, 0)
        XCTAssertTrue(try keys.loadRing().isEmpty, "waiting never creates a key")

        await c.recheckKey()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: true)), "still no key: still waiting")

        try keys.save(Data(repeating: 9, count: 32), version: 1) // iCloud Keychain delivers it
        await c.recheckKey()
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(confirms.snapshot, 1)
    }

    func testWrongKeyInKeychainStaysNeedsKey() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 1, count: 32), version: 1)
        serve([
            "POST /v1/session": { _ in .err(403, "device_pending") },
            "POST /v1/devices": { _ in .json(CloudTestJSON.enrollment(device: device, exists: true, recovery: true)) },
            "POST /v1/devices/confirm": { _ in .err(403, "bad_key_proof") },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: true, wrongKey: true)))
        XCTAssertNil(c.identity, "a Mac that could not prove the key has no session")
    }

    func testRecoveryKeyUnlocksANewMac() async throws {
        let device = try deviceKey().deviceId
        let master = Data(repeating: 0x33, count: 32)
        var ring = CloudKeyRing(); try ring.insert(master, version: 1)
        let recovery = try CloudRecoveryKey.generate()
        let wrapped = try CloudRecoveryKey.wrap(ring: ring, recoveryKey: recovery, accountId: CloudTestJSON.accountId, keyVersion: 1)
        let blob = #"{"wrapped":"\#(wrapped.base64EncodedString())","kdf":"\#(CloudRecoveryBlobCodec.kdf(accountId: CloudTestJSON.accountId))","keyVersion":1}"#
        let challenge = String(repeating: "ef", count: 16)
        let proof = CloudLocked("")
        serve([
            "POST /v1/session": { _ in .err(403, "device_pending") },
            "POST /v1/devices": { _ in .json(CloudTestJSON.enrollment(device: device, challenge: challenge, exists: true, recovery: true)) },
            "POST /v1/library/recovery-blob": { _ in .json(blob) },
            "POST /v1/devices/confirm": { body in proof.with { $0 = self.object(body)["keyProof"] as? String ?? "" }; return .json(CloudTestJSON.session(device: device, libraryExists: true, recovery: true)) },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: true)))

        await c.submitRecoveryKey(try CloudRecoveryKey.encode(try CloudRecoveryKey.generate())) // somebody else's key
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: true, wrongRecoveryKey: true)))
        XCTAssertTrue(try keys.loadRing().isEmpty)

        await c.submitRecoveryKey("not a recovery key")
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: true, wrongRecoveryKey: true)))

        await c.submitRecoveryKey(try CloudRecoveryKey.encode(recovery))
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(try keys.loadRing().keys[1], master, "the unwrapped ring is saved to the keychain")
        XCTAssertEqual(proof.snapshot, try CloudCrypto.keyProof(authKey: CloudCrypto.authKey(master: SymmetricKey(data: master)), challengeHex: challenge, deviceId: device))
    }

    func testNewMacWhenTheLibraryDoesNotExistYetConfirmsWithoutProofAndCreatesTheLibrary() async throws {
        let device = try deviceKey().deviceId
        let confirmBody = CloudLocked<[String: Any]>([:])
        serve([
            "POST /v1/session": { _ in .err(404, "unknown_device") },
            "POST /v1/accounts": { _ in .err(409, "already_bound") },
            "POST /v1/devices": { _ in .json(CloudTestJSON.enrollment(device: device, exists: false)) },
            "POST /v1/devices/confirm": { body in confirmBody.with { $0 = self.object(body) }; return .json(CloudTestJSON.session(device: device, libraryExists: false)) },
            "POST /v1/library": { _ in .json(#"{"keyVersion":1}"#, status: 201) },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(confirmBody.snapshot["keyProof"] as? String, "")
        XCTAssertEqual(c.state, .offerRecoveryKey)
    }

    func testDeviceLimitAndRevokedAreReported() async throws {
        let device = try deviceKey().deviceId
        serve([
            "POST /v1/session": { _ in .err(404, "unknown_device") },
            "POST /v1/accounts": { _ in .err(409, "already_bound") },
            "POST /v1/devices": { _ in .err(403, "device_limit") },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .unavailable(.deviceLimit))

        serve(["POST /v1/session": { _ in .err(403, "device_revoked") }])
        let revoked = controller()
        await revoked.refresh()
        XCTAssertEqual(revoked.state, .deviceRevoked)
        _ = device
    }

    // MARK: states from the server

    func testReadOnlyStatesComeFromTheServer() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        serve(["POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, state: "lapsed", readOnly: true, libraryExists: true)) }])
        purchasing.access = .retry
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .readOnly(.paymentRetry))

        purchasing.access = .expired
        serve(["POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, state: "lapsed", readOnly: true, libraryExists: true)) }])
        let expired = controller()
        await expired.refresh()
        XCTAssertEqual(expired.state, .readOnly(.expired))
    }

    func testGraceIsStillWritable() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        serve(["POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, state: "grace", readOnly: false, libraryExists: true)) }])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .ready)
    }

    func testOfflineIsAProblemNotAState() async {
        CloudStubProtocol.install { _, _ in .fail(.notConnectedToInternet) }
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .unavailable(.offline))
    }

    // MARK: sessions

    func testSessionTokenIsCachedRenewedNearExpiryAndSingleFlight() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        let sessions = CloudLocked(0)
        serve(["POST /v1/session": { _ in
            let n = sessions.with { $0 += 1; return $0 }
            return .json(CloudTestJSON.session(device: device, token: "tok-\(n)", expiresIn: n == 1 ? 3600 : 7200, libraryExists: true))
        }])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(sessions.snapshot, 1)
        let first = try await c.sessionToken(forceRefresh: false)
        XCTAssertEqual(first, "tok-1")
        let again = try await c.sessionToken(forceRefresh: false)
        XCTAssertEqual(again, "tok-1")
        XCTAssertEqual(sessions.snapshot, 1, "a token with time left is reused")

        clock.with { $0 = $0.addingTimeInterval(3600 - 30) } // 30 s left: renew
        async let a = c.sessionToken(forceRefresh: false)
        async let b = c.sessionToken(forceRefresh: false)
        let (ta, tb) = try await (a, b)
        XCTAssertEqual(ta, "tok-2")
        XCTAssertEqual(tb, "tok-2")
        XCTAssertEqual(sessions.snapshot, 2, "concurrent callers share one renewal")

        let forced = try await c.sessionToken(forceRefresh: true)
        XCTAssertEqual(forced, "tok-3")
    }

    func testRenewalAfterRevocationSignsTheMacOut() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        let revoked = CloudLocked(false)
        serve(["POST /v1/session": { _ in
            revoked.snapshot ? .err(403, "device_revoked") : .json(CloudTestJSON.session(device: device, libraryExists: true))
        }])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .ready)
        revoked.with { $0 = true }
        do { _ = try await c.sessionToken(forceRefresh: true); XCTFail() } catch { XCTAssertEqual(error as? CloudTransportError, .deviceRevoked) }
        XCTAssertEqual(c.state, .deviceRevoked)
        XCTAssertNil(c.identity)
    }

    func testASyncRouteAnsweringDeviceRevokedSignsTheMacOutAtOnce() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        serve([
            "POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, libraryExists: true)) },
            "POST /v1/sync/upload": { _ in .err(403, "device_revoked") },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .ready)
        let transport = c.makeTransport()
        do { _ = try await transport.requestUploads([CloudUploadRequest(ref: .audio(id: String(repeating: "a", count: 32)), size: 1)]); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .deviceRevoked)
        }
        for _ in 0..<50 where c.state != .deviceRevoked { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(c.state, .deviceRevoked, "no waiting for the one-hour token to renew")
        XCTAssertNil(c.identity)
    }

    func testAKeyFromBeforeAResetElsewhereIsNotUsedInTheNewEpochUntilItIsReplaced() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        let epoch = CloudLocked(1)
        serve(["POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, epoch: epoch.snapshot, libraryExists: true)) }])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .ready)
        epoch.with { $0 = 2 }                    // another Mac reset the library: a new epoch with a new key, version 1 again
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: false, wrongKey: true)), "the old key must not be used in the new library")
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: false, wrongKey: true)), "and it stays that way until the key changes")
        try keys.save(Data(repeating: 6, count: 32), version: 1)   // iCloud Keychain delivers the new key
        await c.recheckKey()
        XCTAssertEqual(c.state, .ready)
        epoch.with { $0 = 3 }
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: false, wrongKey: true)), "a second reset is recognised the same way")
    }

    func testRenewalMovesReadyToReadOnlyAndBack() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        let lapsed = CloudLocked(false)
        serve(["POST /v1/session": { _ in
            lapsed.snapshot ? .json(CloudTestJSON.session(device: device, state: "lapsed", readOnly: true, libraryExists: true))
                            : .json(CloudTestJSON.session(device: device, libraryExists: true))
        }])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .ready)
        lapsed.with { $0 = true }
        _ = try await c.sessionToken(forceRefresh: true)
        XCTAssertEqual(c.state, .readOnly(.expired))
        XCTAssertEqual(c.identity?.readOnly, true)
        lapsed.with { $0 = false }
        _ = try await c.sessionToken(forceRefresh: true)
        XCTAssertEqual(c.state, .ready)
    }

    // MARK: reset, devices

    func testResetNeedsTheExactPhraseAndThenStartsOver() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        let log = CloudLocked<[String]>([])
        let reset = CloudLocked(false)
        serve([
            "POST /v1/session": { _ in reset.snapshot ? .json(CloudTestJSON.session(device: device, epoch: 2, libraryExists: false)) : .json(CloudTestJSON.session(device: device, libraryExists: true)) },
            "POST /v1/library/reset": { body in
                XCTAssertEqual(self.object(body)["confirm"] as? String, "RESET MY LIBRARY")
                reset.with { $0 = true }
                return .json(#"{"epoch":2,"token":"t2","expiresAt":"2030-01-01T00:00:00Z","library":{"exists":false,"keyVersion":0,"recoveryAvailable":false}}"#)
            },
            "POST /v1/library": { _ in .json(#"{"keyVersion":1}"#, status: 201) },
        ], log: log)
        let c = controller()
        await c.refresh()
        let oldKey = try masterKeyBytes()

        await c.resetLibrary(confirmation: "reset my library")
        XCTAssertNotNil(c.lastError)
        XCTAssertFalse(log.snapshot.contains("POST /v1/library/reset"), "a wrong phrase sends nothing")
        XCTAssertEqual(c.state, .ready)

        await c.resetLibrary(confirmation: "RESET MY LIBRARY")
        XCTAssertEqual(c.state, .offerRecoveryKey, "after a reset the Mac creates a fresh library")
        XCTAssertEqual(c.identity?.epoch, 2)
        XCTAssertNotEqual(try masterKeyBytes(), oldKey, "the old library key is replaced")
    }

    func testResetFromNeedsKeyUsesTheDevicePath() async throws {
        let device = try deviceKey().deviceId
        let resetBody = CloudLocked<[String: Any]>([:])
        let reset = CloudLocked(false)
        serve([
            "POST /v1/session": { _ in reset.snapshot ? .json(CloudTestJSON.session(device: device, epoch: 2, libraryExists: false)) : .err(403, "device_pending") },
            "POST /v1/devices": { _ in .json(CloudTestJSON.enrollment(device: device, exists: true)) },
            "POST /v1/library/reset": { body in reset.with { $0 = true }; resetBody.with { $0 = self.object(body) }
                return .json(#"{"epoch":2,"token":"t2","expiresAt":"2030-01-01T00:00:00Z","library":{"exists":false,"keyVersion":0,"recoveryAvailable":false}}"#) },
            "POST /v1/library": { _ in .json(#"{"keyVersion":1}"#, status: 201) },
        ])
        let c = controller()
        await c.refresh()
        XCTAssertEqual(c.state, .needsKey(CloudNeedsKey(recoveryAvailable: false)))
        await c.resetLibrary(confirmation: "RESET MY LIBRARY")
        XCTAssertEqual(resetBody.snapshot["deviceId"] as? String, device)
        XCTAssertEqual(resetBody.snapshot["transactionJWS"] as? String, "jws.value")
        XCTAssertNotNil(resetBody.snapshot["sig"])
        XCTAssertEqual(c.state, .offerRecoveryKey)
    }

    func testDeviceListAndRevoke() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        let other = String(repeating: "9", count: 32)
        let log = CloudLocked<[String]>([])
        serve([
            "POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, libraryExists: true)) },
            "GET /v1/account": { _ in .json(#"{"accountId":"\#(CloudTestJSON.accountId)","epoch":1,"state":"active","paidUntil":"2026-12-01T00:00:00Z","autoRenew":true,"plan":{"name":"standard","storedBytes":1,"monthlyDownloadBytes":1,"monthlyUploadGrants":1},"deviceLimit":4,"library":{"exists":true,"keyVersion":1,"recoveryAvailable":false},"devices":[{"id":"\#(device)","state":"authorized","current":true,"enrolledAt":"2026-09-01T00:00:00Z"},{"id":"\#(other)","state":"authorized","current":false,"enrolledAt":"2026-09-02T00:00:00Z"}]}"#) },
            "DELETE /v1/devices/\(other)": { _ in CloudStubProtocol.Reply(status: 204) },
            "DELETE /v1/devices/\(device)": { _ in CloudStubProtocol.Reply(status: 204) },
        ], log: log)
        let c = controller()
        await c.refresh()
        await c.refreshAccount()
        XCTAssertEqual(c.accountInfo?.devices.count, 2)
        await c.revokeDevice(id: other)
        XCTAssertEqual(c.state, .ready, "removing another Mac does not affect this one")
        await c.revokeDevice(id: device)
        XCTAssertEqual(c.state, .deviceRevoked)
        XCTAssertNil(c.identity)
    }

    func testTheTokenProviderServesTheTransport() async throws {
        let device = try deviceKey().deviceId
        try keys.save(Data(repeating: 5, count: 32), version: 1)
        serve([
            "POST /v1/session": { _ in .json(CloudTestJSON.session(device: device, token: "the-token", libraryExists: true)) },
            "GET /v1/sync/heads": { _ in .json(#"{"serverTime":"2026-11-13T12:00:00Z","version":1,"unchanged":true}"#) },
        ])
        let c = controller()
        await c.refresh()
        let transport = c.makeTransport()
        let heads = try await transport.heads(since: nil)
        XCTAssertEqual(heads.version, 1)
        let token = try await c.tokenProvider(false)
        XCTAssertEqual(token, "the-token")
    }
}
